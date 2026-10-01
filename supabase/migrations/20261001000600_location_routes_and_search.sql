-- =========================================================================
-- Location-aware routes and search.
--   * save_bus_route: every stop must be an approved main location, the route
--     starts / ends at its origin / destination, a location appears in one run,
--     and chosen master pickup / drop points must belong to the location and
--     allow pickup / drop. Stops record master_point_id.
--   * admin_save_route_template: catalog stops need a main location too.
--   * search_trips: optional exact pickup / drop point filters; only active main
--     locations are searchable.
--   * get_journey_points: the pickup / drop points actually served by buses on a
--     journey (service-specific), for the customer filter.
--   * search_cities lists main locations in display order.
-- =========================================================================

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
  v_city uuid;
  v_prev_city uuid;
  v_seen uuid[] := '{}';
  v_pt public.pickup_drop_points;
  v_idx integer := 0;
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


  -- Main-location validation: every stop is an active main location (or one the
  -- route already uses), the route starts and ends where it says, locations
  -- appear in one run each, and chosen master points belong to that location.
  for v_stop in select * from jsonb_array_elements(p_stops) loop
    v_idx := v_idx + 1;
    v_city := nullif(v_stop ->> 'city_id', '')::uuid;
    if v_city is null then
      raise exception 'Stop % needs a main location', v_idx;
    end if;
    if not exists (select 1 from public.cities c where c.id = v_city and c.display_order is not null) then
      raise exception 'Stop % is not a valid main location', v_idx;
    end if;
    if not exists (select 1 from public.cities c where c.id = v_city and c.is_active)
       and not exists (select 1 from public.boarding_points bp where bp.route_id = v_route_id and bp.city_id = v_city)
       and not exists (select 1 from public.dropping_points dp where dp.route_id = v_route_id and dp.city_id = v_city) then
      raise exception 'Stop % uses a location that is no longer active', v_idx;
    end if;
    if v_idx = 1 and v_city <> p_source_city_id then
      raise exception 'The first stop must be the origin location';
    end if;
    if v_idx = v_n and v_city <> p_destination_city_id then
      raise exception 'The last stop must be the destination location';
    end if;
    if v_city is distinct from v_prev_city then
      if v_city = any (v_seen) then
        raise exception 'A location can appear only once on a route (stop %)', v_idx;
      end if;
      v_seen := v_seen || v_city;
    end if;
    v_prev_city := v_city;

    if nullif(v_stop ->> 'master_point_id', '') is not null then
      select * into v_pt from public.pickup_drop_points where id = (v_stop ->> 'master_point_id')::uuid;
      if v_pt.id is null then
        raise exception 'Stop %: pickup / drop point not found', v_idx;
      end if;
      if v_pt.main_location_id <> v_city then
        raise exception 'Stop %: the point does not belong to the selected location', v_idx;
      end if;
      if not v_pt.is_active
         and not exists (select 1 from public.boarding_points bp where bp.route_id = v_route_id and bp.master_point_id = v_pt.id)
         and not exists (select 1 from public.dropping_points dp where dp.route_id = v_route_id and dp.master_point_id = v_pt.id) then
        raise exception 'Stop %: the point is no longer active', v_idx;
      end if;
      if coalesce((v_stop ->> 'is_boarding')::boolean, false) and not v_pt.is_pickup_allowed then
        raise exception 'Stop %: pickup is not allowed at this point', v_idx;
      end if;
      if coalesce((v_stop ->> 'is_dropping')::boolean, false) and not v_pt.is_drop_allowed then
        raise exception 'Stop %: drop is not allowed at this point', v_idx;
      end if;
    end if;
  end loop;

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
          master_point_id = nullif(v_stop ->> 'master_point_id', '')::uuid,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.boarding_points (route_id, name, address, latitude, longitude, city_id, master_point_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, btrim(v_stop ->> 'name'), nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric,
                nullif(v_stop ->> 'city_id', '')::uuid, nullif(v_stop ->> 'master_point_id', '')::uuid,
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
          master_point_id = nullif(v_stop ->> 'master_point_id', '')::uuid,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.dropping_points (route_id, name, address, latitude, longitude, city_id, master_point_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, btrim(v_stop ->> 'name'), nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric,
                nullif(v_stop ->> 'city_id', '')::uuid, nullif(v_stop ->> 'master_point_id', '')::uuid,
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
    if nullif(v_stop ->> 'city_id', '') is null then raise exception 'Stop % needs a main location', v_i; end if;
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

drop function private.trip_fare_range(uuid, uuid, uuid);
create or replace function private.trip_fare_range(
  p_trip_id uuid, p_src_city_id uuid, p_dst_city_id uuid,
  p_pickup_point_id uuid default null, p_drop_point_id uuid default null
)
returns table (min_cents integer, max_cents integer)
language sql
stable
security definer
set search_path = ''
as $$
  with trip as (
    select t.id, t.service_id, t.route_id, t.travel_date, sv.service_source_city_id as src, sv.service_dest_city_id as dst,
           (r.bus_id is not null) as wizard
    from public.bus_trips t
    join public.bus_services sv on sv.id = t.service_id
    join public.bus_routes r on r.id = t.route_id
    where t.id = p_trip_id
  ),
  pairs as (
    select b.id as b_id, d.id as d_id
    from trip tr
    join public.boarding_points b on b.route_id = tr.route_id and b.is_active
    join public.dropping_points d on d.route_id = tr.route_id and d.is_active
    where coalesce(b.city_id, tr.src) = p_src_city_id
      and coalesce(d.city_id, tr.dst) = p_dst_city_id
      and (not tr.wizard or d.sequence_no > b.sequence_no)
      and (p_pickup_point_id is null or b.master_point_id = p_pickup_point_id)
      and (p_drop_point_id is null or d.master_point_id = p_drop_point_id)
  ),
  chosen as (
    select b_id, d_id from pairs
    union all
    select null::uuid, null::uuid where not exists (select 1 from pairs)
  ),
  seats as (
    select ts.seat_id, ts.fare_cents
    from public.trip_seats ts
    where ts.trip_id = p_trip_id
      and (ts.status = 'available'
           or not exists (select 1 from public.trip_seats x where x.trip_id = p_trip_id and x.status = 'available'))
  ),
  fares as (
    select private.resolve_seat_fare(tr.service_id, tr.travel_date, s.seat_id, c.b_id, c.d_id, s.fare_cents) as f
    from trip tr cross join chosen c cross join seats s
  )
  select min(f)::integer, max(f)::integer from fares;
$$;

revoke execute on function private.trip_fare_range(uuid, uuid, uuid, uuid, uuid) from public;
grant execute on function private.trip_fare_range(uuid, uuid, uuid, uuid, uuid) to anon, authenticated;

drop function public.search_trips(uuid, uuid, date);
create or replace function public.search_trips(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date,
  p_pickup_point_id uuid default null,
  p_drop_point_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_direct jsonb;
  v_connected jsonb;
begin
  -- Only active main locations are searchable.
  if not exists (select 1 from public.cities where id = p_source_city_id and is_active and display_order is not null)
     or not exists (select 1 from public.cities where id = p_destination_city_id and is_active and display_order is not null) then
    return jsonb_build_object('direct', '[]'::jsonb, 'connected', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'trip_id', t.id,
    'service_id', sv.id,
    'operator_id', o.id,
    'operator_name', o.name,
    'operator_rating', o.rating,
    'bus_id', bs.id,
    'bus_type', bs.bus_type,
    'amenities', bs.amenities,
    'departure_at', t.departure_at,
    'arrival_at', t.arrival_at,
    'available_seats', t.available_seats,
    'min_fare_cents', fr.min_cents,
    'max_fare_cents', fr.max_cents,
    'currency_code', t.currency_code
  ) order by t.departure_at), '[]'::jsonb)
  into v_direct
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  join public.operators o on o.id = t.operator_id
  join public.buses bs on bs.id = t.bus_id
  join public.bus_routes r on r.id = t.route_id
  cross join lateral private.trip_fare_range(t.id, p_source_city_id, p_destination_city_id, p_pickup_point_id, p_drop_point_id) fr
  where t.travel_date = p_travel_date
    and t.status = 'scheduled'
    and private.is_bus_bookable(t.bus_id)
    and (
      (sv.service_source_city_id = p_source_city_id and sv.service_dest_city_id = p_destination_city_id)
      or exists (
        select 1
        from public.boarding_points b
        join public.dropping_points d on d.route_id = b.route_id
        where b.route_id = t.route_id and b.is_active and d.is_active
          and b.city_id = p_source_city_id and d.city_id = p_destination_city_id
          and r.bus_id is not null and d.sequence_no > b.sequence_no
      )
    )
    -- Exact pickup / drop filter: the route must serve those master points, in order.
    and (
      (p_pickup_point_id is null and p_drop_point_id is null)
      or exists (
        select 1
        from public.boarding_points b
        join public.dropping_points d on d.route_id = b.route_id
        where b.route_id = t.route_id and b.is_active and d.is_active
          and (p_pickup_point_id is null or b.master_point_id = p_pickup_point_id)
          and (p_drop_point_id is null or d.master_point_id = p_drop_point_id)
          and coalesce(b.city_id, sv.service_source_city_id) = p_source_city_id
          and coalesce(d.city_id, sv.service_dest_city_id) = p_destination_city_id
          and d.sequence_no > b.sequence_no
      )
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'transfer_city_id', s1.service_dest_city_id,
    'leg1', jsonb_build_object(
      'trip_id', t1.id, 'service_id', s1.id, 'operator_id', o1.id, 'operator_name', o1.name,
      'departure_at', t1.departure_at, 'arrival_at', t1.arrival_at,
      'min_fare_cents', f1.min_cents, 'available_seats', t1.available_seats
    ),
    'leg2', jsonb_build_object(
      'trip_id', t2.id, 'service_id', s2.id, 'operator_id', o2.id, 'operator_name', o2.name,
      'departure_at', t2.departure_at, 'arrival_at', t2.arrival_at,
      'min_fare_cents', f2.min_cents, 'available_seats', t2.available_seats
    ),
    'total_min_fare_cents', coalesce(f1.min_cents, 0) + coalesce(f2.min_cents, 0)
  ) order by t1.departure_at), '[]'::jsonb)
  into v_connected
  from public.bus_services s1
  join public.bus_trips t1 on t1.service_id = s1.id
    and t1.travel_date = p_travel_date
    and t1.status = 'scheduled'
  join public.operators o1 on o1.id = t1.operator_id
  join public.bus_services s2 on s2.service_source_city_id = s1.service_dest_city_id
    and s2.service_dest_city_id = p_destination_city_id
  join public.bus_trips t2 on t2.service_id = s2.id
    and t2.status = 'scheduled'
    and t2.travel_date between p_travel_date and p_travel_date + 1
  join public.operators o2 on o2.id = t2.operator_id
  cross join lateral private.trip_fare_range(t1.id, s1.service_source_city_id, s1.service_dest_city_id) f1
  cross join lateral private.trip_fare_range(t2.id, s2.service_source_city_id, s2.service_dest_city_id) f2
  where s1.service_source_city_id = p_source_city_id
    and private.is_bus_bookable(t1.bus_id)
    and private.is_bus_bookable(t2.bus_id)
    and p_pickup_point_id is null and p_drop_point_id is null
    and t2.departure_at >= t1.arrival_at + interval '15 minutes'
    and t2.departure_at <= t1.arrival_at + interval '6 hours';

  return jsonb_build_object('direct', v_direct, 'connected', v_connected);
