-- =========================================================================
-- Intermediate stops on a bus service, with stop purposes & facilities
--
-- A stop is a template row on bus_services (the recurring template). Times are
-- stored as minute offsets from the service's departure, so they follow the
-- departure time, roll over midnight naturally and need no per-trip copies.
--   departure_offset = arrival_offset + stop_duration   (always, generated)
-- Purposes/facilities are informational only: nothing here influences timing.
-- =========================================================================

create table public.bus_service_stops (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.bus_services (id) on delete cascade,
  sequence_no integer not null check (sequence_no > 0),
  location_city_id uuid not null references public.cities (id),
  allows_pickup boolean not null default true,
  allows_drop boolean not null default true,
  arrival_offset_minutes integer not null check (arrival_offset_minutes > 0),
  stop_duration_minutes integer not null default 2 check (stop_duration_minutes between 1 and 360),
  departure_offset_minutes integer generated always as (arrival_offset_minutes + stop_duration_minutes) stored,
  stop_purposes text[] not null default '{}',
  meal_types text[] not null default '{}',
  refreshment_types text[] not null default '{}',
  facilities text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (service_id, sequence_no),
  check (allows_pickup or allows_drop),
  check (stop_purposes <@ array['meal_break', 'tea_refreshment', 'toilet_break', 'rest_break', 'ferry_transfer', 'passenger_transfer', 'other']),
  check (meal_types <@ array['breakfast', 'lunch', 'dinner']),
  check (refreshment_types <@ array['tea', 'coffee', 'snacks']),
  check (facilities <@ array['restaurant_food', 'toilet', 'drinking_water', 'waiting_area', 'refreshment_shop']),
  -- sub-options only make sense under their parent purpose
  check (meal_types = '{}' or 'meal_break' = any (stop_purposes)),
  check (refreshment_types = '{}' or 'tea_refreshment' = any (stop_purposes))
);

create index bus_service_stops_service_id_idx on public.bus_service_stops (service_id, sequence_no);
create index bus_service_stops_location_city_id_idx on public.bus_service_stops (location_city_id);

alter table public.bus_service_stops enable row level security;

-- Customers read stops through get_trip_stop_timeline(); operators write only
-- through save_service_stops(), which validates the whole list atomically.
create policy bus_service_stops_select_public on public.bus_service_stops for select to anon, authenticated using (true);
create policy bus_service_stops_admin_all on public.bus_service_stops for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- Replace a service's stops with the given ordered list.
-- p_stops: [{location_city_id, allows_pickup, allows_drop, arrival_offset_minutes,
--            stop_duration_minutes, stop_purposes[], meal_types[], refreshment_types[], facilities[]}]
create or replace function public.save_service_stops(p_service_id uuid, p_stops jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
  v_stop jsonb;
  v_seq integer := 0;
  v_prev_departure integer := 0;
  v_arrival integer;
  v_duration integer;
  v_city uuid;
begin
  select * into v_svc from public.bus_services where id = p_service_id;
  if v_svc.id is null then
    raise exception 'Service not found';
  end if;
  if not (private.is_operator_staff(v_svc.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized for this service';
  end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then
    raise exception 'p_stops must be a JSON array';
  end if;

  delete from public.bus_service_stops where service_id = p_service_id;

  for v_stop in select * from jsonb_array_elements(p_stops) loop
    v_seq := v_seq + 1;
    v_city := (v_stop ->> 'location_city_id')::uuid;
    v_arrival := (v_stop ->> 'arrival_offset_minutes')::integer;
    v_duration := coalesce((v_stop ->> 'stop_duration_minutes')::integer, 2);

    if v_city in (v_svc.service_source_city_id, v_svc.service_dest_city_id) then
      raise exception 'Stop % cannot be the origin or destination', v_seq;
    end if;
    if v_arrival <= v_prev_departure then
      raise exception 'Stop % must arrive after the previous stop has departed', v_seq;
    end if;
    if v_arrival + v_duration >= v_svc.default_arrival_offset_minutes then
      raise exception 'Stop % must depart before the bus reaches the destination', v_seq;
    end if;

    insert into public.bus_service_stops (
      service_id, sequence_no, location_city_id, allows_pickup, allows_drop,
      arrival_offset_minutes, stop_duration_minutes,
      stop_purposes, meal_types, refreshment_types, facilities
    ) values (
      p_service_id, v_seq, v_city,
      coalesce((v_stop ->> 'allows_pickup')::boolean, true),
      coalesce((v_stop ->> 'allows_drop')::boolean, true),
      v_arrival, v_duration,
      coalesce(array(select jsonb_array_elements_text(v_stop -> 'stop_purposes')), '{}'),
      coalesce(array(select jsonb_array_elements_text(v_stop -> 'meal_types')), '{}'),
      coalesce(array(select jsonb_array_elements_text(v_stop -> 'refreshment_types')), '{}'),
      coalesce(array(select jsonb_array_elements_text(v_stop -> 'facilities')), '{}')
    );
    v_prev_departure := v_arrival + v_duration;
  end loop;

  return v_seq;
end;
$$;

revoke execute on function public.save_service_stops(uuid, jsonb) from public, anon;
grant execute on function public.save_service_stops(uuid, jsonb) to authenticated;

-- Customer-facing stop timeline for one departure. Exposes only informational
-- fields (no operator/service ids); times are resolved to real timestamps, so
-- stops after midnight land on the next calendar day.
create or replace function public.get_trip_stop_timeline(p_trip_id uuid)
returns table (
  sequence_no integer,
  location_name text,
  arrival_at timestamptz,
  departure_at timestamptz,
  stop_duration_minutes integer,
  allows_pickup boolean,
  allows_drop boolean,
  stop_purposes text[],
  meal_types text[],
  refreshment_types text[],
  facilities text[]
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    st.sequence_no,
    c.name,
    t.departure_at + make_interval(mins => st.arrival_offset_minutes),
    t.departure_at + make_interval(mins => st.departure_offset_minutes),
    st.stop_duration_minutes,
    st.allows_pickup,
    st.allows_drop,
    st.stop_purposes,
    st.meal_types,
    st.refreshment_types,
    st.facilities
  from public.bus_trips t
  join public.bus_service_stops st on st.service_id = t.service_id
  join public.cities c on c.id = st.location_city_id
  where t.id = p_trip_id
  order by st.sequence_no;
$$;

revoke execute on function public.get_trip_stop_timeline(uuid) from public;
grant execute on function public.get_trip_stop_timeline(uuid) to anon, authenticated;

-- A service can't be shortened below its last stop's departure.
create or replace function private.guard_service_duration_vs_stops()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.default_arrival_offset_minutes is distinct from old.default_arrival_offset_minutes
     and exists (
       select 1 from public.bus_service_stops s
       where s.service_id = new.id and s.departure_offset_minutes >= new.default_arrival_offset_minutes
     ) then
    raise exception 'Journey duration is shorter than the last stop departure; adjust the stops first';
  end if;
  return new;
end;
$$;

create trigger guard_service_duration_vs_stops
  before update of default_arrival_offset_minutes on public.bus_services
  for each row execute function private.guard_service_duration_vs_stops();

revoke execute on function private.guard_service_duration_vs_stops() from public, anon, authenticated;
