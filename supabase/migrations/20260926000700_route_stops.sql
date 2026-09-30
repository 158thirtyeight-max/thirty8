-- =========================================================================
-- Per-bus route, stops, boarding/dropping points (Phase 8)
--
-- A route is owned by a bus (bus_routes.bus_id) so two buses on the same
-- corridor can have different stops and times. The bus's `bus_services` row
-- is the bus/route/schedule anchor. Boarding and dropping points stay in the
-- existing tables (booking_items reference them); stops that are both a
-- boarding and a dropping point get a row in each with the same sequence_no.
--
-- Existing (legacy) routes have bus_id null and keep working unchanged.
-- =========================================================================

alter table public.bus_routes
  add column bus_id uuid references public.buses (id) on delete cascade;

-- One route per bus; legacy routes (no bus) keep the old per-corridor uniqueness.
do $$
declare v_name text;
begin
  select c.conname into v_name
  from pg_constraint c
  where c.conrelid = 'public.bus_routes'::regclass and c.contype = 'u'
    and (select array_agg(a.attname::text order by a.attname::text)
         from unnest(c.conkey) k join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k)
        = array['destination_city_id', 'operator_id', 'source_city_id'];
  if v_name is not null then
    execute format('alter table public.bus_routes drop constraint %I', v_name);
  end if;
end $$;

create unique index bus_routes_legacy_corridor_uniq
  on public.bus_routes (operator_id, source_city_id, destination_city_id) where bus_id is null;
create unique index bus_routes_one_per_bus_uniq on public.bus_routes (bus_id) where bus_id is not null;

alter table public.boarding_points
  add column arrival_offset_min integer check (arrival_offset_min is null or arrival_offset_min >= 0),
  add column departure_offset_min integer check (departure_offset_min is null or departure_offset_min >= 0),
  add column city_id uuid references public.cities (id);
alter table public.dropping_points
  add column arrival_offset_min integer check (arrival_offset_min is null or arrival_offset_min >= 0),
  add column departure_offset_min integer check (departure_offset_min is null or departure_offset_min >= 0),
  add column city_id uuid references public.cities (id);

create index boarding_points_city_id_idx on public.boarding_points (city_id) where city_id is not null;
create index dropping_points_city_id_idx on public.dropping_points (city_id) where city_id is not null;

alter table public.bus_services
  add column operating_days smallint[] not null default '{1,2,3,4,5,6,7}',
  add column est_duration_min integer check (est_duration_min is null or est_duration_min > 0),
  add constraint bus_services_operating_days_chk
    check (operating_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]);

-- ISO weekdays: 1 = Monday ... 7 = Sunday.