end;
$$;

revoke execute on function public.search_trips(uuid, uuid, date, uuid, uuid) from public;
grant execute on function public.search_trips(uuid, uuid, date, uuid, uuid) to anon, authenticated;

-- Pickup / drop points served by scheduled, bookable buses between two main
-- locations (optionally on one date). Only master points that a route actually
-- uses appear, so customers never see a point no bus serves.
create or replace function public.get_journey_points(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with trips as (
    select distinct t.route_id, sv.service_source_city_id as src, sv.service_dest_city_id as dst
    from public.bus_trips t
    join public.bus_services sv on sv.id = t.service_id
    where t.status = 'scheduled'
      and (p_travel_date is null or t.travel_date = p_travel_date)
      and private.is_bus_bookable(t.bus_id)
  ),
  pairs as (
    select b.master_point_id as b_pt, d.master_point_id as d_pt
    from trips tr
    join public.boarding_points b on b.route_id = tr.route_id and b.is_active
    join public.dropping_points d on d.route_id = tr.route_id and d.is_active and d.sequence_no > b.sequence_no
    where coalesce(b.city_id, tr.src) = p_source_city_id
      and coalesce(d.city_id, tr.dst) = p_destination_city_id
  )
  select jsonb_build_object(
    'pickup', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'landmark', p.landmark, 'main_location_id', p.main_location_id)
                       order by p.display_order, p.name)
      from public.pickup_drop_points p
      where p.is_active and p.id in (select b_pt from pairs where b_pt is not null)), '[]'::jsonb),
    'drop', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'landmark', p.landmark, 'main_location_id', p.main_location_id)
                       order by p.display_order, p.name)
      from public.pickup_drop_points p
      where p.is_active and p.id in (select d_pt from pairs where d_pt is not null)), '[]'::jsonb)
  );
$$;

revoke execute on function public.get_journey_points(uuid, uuid, date) from public;
grant execute on function public.get_journey_points(uuid, uuid, date) to anon, authenticated;

create or replace function public.search_cities(p_query text default '', p_limit integer default 10)
returns setof public.cities
language sql
stable
set search_path = ''
as $$
  select c.*
  from public.cities c
  where c.is_active and c.display_order is not null
  order by
    case when p_query is null or p_query = '' then c.display_order
         else 0 end,
    case when p_query is null or p_query = '' then 0 else extensions.similarity(c.name, p_query) end desc,
    c.name asc
  limit greatest(p_limit, 1);
$$;
