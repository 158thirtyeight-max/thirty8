-- =========================================================================
-- Platform route catalog.
--
-- Admins define routes (origin -> destination with ordered stops and timings
-- as minute offsets from the origin departure). The catalog is the single
-- source of truth read by all three apps:
--   * admin web    - full CRUD, and assignment of a route to a bus
--   * operator app - picks a route as the starting point for a bus's route
--   * customer app - lists active routes as popular routes
-- Assigning a route copies it into the bus's own route (save_bus_route), so
-- existing booking / fare / search behaviour is unchanged.
-- =========================================================================

create table public.route_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  source_city_id uuid not null references public.cities (id),
  destination_city_id uuid not null references public.cities (id),
  distance_km numeric(8, 1) check (distance_km is null or distance_km > 0),
  est_duration_min integer check (est_duration_min is null or est_duration_min > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint route_templates_cities_differ check (source_city_id <> destination_city_id)
);

create table public.route_template_stops (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.route_templates (id) on delete cascade,
  sequence_no integer not null check (sequence_no >= 1),
  name text not null check (btrim(name) <> ''),
  city_id uuid references public.cities (id),
  is_boarding boolean not null default true,
  is_dropping boolean not null default true,
  arrival_offset_min integer check (arrival_offset_min is null or arrival_offset_min >= 0),
  departure_offset_min integer check (departure_offset_min is null or departure_offset_min >= 0),
  unique (template_id, sequence_no)
);

create index route_templates_source_dest_idx on public.route_templates (source_city_id, destination_city_id);
create index route_templates_destination_idx on public.route_templates (destination_city_id);
create index route_template_stops_city_idx on public.route_template_stops (city_id) where city_id is not null;

create trigger set_updated_at
  before update on public.route_templates
  for each row execute function private.set_updated_at();

alter table public.route_templates enable row level security;
alter table public.route_template_stops enable row level security;

-- Everyone can read active routes (admins also see inactive ones).
create policy route_templates_select on public.route_templates
  for select to anon, authenticated
  using (is_active or private.is_platform_admin());
create policy route_templates_admin_write on public.route_templates
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy route_template_stops_select on public.route_template_stops
  for select to anon, authenticated
  using (exists (select 1 from public.route_templates t
                 where t.id = template_id and (t.is_active or private.is_platform_admin())));
create policy route_template_stops_admin_write on public.route_template_stops
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

grant select on public.route_templates, public.route_template_stops to anon, authenticated;
grant insert, update, delete on public.route_templates, public.route_template_stops to authenticated;