-- The bus's primary service (oldest); legacy buses may have several services.
create or replace function private.bus_primary_service(p_bus_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.bus_services where bus_id = p_bus_id order by created_at, id limit 1;
$$;

revoke execute on function private.bus_primary_service(uuid) from public, anon;
grant execute on function private.bus_primary_service(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Validation of a bus's route setup. Returns {valid, errors[], stats}.
-- ---------------------------------------------------------------------
create or replace function public.validate_bus_route(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc public.bus_services;
  v_route public.bus_routes;
  v_errors text[] := '{}';
  v_stops integer;
  v_boarding integer;
  v_dropping integer;
  v_n integer;
  v_last_end integer;
  r record;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then
    raise exception 'Bus not found';
  end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);
  if v_svc.id is null then
    return jsonb_build_object('valid', false, 'errors', jsonb_build_array('No route has been configured'),
                              'stats', jsonb_build_object('stops', 0, 'boarding', 0, 'dropping', 0));
  end if;
  select * into v_route from public.bus_routes where id = v_svc.route_id;

  if v_route.source_city_id = v_route.destination_city_id then
    v_errors := array_append(v_errors, 'Origin and destination must be different');
  end if;
  if v_svc.est_duration_min is null or v_svc.est_duration_min < 1 then
    v_errors := array_append(v_errors, 'Estimated journey duration is missing');
  end if;
  if coalesce(array_length(v_svc.operating_days, 1), 0) = 0 then
    v_errors := array_append(v_errors, 'No operating days are selected');
  end if;

  select count(*) into v_boarding from public.boarding_points where route_id = v_route.id and is_active;
  select count(*) into v_dropping from public.dropping_points where route_id = v_route.id and is_active;
  if v_boarding = 0 then v_errors := array_append(v_errors, 'At least one boarding point is required'); end if;
  if v_dropping = 0 then v_errors := array_append(v_errors, 'At least one dropping point is required'); end if;

  -- Stop sequence and timing, in travel order (a stop may appear as boarding, dropping or both).
  with s as (
    select sequence_no, name, arrival_offset_min, departure_offset_min from public.boarding_points
      where route_id = v_route.id and is_active
    union all
    select sequence_no, name, arrival_offset_min, departure_offset_min from public.dropping_points
      where route_id = v_route.id and is_active
  )
  select count(distinct sequence_no) into v_stops from s;
  if v_stops < 2 then v_errors := array_append(v_errors, 'A route needs at least an origin and a destination stop'); end if;

  select count(*) into v_n from (
    select sequence_no from public.boarding_points where route_id = v_route.id and is_active and (name is null or btrim(name) = '')
    union all
    select sequence_no from public.dropping_points where route_id = v_route.id and is_active and (name is null or btrim(name) = '')
  ) x;
  if v_n > 0 then v_errors := v_errors || format('%s stop(s) have no name', v_n); end if;

  select count(*) into v_n from (
    select 1 from public.boarding_points where route_id = v_route.id and is_active and (departure_offset_min is null)
    union all
    select 1 from public.dropping_points where route_id = v_route.id and is_active and (arrival_offset_min is null)
  ) x;
  if v_n > 0 then v_errors := array_append(v_errors, 'Arrival / departure times are missing for some stops'); end if;

  v_last_end := null;
  for r in
    select seq,
           min(arrival_offset_min) as arr,
           coalesce(max(departure_offset_min), min(arrival_offset_min)) as dep
    from (
      select sequence_no as seq, arrival_offset_min, departure_offset_min from public.boarding_points where route_id = v_route.id and is_active
      union all
      select sequence_no, arrival_offset_min, departure_offset_min from public.dropping_points where route_id = v_route.id and is_active
    ) t
    group by seq order by seq
  loop
    if r.arr is not null and v_last_end is not null and r.arr < v_last_end then
      v_errors := v_errors || format('Stop %s is reached before the previous stop is left', r.seq);
    end if;
    if r.arr is not null and r.dep is not null and r.dep < r.arr then
      v_errors := v_errors || format('Stop %s departs before it arrives', r.seq);
    end if;
    v_last_end := coalesce(r.dep, r.arr, v_last_end);
  end loop;

  if v_svc.est_duration_min is not null and v_last_end is not null and v_last_end > v_svc.est_duration_min then
    v_errors := array_append(v_errors, 'Stop times run past the estimated journey duration');
  end if;

  return jsonb_build_object(
    'valid', coalesce(array_length(v_errors, 1), 0) = 0,
    'errors', to_jsonb(v_errors),
    'stats', jsonb_build_object('stops', v_stops, 'boarding', v_boarding, 'dropping', v_dropping,
                                'route_id', v_route.id, 'service_id', v_svc.id)
  );
end;
$$;

revoke execute on function public.validate_bus_route(uuid) from public, anon;
grant execute on function public.validate_bus_route(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- save_bus_route: creates/updates the bus's route, its stops, and its service
-- anchor (origin departure time, duration, operating days) atomically.
-- p_stops is ordered, first = origin (boarding), last = destination (dropping):
--   [{name, address, latitude, longitude, city_id, is_boarding, is_dropping,
--     arrival_offset_min, departure_offset_min, boarding_point_id, dropping_point_id}]
-- Points that were removed are deactivated (never deleted) so past bookings
-- keep their references.
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
  if not private.is_operator_staff(v_bus.operator_id) then raise exception 'Not authorized'; end if;
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
