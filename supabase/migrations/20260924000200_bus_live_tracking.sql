-- =========================================================================
-- Bus live tracking: GPS coordinate matching against boarding/dropping
-- points, mirroring the cargo tracking design (update_cargo_location /
-- track_cargo_shipment) from Phase 4. No external maps API — pure
-- coordinate math, per the plan.
-- =========================================================================

alter table public.bus_trips
  add column current_latitude numeric(10, 7),
  add column current_longitude numeric(10, 7),
  add column last_location_update timestamptz;

create table public.bus_trip_events (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.bus_trips (id) on delete cascade,
  latitude numeric(10, 7) not null,
  longitude numeric(10, 7) not null,
  event_type text not null check (event_type in ('location_update', 'milestone_arrived')),
  point_name text,
  point_type text check (point_type in ('boarding', 'dropping')),
  recorded_at timestamptz not null default now()
);

create index bus_trip_events_trip_id_idx on public.bus_trip_events (trip_id, recorded_at desc);

alter table public.bus_trip_events enable row level security;

create policy bus_trip_events_select on public.bus_trip_events
  for select to authenticated
  using (
    exists (
      select 1 from public.bus_trips t
      where t.id = bus_trip_events.trip_id and private.is_operator_staff(t.operator_id)
    )
    or exists (
      select 1 from public.booking_items bi
      where bi.trip_id = bus_trip_events.trip_id and bi.booking_id in (
        select id from public.bookings where customer_id = (select auth.uid())
      )
    )
    or private.is_platform_admin()
  );

create policy bus_trip_events_admin_all on public.bus_trip_events
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
-- No client insert policy: rows are written only by update_bus_location() (SECURITY DEFINER, below).

-- Operator's driver/conductor phone pings GPS periodically while the trip is
-- in progress. Geofence-matches against every boarding/dropping point on the
-- trip's route (~200m radius) to auto-log arrival milestones.
create or replace function public.update_bus_location(p_trip_id uuid, p_latitude numeric, p_longitude numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_point record;
  v_distance_km numeric;
  v_milestone boolean := false;
  v_matched_point_name text;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then
    raise exception 'Trip not found';
  end if;
  if not private.is_operator_staff(v_trip.operator_id) then
    raise exception 'Not authorized for this trip';
  end if;
  if v_trip.status not in ('scheduled', 'boarding', 'departed') then
    raise exception 'Trip is not currently trackable (status: %)', v_trip.status;
  end if;

  update public.bus_trips
  set current_latitude = p_latitude, current_longitude = p_longitude, last_location_update = now()
  where id = p_trip_id;

  insert into public.bus_trip_events (trip_id, latitude, longitude, event_type)
  values (p_trip_id, p_latitude, p_longitude, 'location_update');

  for v_point in
    select name, latitude, longitude, 'boarding' as point_type from public.boarding_points where route_id = v_trip.route_id and latitude is not null
    union all
    select name, latitude, longitude, 'dropping' as point_type from public.dropping_points where route_id = v_trip.route_id and latitude is not null
  loop
    v_distance_km := private.haversine_km(p_latitude, p_longitude, v_point.latitude, v_point.longitude);
    if v_distance_km <= 0.2 then
      v_milestone := true;
      v_matched_point_name := v_point.name;
      insert into public.bus_trip_events (trip_id, latitude, longitude, event_type, point_name, point_type)
      values (p_trip_id, p_latitude, p_longitude, 'milestone_arrived', v_point.name, v_point.point_type);
    end if;
  end loop;

  return jsonb_build_object('trip_id', p_trip_id, 'milestone_reached', v_milestone, 'point_name', v_matched_point_name);
end;
$$;

-- Customer/operator tracking read: current position + recent event timeline.
create or replace function public.track_bus_trip(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_events jsonb;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then
    raise exception 'Trip not found';
  end if;

  if not private.is_operator_staff(v_trip.operator_id)
    and not private.is_platform_admin()
    and not exists (
      select 1 from public.booking_items bi
      join public.bookings b on b.id = bi.booking_id
      where bi.trip_id = p_trip_id and b.customer_id = (select auth.uid())
    ) then
    raise exception 'Not authorized to track this trip';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'event_type', event_type, 'point_name', point_name, 'point_type', point_type,
    'latitude', latitude, 'longitude', longitude, 'recorded_at', recorded_at
  ) order by recorded_at desc), '[]'::jsonb)
  into v_events
  from public.bus_trip_events
  where trip_id = p_trip_id
  limit 50;

  return jsonb_build_object(
    'trip_id', v_trip.id,
    'status', v_trip.status,
    'live_tracking_enabled', v_trip.live_tracking_enabled,
    'current_latitude', v_trip.current_latitude,
    'current_longitude', v_trip.current_longitude,
    'last_location_update', v_trip.last_location_update,
    'events', v_events
  );
end;
$$;

revoke execute on function public.update_bus_location(uuid, numeric, numeric) from public, anon;
revoke execute on function public.track_bus_trip(uuid) from public, anon;
grant execute on function public.update_bus_location(uuid, numeric, numeric) to authenticated;
grant execute on function public.track_bus_trip(uuid) to authenticated;