-- ---------------------------------------------------------------------
-- admin_save_route_template: create (p_id null) or replace a route and its
-- stops atomically. p_stops is ordered, first = origin, last = destination:
--   [{name, city_id, is_boarding, is_dropping, arrival_offset_min, departure_offset_min}]
-- ---------------------------------------------------------------------
create or replace function public.admin_save_route_template(
  p_id uuid,
  p_name text,
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_distance_km numeric,
  p_est_duration_min integer,
  p_is_active boolean,
  p_stops jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := p_id;
  v_n integer;
  v_i integer := 0;
  v_stop jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Not authorized'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'A route name is required'; end if;
  if p_source_city_id is null or p_destination_city_id is null or p_source_city_id = p_destination_city_id then
    raise exception 'Origin and destination must be two different cities';
  end if;
  if jsonb_typeof(p_stops) <> 'array' then raise exception 'Stops must be an array'; end if;
  v_n := jsonb_array_length(p_stops);
  if v_n < 2 or v_n > 30 then raise exception 'A route needs between 2 and 30 stops'; end if;
  if not coalesce((p_stops -> 0 ->> 'is_boarding')::boolean, false) then
    raise exception 'The origin must be a boarding point';
  end if;
  if not coalesce((p_stops -> (v_n - 1) ->> 'is_dropping')::boolean, false) then
    raise exception 'The destination must be a dropping point';
  end if;

  if v_id is null then
    insert into public.route_templates (name, source_city_id, destination_city_id, distance_km, est_duration_min, is_active)
    values (btrim(p_name), p_source_city_id, p_destination_city_id, p_distance_km, p_est_duration_min, coalesce(p_is_active, true))
    returning id into v_id;
  else
    update public.route_templates
    set name = btrim(p_name), source_city_id = p_source_city_id, destination_city_id = p_destination_city_id,
        distance_km = p_distance_km, est_duration_min = p_est_duration_min, is_active = coalesce(p_is_active, true)
    where id = v_id;
    if not found then raise exception 'Route not found'; end if;
    delete from public.route_template_stops where template_id = v_id;
  end if;

  for v_stop in select * from jsonb_array_elements(p_stops) loop
    v_i := v_i + 1;
    if btrim(coalesce(v_stop ->> 'name', '')) = '' then raise exception 'Stop % has no name', v_i; end if;
    insert into public.route_template_stops (template_id, sequence_no, name, city_id, is_boarding, is_dropping,
                                             arrival_offset_min, departure_offset_min)
    values (v_id, v_i, btrim(v_stop ->> 'name'), nullif(v_stop ->> 'city_id', '')::uuid,
            coalesce((v_stop ->> 'is_boarding')::boolean, false), coalesce((v_stop ->> 'is_dropping')::boolean, false),
            nullif(v_stop ->> 'arrival_offset_min', '')::integer, nullif(v_stop ->> 'departure_offset_min', '')::integer);
  end loop;

  perform private.write_audit('route_template.saved', 'route_template', v_id, null,
                              jsonb_build_object('name', btrim(p_name), 'stops', v_n));
  return v_id;
end;
$$;

revoke execute on function public.admin_save_route_template(uuid, text, uuid, uuid, numeric, integer, boolean, jsonb) from public, anon;
grant execute on function public.admin_save_route_template(uuid, text, uuid, uuid, numeric, integer, boolean, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- save_bus_route now also accepts platform admins (so an admin can assign a
-- catalog route to a bus). Otherwise identical to the operator-facing version.
-- ---------------------------------------------------------------------
create or replace function public.save_bus_route(
  p_bus_id uuid,
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_distance_km numeric,
  p_departure_time time,
  p_duration_min integer,
  p_operating_days smallint[],
  p_stops jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc public.bus_services;
  v_route_id uuid;
  v_n integer;
  v_i integer := 0;
  v_stop jsonb;
  v_min_b integer;
  v_min_d integer;
  v_id uuid;
  v_src_name text;
  v_dst_name text;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
  if not (v_bus.lifecycle_status in ('draft', 'changes_requested') or v_bus.is_legacy) then
    raise exception 'The route is locked while the bus is %', v_bus.lifecycle_status;
  end if;

  if p_source_city_id is null or p_destination_city_id is null or p_source_city_id = p_destination_city_id then
    raise exception 'Origin and destination must be two different cities';
  end if;
  if p_departure_time is null then raise exception 'Departure time is required'; end if;
  if p_duration_min is null or p_duration_min < 1 then raise exception 'Estimated journey duration is required'; end if;
  if p_operating_days is null or coalesce(array_length(p_operating_days, 1), 0) = 0 then
    raise exception 'Select at least one operating day';
  end if;
  if jsonb_typeof(p_stops) <> 'array' then raise exception 'Stops must be an array'; end if;
  v_n := jsonb_array_length(p_stops);
  if v_n < 2 or v_n > 30 then raise exception 'A route needs between 2 and 30 stops'; end if;
  if not coalesce((p_stops -> 0 ->> 'is_boarding')::boolean, false) then
    raise exception 'The origin must be a boarding point';
  end if;
  if not coalesce((p_stops -> (v_n - 1) ->> 'is_dropping')::boolean, false) then
    raise exception 'The destination must be a dropping point';
  end if;

  select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);

  if v_svc.id is not null then
    v_route_id := v_svc.route_id;
    update public.bus_routes
    set source_city_id = p_source_city_id, destination_city_id = p_destination_city_id, distance_km = p_distance_km
    where id = v_route_id;
  else
    select id into v_route_id from public.bus_routes where bus_id = p_bus_id;
    if v_route_id is null then
      insert into public.bus_routes (operator_id, bus_id, source_city_id, destination_city_id, distance_km)
      values (v_bus.operator_id, p_bus_id, p_source_city_id, p_destination_city_id, p_distance_km)
      returning id into v_route_id;
    else
      update public.bus_routes
      set source_city_id = p_source_city_id, destination_city_id = p_destination_city_id, distance_km = p_distance_km
      where id = v_route_id;
    end if;
  end if;

  -- Park existing active rows out of the way of the unique (route, sequence) key.
  select least(coalesce(min(sequence_no), 0), 0) into v_min_b from public.boarding_points where route_id = v_route_id;
  select least(coalesce(min(sequence_no), 0), 0) into v_min_d from public.dropping_points where route_id = v_route_id;
  update public.boarding_points set sequence_no = sequence_no + 1000000 where route_id = v_route_id and sequence_no > 0;
  update public.dropping_points set sequence_no = sequence_no + 1000000 where route_id = v_route_id and sequence_no > 0;

  for v_stop in select * from jsonb_array_elements(p_stops) loop
    v_i := v_i + 1;
    if btrim(coalesce(v_stop ->> 'name', '')) = '' then
      raise exception 'Stop % has no name', v_i;
    end if;

    if coalesce((v_stop ->> 'is_boarding')::boolean, false) then
      v_id := nullif(v_stop ->> 'boarding_point_id', '')::uuid;
      if v_id is not null and exists (select 1 from public.boarding_points where id = v_id and route_id = v_route_id) then
        update public.boarding_points set
          name = btrim(v_stop ->> 'name'), address = nullif(v_stop ->> 'address', ''),
          latitude = nullif(v_stop ->> 'latitude', '')::numeric, longitude = nullif(v_stop ->> 'longitude', '')::numeric,
          city_id = nullif(v_stop ->> 'city_id', '')::uuid,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.boarding_points (route_id, name, address, latitude, longitude, city_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, btrim(v_stop ->> 'name'), nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric,
                nullif(v_stop ->> 'city_id', '')::uuid,
                nullif(v_stop ->> 'arrival_offset_min', '')::integer,
                nullif(v_stop ->> 'departure_offset_min', '')::integer, v_i);
      end if;
    end if;

    if coalesce((v_stop ->> 'is_dropping')::boolean, false) then
      v_id := nullif(v_stop ->> 'dropping_point_id', '')::uuid;
      if v_id is not null and exists (select 1 from public.dropping_points where id = v_id and route_id = v_route_id) then
        update public.dropping_points set
          name = btrim(v_stop ->> 'name'), address = nullif(v_stop ->> 'address', ''),
          latitude = nullif(v_stop ->> 'latitude', '')::numeric, longitude = nullif(v_stop ->> 'longitude', '')::numeric,
          city_id = nullif(v_stop ->> 'city_id', '')::uuid,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.dropping_points (route_id, name, address, latitude, longitude, city_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, btrim(v_stop ->> 'name'), nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric,
                nullif(v_stop ->> 'city_id', '')::uuid,
                nullif(v_stop ->> 'arrival_offset_min', '')::integer,
                nullif(v_stop ->> 'departure_offset_min', '')::integer, v_i);
      end if;
    end if;
  end loop;

  -- Anything still parked was removed by the operator: deactivate with unique negative sequence numbers.
  update public.boarding_points bp
  set is_active = false, sequence_no = v_min_b - x.rn
  from (select id, row_number() over (order by id) as rn from public.boarding_points
        where route_id = v_route_id and sequence_no >= 1000000) x
  where bp.id = x.id;
  update public.dropping_points dp
  set is_active = false, sequence_no = v_min_d - x.rn
  from (select id, row_number() over (order by id) as rn from public.dropping_points
        where route_id = v_route_id and sequence_no >= 1000000) x
  where dp.id = x.id;

  select name into v_src_name from public.cities where id = p_source_city_id;
  select name into v_dst_name from public.cities where id = p_destination_city_id;

  if v_svc.id is not null then
    update public.bus_services
    set service_source_city_id = p_source_city_id, service_dest_city_id = p_destination_city_id,
        default_departure_time = p_departure_time, default_arrival_offset_minutes = p_duration_min,
        est_duration_min = p_duration_min, operating_days = p_operating_days
    where id = v_svc.id;
  else
    insert into public.bus_services (
      operator_id, route_id, bus_id, service_name, service_source_city_id, service_dest_city_id,
      default_departure_time, default_arrival_offset_minutes, est_duration_min, operating_days, status
    ) values (
      v_bus.operator_id, v_route_id, p_bus_id,
      coalesce(v_bus.name, v_bus.registration_number) || ' ' || coalesce(v_src_name, '') || ' to ' || coalesce(v_dst_name, ''),
      p_source_city_id, p_destination_city_id, p_departure_time, p_duration_min, p_duration_min, p_operating_days,
      'paused'
    );
  end if;

  perform private.write_audit(
    'bus.route_saved', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'route_id', v_route_id, 'stops', v_n)
  );
  return public.validate_bus_route(p_bus_id);
end;
$$;

revoke execute on function public.save_bus_route(uuid, uuid, uuid, numeric, time, integer, smallint[], jsonb) from public, anon;
grant execute on function public.save_bus_route(uuid, uuid, uuid, numeric, time, integer, smallint[], jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- admin_assign_route_to_bus: copies a catalog route onto a bus. The origin
-- departs at p_departure_time; stop clock times follow from the offsets.
-- ---------------------------------------------------------------------
create or replace function public.admin_assign_route_to_bus(
  p_bus_id uuid,
  p_template_id uuid,
  p_departure_time time,
  p_operating_days smallint[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t public.route_templates;
  v_stops jsonb;
  v_duration integer;
begin
  if not private.is_platform_admin() then raise exception 'Not authorized'; end if;
  select * into v_t from public.route_templates where id = p_template_id;
  if v_t.id is null then raise exception 'Route not found'; end if;
  if not v_t.is_active then raise exception 'This route is inactive'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', name, 'city_id', city_id, 'is_boarding', is_boarding, 'is_dropping', is_dropping,
           'arrival_offset_min', arrival_offset_min, 'departure_offset_min', departure_offset_min)
         order by sequence_no), '[]'::jsonb)
  into v_stops from public.route_template_stops where template_id = p_template_id;

  v_duration := coalesce(v_t.est_duration_min,
                         (select max(coalesce(arrival_offset_min, departure_offset_min))
                          from public.route_template_stops where template_id = p_template_id));

  return public.save_bus_route(p_bus_id, v_t.source_city_id, v_t.destination_city_id, v_t.distance_km,
                               p_departure_time, v_duration, p_operating_days, v_stops);
end;
$$;

revoke execute on function public.admin_assign_route_to_bus(uuid, uuid, time, smallint[]) from public, anon;
grant execute on function public.admin_assign_route_to_bus(uuid, uuid, time, smallint[]) to authenticated;
