-- =========================================================================
-- Route map: stored road-following geometry per route + a trip map read.
--
-- Reuses existing structures only: stops come from boarding_points / dropping_points (grouped by
-- location, in travel order, like route_stops); each travel direction is already its own bus_routes
-- row (outbound / return), so a trip's route_id IS its direction. The only new table holds the
-- computed road geometry so it is calculated once per route change, never when a customer opens a trip.
--
-- Live position is NOT stored here: it stays in the existing tracking system
-- (vehicle_location_observations -> get_trip_tracking, tracker-first, allow_driver_fallback policy).
-- =========================================================================

create table public.route_geometries (
  route_id uuid primary key references public.bus_routes (id) on delete cascade,
  stops_hash text not null,                -- hash of the ordered stop coordinates this geometry was built from
  polyline6 text not null,                 -- encoded polyline, precision 6 (OSRM geometries=polyline6)
  distance_m numeric(12, 1),
  duration_s numeric(12, 1),
  provider text not null default 'osrm',
  computed_at timestamptz not null default now()
);
alter table public.route_geometries enable row level security;
revoke all on public.route_geometries from anon, authenticated;

-- Ordered stops of a route (one entry per location, first sequence wins), coordinates from the
-- stop point or, failing that, the location itself.
create or replace function private.route_map_stops(p_route_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with s as (
    select city_id, name, latitude, longitude, sequence_no, true as pickup, false as drop_
      from public.boarding_points where route_id = p_route_id and is_active and city_id is not null
    union all
    select city_id, name, latitude, longitude, sequence_no, false, true
      from public.dropping_points where route_id = p_route_id and is_active and city_id is not null
  ), g as (
    select city_id,
           min(sequence_no) as ord,
           bool_or(pickup) as pickup,
           bool_or(drop_) as drop_,
           (array_agg(name order by sequence_no))[1] as name,
           (array_agg(latitude order by (latitude is null), sequence_no))[1] as lat,
           (array_agg(longitude order by (latitude is null), sequence_no))[1] as lng
    from s group by city_id
  ), n as (
    select g.*, row_number() over (order by g.ord) as rn from g
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'location_id', n.city_id,
           'name', coalesce(l.name, n.name),
           'latitude', coalesce(n.lat, l.latitude),
           'longitude', coalesce(n.lng, l.longitude),
           'order', n.rn,
           'is_pickup', n.pickup,
           'is_drop', n.drop_) order by n.ord), '[]'::jsonb)
  from n
  left join public.locations l on l.id = n.city_id;
$$;
revoke execute on function private.route_map_stops(uuid) from public, anon, authenticated;

create or replace function private.route_stops_hash(p_route_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select md5(coalesce(string_agg(round((e ->> 'latitude')::numeric, 5)::text || ',' || round((e ->> 'longitude')::numeric, 5)::text, ';'
                                 order by (e ->> 'order')::int), ''))
  from jsonb_array_elements(private.route_map_stops(p_route_id)) e
  where e ->> 'latitude' is not null and e ->> 'longitude' is not null;
$$;
revoke execute on function private.route_stops_hash(uuid) from public, anon, authenticated;

-- The trip's map: direction, ordered stops, the customer's own pickup / drop, stored road geometry.
-- Same audience as get_trip_tracking: operator staff, platform admin, or a customer with a confirmed
-- booking on this trip.
create or replace function public.get_trip_route_map(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_route public.bus_routes;
  v_staff boolean;
  v_geo public.route_geometries;
  v_pick uuid;
  v_drop uuid;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  v_staff := private.is_operator_staff(v_trip.operator_id) or private.is_platform_admin();
  if not v_staff and not exists (
      select 1 from public.booking_items bi join public.bookings b on b.id = bi.booking_id
      where bi.trip_id = p_trip_id and b.customer_id = (select auth.uid()) and bi.status in ('confirmed', 'completed')) then
    raise exception 'Not authorized to view this trip';
  end if;

  select * into v_route from public.bus_routes where id = v_trip.route_id;
  select * into v_geo from public.route_geometries where route_id = v_trip.route_id;

  if not v_staff then
    select bp.city_id, dp.city_id into v_pick, v_drop
      from public.booking_items bi
      join public.bookings b on b.id = bi.booking_id
      left join public.boarding_points bp on bp.id = bi.boarding_point_id
      left join public.dropping_points dp on dp.id = bi.dropping_point_id
      where bi.trip_id = p_trip_id and b.customer_id = (select auth.uid()) and bi.status in ('confirmed', 'completed')
      limit 1;
  end if;

  return jsonb_build_object(
    'trip_id', p_trip_id,
    'route_id', v_trip.route_id,
    'direction', v_route.direction,
    'trip_status', v_trip.status,
    'stops', private.route_map_stops(v_trip.route_id),
    'my_pickup_location_id', v_pick,
    'my_drop_location_id', v_drop,
    'geometry', case when v_geo.route_id is null then null else jsonb_build_object(
        'polyline6', v_geo.polyline6, 'distance_m', v_geo.distance_m, 'duration_s', v_geo.duration_s,
        'computed_at', v_geo.computed_at,
        -- false when the stops changed after the geometry was built: the client must not draw it as the route
        'is_current', v_geo.stops_hash = private.route_stops_hash(v_trip.route_id)) end);
end;
$$;

-- Edge Function input (runs as the caller): who may (re)build a route's geometry, and what from.
create or replace function public.get_route_geometry_inputs(p_route_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_route public.bus_routes;
  v_geo public.route_geometries;
  v_hash text;
begin
  select * into v_route from public.bus_routes where id = p_route_id;
  if v_route.id is null then raise exception 'Route not found'; end if;
  if not (private.is_operator_staff(v_route.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized for this route';
  end if;
  v_hash := private.route_stops_hash(p_route_id);
  select * into v_geo from public.route_geometries where route_id = p_route_id;
  return jsonb_build_object(
    'route_id', p_route_id,
    'direction', v_route.direction,
    'stops_hash', v_hash,
    'is_current', v_geo.route_id is not null and v_geo.stops_hash = v_hash,
    'waypoints', (select coalesce(jsonb_agg(jsonb_build_object('latitude', e -> 'latitude', 'longitude', e -> 'longitude') order by (e ->> 'order')::int), '[]'::jsonb)
                  from jsonb_array_elements(private.route_map_stops(p_route_id)) e
                  where e ->> 'latitude' is not null and e ->> 'longitude' is not null));
end;
$$;

-- Edge Function output (service role only). Refuses geometry built from stops that have since changed.
create or replace function public.save_route_geometry(
  p_route_id uuid, p_stops_hash text, p_polyline6 text, p_distance_m numeric, p_duration_s numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_stops_hash is distinct from private.route_stops_hash(p_route_id) then
    return jsonb_build_object('saved', false, 'reason', 'stops_changed');
  end if;
  if coalesce(length(p_polyline6), 0) < 4 then
    return jsonb_build_object('saved', false, 'reason', 'empty_geometry');
  end if;
  insert into public.route_geometries (route_id, stops_hash, polyline6, distance_m, duration_s, computed_at)
  values (p_route_id, p_stops_hash, p_polyline6, p_distance_m, p_duration_s, now())
  on conflict (route_id) do update
    set stops_hash = excluded.stops_hash, polyline6 = excluded.polyline6, distance_m = excluded.distance_m,
        duration_s = excluded.duration_s, computed_at = now();
  return jsonb_build_object('saved', true);
end;
$$;

-- Tracking read: add speed / heading / accuracy of the exact fix the decision used (never for estimates).
create or replace function public.get_trip_tracking(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_staff boolean;
  v_events jsonb;
  v_dev jsonb := null;
  v_t jsonb;
  v_fix record;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  v_staff := private.is_operator_staff(v_trip.operator_id) or private.is_platform_admin();
  if not v_staff and not exists (
      select 1 from public.booking_items bi join public.bookings b on b.id = bi.booking_id
      where bi.trip_id = p_trip_id and b.customer_id = (select auth.uid()) and bi.status in ('confirmed', 'completed')) then
    raise exception 'Not authorized to track this trip';
  end if;

  select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) into v_events
  from (select recorded_at as at, jsonb_build_object('point_name', point_name, 'point_type', point_type, 'recorded_at', recorded_at) as j
        from public.bus_trip_events where trip_id = p_trip_id and event_type = 'milestone_arrived'
        order by recorded_at desc limit 20) x;

  if v_staff then
    select jsonb_build_object('name', d.name, 'activation_status', d.activation_status, 'connection_status', d.connection_status,
                              'last_communication_at', d.last_communication_at)
      into v_dev
      from public.bus_gps_assignments a join public.gps_devices d on d.id = a.device_id
      where a.bus_id = v_trip.bus_id and a.unassigned_at is null;
  end if;

  v_t := private.compute_tracking(p_trip_id);
  if v_t ->> 'source' in ('tracker', 'driver_device') and v_t ->> 'recorded_at' is not null then
    select o.speed_kmh, o.heading, o.accuracy_m into v_fix
      from public.vehicle_location_observations o
      where o.bus_id = v_trip.bus_id and o.source = v_t ->> 'source' and o.recorded_at = (v_t ->> 'recorded_at')::timestamptz
      order by o.id desc limit 1;
    v_t := v_t || jsonb_build_object('speed_kmh', v_fix.speed_kmh, 'heading', v_fix.heading, 'accuracy_m', v_fix.accuracy_m);
  end if;

  return v_t || jsonb_build_object(
    'trip_id', p_trip_id, 'trip_status', v_trip.status, 'as_of', now(),
    'milestones', v_events, 'device', v_dev);
end;
$$;

-- Driver phone fix: carry speed / heading, and stop writing when it cannot count or is too frequent.
drop function public.update_bus_location(uuid, numeric, numeric, numeric);
create or replace function public.update_bus_location(
  p_trip_id uuid, p_latitude numeric, p_longitude numeric, p_accuracy_m numeric default null,
  p_speed_kmh numeric default null, p_heading numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_bus public.buses;
  v_point record;
  v_milestone boolean := false;
  v_matched text;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  if not private.is_operator_staff(v_trip.operator_id) then raise exception 'Not authorized for this trip'; end if;
  if v_trip.status not in ('scheduled', 'boarding', 'departed') then
    raise exception 'Trip is not currently trackable (status: %)', v_trip.status;
  end if;
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_coordinates: latitude/longitude out of range';
  end if;
  select * into v_bus from public.buses where id = v_trip.bus_id;
  -- the phone is a fallback source: only where an admin enabled it for this bus
  if not coalesce(v_bus.allow_driver_fallback, false) then
    return jsonb_build_object('trip_id', p_trip_id, 'accepted', false, 'reason', 'driver_fallback_disabled');
  end if;
  -- at most one phone fix every 5 seconds per trip
  if exists (select 1 from public.vehicle_location_observations
             where bus_id = v_trip.bus_id and source = 'driver_device' and trip_id = p_trip_id and received_at > now() - interval '5 seconds') then
    return jsonb_build_object('trip_id', p_trip_id, 'accepted', false, 'reason', 'throttled');
  end if;

  insert into public.vehicle_location_observations (bus_id, trip_id, source, user_id, latitude, longitude, accuracy_m, speed_kmh, heading, recorded_at)
  values (v_trip.bus_id, p_trip_id, 'driver_device', (select auth.uid()), p_latitude, p_longitude, p_accuracy_m,
          case when p_speed_kmh >= 0 then p_speed_kmh end, case when p_heading >= 0 and p_heading < 360 then p_heading end, now());

  insert into public.bus_trip_events (trip_id, latitude, longitude, event_type)
  values (p_trip_id, p_latitude, p_longitude, 'location_update');

  for v_point in
    select name, latitude, longitude, 'boarding' as point_type from public.boarding_points where route_id = v_trip.route_id and latitude is not null
    union all
    select name, latitude, longitude, 'dropping' as point_type from public.dropping_points where route_id = v_trip.route_id and latitude is not null
  loop
    if private.haversine_km(p_latitude, p_longitude, v_point.latitude, v_point.longitude) <= 0.2
       and not exists (select 1 from public.bus_trip_events e
                       where e.trip_id = p_trip_id and e.event_type = 'milestone_arrived' and e.point_name = v_point.name
                         and e.recorded_at > now() - interval '10 minutes') then
      v_milestone := true;
      v_matched := v_point.name;
      insert into public.bus_trip_events (trip_id, latitude, longitude, event_type, point_name, point_type)
      values (p_trip_id, p_latitude, p_longitude, 'milestone_arrived', v_point.name, v_point.point_type);
    end if;
  end loop;

  perform private.refresh_trip_location(p_trip_id);
  return jsonb_build_object('trip_id', p_trip_id, 'accepted', true, 'milestone_reached', v_milestone, 'point_name', v_matched);
end;
$$;

revoke execute on function public.get_trip_route_map(uuid) from public, anon;
revoke execute on function public.get_route_geometry_inputs(uuid) from public, anon;
revoke execute on function public.save_route_geometry(uuid, text, text, numeric, numeric) from public, anon, authenticated;
revoke execute on function public.get_trip_tracking(uuid) from public, anon;
revoke execute on function public.update_bus_location(uuid, numeric, numeric, numeric, numeric, numeric) from public, anon;
grant execute on function public.get_trip_route_map(uuid) to authenticated;
grant execute on function public.get_route_geometry_inputs(uuid) to authenticated;
grant execute on function public.save_route_geometry(uuid, text, text, numeric, numeric) to service_role;
grant execute on function public.get_trip_tracking(uuid) to authenticated;
grant execute on function public.update_bus_location(uuid, numeric, numeric, numeric, numeric, numeric) to authenticated;
