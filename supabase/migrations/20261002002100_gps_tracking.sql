-- =========================================================================
-- GPS tracking: provider-neutral device registry, location observations, source priority.
--
-- No GPS hardware/provider is selected yet, so NOTHING here claims a device is connected:
--   * gps_devices + bus_gps_assignments: a device is registered, assigned to ONE bus (one active
--     assignment per device and per bus), activated by an admin with a provider, and only becomes
--     "online" when the ingest path actually receives a fix. provider_config_ref names a server-side
--     secret; credentials are never stored or readable by clients.
--   * vehicle_location_observations: every fix with its source (tracker | driver_device |
--     passenger_assisted). No client can read this table.
--   * Source priority (private.compute_tracking):
--       1 fresh tracker -> 2 fresh driver device (only if an admin enabled the fallback for the bus)
--       -> 3 aggregated passenger-assisted estimate (feature flag + strict conditions)
--       -> 4 last known, marked stale -> 5 offline / not started / not configured.
--     A passenger phone never replaces a working tracker and never proves boarding.
--   * Passenger-assisted location is consent based, limited to the trip window, exposed only as an
--     aggregate, and purged after the trip. The feature flag defaults to OFF.
-- Thresholds live in platform_settings (admin-editable), not in code.
-- =========================================================================

-- ---------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------
create table public.platform_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now()
);
alter table public.platform_settings enable row level security;
create policy platform_settings_admin_select on public.platform_settings
  for select to authenticated using (private.is_platform_admin());
revoke all on public.platform_settings from anon, authenticated;
grant select on public.platform_settings to authenticated;

insert into public.platform_settings (key, value) values
  ('tracker_fresh_seconds', '120'),
  ('tracker_offline_seconds', '900'),
  ('passenger_tracking_enabled', 'false'),
  ('passenger_min_users', '3'),
  ('passenger_max_age_seconds', '60'),
  ('passenger_max_accuracy_m', '50'),
  ('passenger_cluster_radius_m', '150'),
  ('passenger_corridor_m', '300'),
  ('passenger_sample_min_interval_seconds', '10');

create or replace function private.setting_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::numeric from public.platform_settings where key = p_key), p_default)
$$;
create or replace function private.setting_bool(p_key text, p_default boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::boolean from public.platform_settings where key = p_key), p_default)
$$;
revoke execute on function private.setting_num(text, numeric) from public, anon, authenticated;
revoke execute on function private.setting_bool(text, boolean) from public, anon, authenticated;

create or replace function public.admin_set_platform_setting(p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  if p_key not in (select key from public.platform_settings) then raise exception 'Unknown setting %', p_key; end if;
  update public.platform_settings set value = p_value, updated_by = (select auth.uid()), updated_at = now() where key = p_key;
  perform private.write_audit('platform_setting.set', 'platform_setting', null, null, jsonb_build_object('key', p_key, 'value', p_value));
end;
$$;
revoke execute on function public.admin_set_platform_setting(text, jsonb) from public, anon;
grant execute on function public.admin_set_platform_setting(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- devices + assignments
-- ---------------------------------------------------------------------
create table public.gps_devices (
  id uuid primary key default gen_random_uuid(),
  name text,
  provider text,
  integration_type text,
  device_identifier text not null,
  imei text check (imei is null or imei ~ '^[0-9]{15}$'),
  serial_no text,
  sim_ref text,
  installed_on date,
  activation_status text not null default 'registered' check (activation_status in ('registered', 'active', 'inactive', 'retired')),
  connection_status text not null default 'never_connected' check (connection_status in ('never_connected', 'online', 'offline', 'error')),
  last_communication_at timestamptz,
  last_error text,
  notes text,
  provider_config_ref text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index gps_devices_identifier_idx on public.gps_devices (coalesce(provider, ''), device_identifier);
create trigger set_updated_at before update on public.gps_devices for each row execute function private.set_updated_at();
alter table public.gps_devices enable row level security;
create policy gps_devices_admin_select on public.gps_devices for select to authenticated using (private.is_platform_admin());
revoke all on public.gps_devices from anon, authenticated;
-- no client grant: admins read through admin_list_gps_devices, operators through get_bus_gps_status

create table public.bus_gps_assignments (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.gps_devices (id) on delete cascade,
  bus_id uuid not null references public.buses (id) on delete cascade,
  assigned_by uuid references public.profiles (id),
  assigned_at timestamptz not null default now(),
  unassigned_at timestamptz
);
-- one tracker per bus and one bus per tracker, at a time
create unique index bus_gps_one_active_per_device on public.bus_gps_assignments (device_id) where unassigned_at is null;
create unique index bus_gps_one_active_per_bus on public.bus_gps_assignments (bus_id) where unassigned_at is null;
alter table public.bus_gps_assignments enable row level security;
create policy bus_gps_assignments_admin_select on public.bus_gps_assignments for select to authenticated using (private.is_platform_admin());
revoke all on public.bus_gps_assignments from anon, authenticated;

create table public.gps_integration_events (
  id bigserial primary key,
  device_id uuid references public.gps_devices (id) on delete cascade,
  level text not null check (level in ('info', 'warning', 'error')),
  message text not null,
  created_at timestamptz not null default now()
);
create index gps_integration_events_idx on public.gps_integration_events (device_id, created_at desc);
alter table public.gps_integration_events enable row level security;
create policy gps_integration_events_admin_select on public.gps_integration_events for select to authenticated using (private.is_platform_admin());
revoke all on public.gps_integration_events from anon, authenticated;

alter table public.buses add column allow_driver_fallback boolean not null default false;
alter table public.bus_trips
  add column location_source text check (location_source in ('tracker', 'driver_device', 'passenger_assisted')),
  add column location_status text,
  add column location_confidence numeric(3, 2);

-- ---------------------------------------------------------------------
-- observations + consent (no client access)
-- ---------------------------------------------------------------------
create table public.vehicle_location_observations (
  id bigserial primary key,
  bus_id uuid not null references public.buses (id) on delete cascade,
  trip_id uuid references public.bus_trips (id) on delete cascade,
  source text not null check (source in ('tracker', 'driver_device', 'passenger_assisted')),
  device_id uuid references public.gps_devices (id) on delete set null,
  user_id uuid references public.profiles (id) on delete cascade,
  latitude numeric(9, 6) not null check (latitude between -90 and 90),
  longitude numeric(9, 6) not null check (longitude between -180 and 180),
  accuracy_m numeric(8, 1) check (accuracy_m is null or accuracy_m >= 0),
  speed_kmh numeric(6, 1),
  heading numeric(5, 1),
  recorded_at timestamptz not null,
  received_at timestamptz not null default now(),
  constraint obs_passenger_has_user check (source <> 'passenger_assisted' or (user_id is not null and trip_id is not null))
);
create index vlo_bus_time_idx on public.vehicle_location_observations (bus_id, source, recorded_at desc);
create index vlo_trip_pax_idx on public.vehicle_location_observations (trip_id, recorded_at desc) where source = 'passenger_assisted';
alter table public.vehicle_location_observations enable row level security;
revoke all on public.vehicle_location_observations from anon, authenticated;

create table public.passenger_location_consent (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  trip_id uuid not null references public.bus_trips (id) on delete cascade,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  purpose_version integer not null default 1,
  unique (user_id, trip_id)
);
alter table public.passenger_location_consent enable row level security;
create policy plc_select_own on public.passenger_location_consent for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.passenger_location_consent from anon, authenticated;
grant select on public.passenger_location_consent to authenticated;

-- ---------------------------------------------------------------------
-- geometry helper
-- ---------------------------------------------------------------------
create or replace function private.dist_to_segment_m(p_lat numeric, p_lng numeric, a_lat numeric, a_lng numeric, b_lat numeric, b_lng numeric)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  kx numeric := 111320 * cos(radians(p_lat));
  ky numeric := 110540;
  ax numeric := (a_lng - p_lng) * kx; ay numeric := (a_lat - p_lat) * ky;
  bx numeric := (b_lng - p_lng) * kx; by_ numeric := (b_lat - p_lat) * ky;
  dx numeric := bx - ax; dy numeric := by_ - ay;
  t numeric;
begin
  if dx = 0 and dy = 0 then return sqrt(ax * ax + ay * ay); end if;
  t := greatest(0, least(1, -(ax * dx + ay * dy) / (dx * dx + dy * dy)));
  return sqrt(power(ax + t * dx, 2) + power(ay + t * dy, 2));
end;
$$;

-- distance (m) from a point to the trip's route polyline made of stops that have coordinates;
-- null when fewer than 2 stops have coordinates (the corridor cannot be verified).
create or replace function private.dist_to_route_m(p_route_id uuid, p_lat numeric, p_lng numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r record;
  prev record;
  best numeric := null;
  d numeric;
  n int := 0;
begin
  for r in
    select s.latitude as lat, s.longitude as lng from (
      select sequence_no, latitude, longitude from public.boarding_points where route_id = p_route_id and latitude is not null and is_active
      union
      select sequence_no, latitude, longitude from public.dropping_points where route_id = p_route_id and latitude is not null and is_active
    ) s order by s.sequence_no
  loop
    n := n + 1;
    if n > 1 then
      d := private.dist_to_segment_m(p_lat, p_lng, prev.lat, prev.lng, r.lat, r.lng);
      if best is null or d < best then best := d; end if;
    end if;
    prev := r;
  end loop;
  return best;
end;
$$;
revoke execute on function private.dist_to_segment_m(numeric, numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated;
revoke execute on function private.dist_to_route_m(uuid, numeric, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- passenger-assisted aggregate (flag + strict conditions, otherwise NULL)
-- ---------------------------------------------------------------------
create or replace function private.passenger_estimate(p_trip_id uuid)
returns table (latitude numeric, longitude numeric, recorded_at timestamptz, confidence numeric)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_min int := private.setting_num('passenger_min_users', 3)::int;
  v_age numeric := private.setting_num('passenger_max_age_seconds', 60);
  v_acc numeric := private.setting_num('passenger_max_accuracy_m', 50);
  v_radius numeric := private.setting_num('passenger_cluster_radius_m', 150);
  v_corridor numeric := private.setting_num('passenger_corridor_m', 300);
  v_n int; v_lat numeric; v_lng numeric; v_ts timestamptz; v_dist numeric;
begin
  if not private.setting_bool('passenger_tracking_enabled', false) then return; end if;
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null or v_trip.status <> 'departed' then return; end if;

  with pts as (
    select distinct on (o.user_id) o.user_id, o.latitude as lat, o.longitude as lng, o.recorded_at as ts
    from public.vehicle_location_observations o
    join public.passenger_location_consent c on c.user_id = o.user_id and c.trip_id = o.trip_id and c.revoked_at is null
    where o.trip_id = p_trip_id and o.source = 'passenger_assisted'
      and o.recorded_at >= now() - make_interval(secs => v_age)
      and (o.accuracy_m is null or o.accuracy_m <= v_acc)
      and exists (select 1 from public.booking_items bi join public.bookings b on b.id = bi.booking_id
                  where bi.trip_id = p_trip_id and b.customer_id = o.user_id and bi.status in ('confirmed', 'completed'))
    order by o.user_id, o.recorded_at desc
  ), med as (
    select percentile_cont(0.5) within group (order by lat) as mlat, percentile_cont(0.5) within group (order by lng) as mlng from pts
  ), cl as (
    select p.* from pts p, med where private.haversine_km(p.lat, p.lng, med.mlat::numeric, med.mlng::numeric) * 1000 <= v_radius
  )
  select count(*), avg(lat), avg(lng), max(ts) into v_n, v_lat, v_lng, v_ts from cl;
  if v_n < v_min then return; end if;

  v_dist := private.dist_to_route_m(v_trip.route_id, v_lat, v_lng);
  if v_dist is null or v_dist > v_corridor then return; end if;

  latitude := v_lat; longitude := v_lng; recorded_at := v_ts;
  confidence := round(least(1, v_n::numeric / (v_min * 2)), 2);
  return next;
end;
$$;
revoke execute on function private.passenger_estimate(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- THE tracking decision (read time, so staleness is always current)
-- ---------------------------------------------------------------------
create or replace function private.compute_tracking(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_bus public.buses;
  v_fresh numeric := private.setting_num('tracker_fresh_seconds', 120);
  v_offline numeric := private.setting_num('tracker_offline_seconds', 900);
  v_from timestamptz;
  v_trk record; v_drv record; v_last record; v_est record;
  v_has_device boolean;
  v_label text; v_status text; v_source text; v_lat numeric; v_lng numeric; v_ts timestamptz; v_conf numeric;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  select * into v_bus from public.buses where id = v_trip.bus_id;
  v_from := v_trip.departure_at - interval '4 hours';

  select exists (select 1 from public.bus_gps_assignments a join public.gps_devices d on d.id = a.device_id
                 where a.bus_id = v_trip.bus_id and a.unassigned_at is null and d.activation_status = 'active')
    into v_has_device;

  if v_trip.status in ('arrived', 'cancelled') then
    select o.latitude, o.longitude, o.recorded_at, o.source into v_last
      from public.vehicle_location_observations o
      where o.bus_id = v_trip.bus_id and o.source in ('tracker', 'driver_device') and o.recorded_at >= v_from
      order by o.recorded_at desc limit 1;
    return jsonb_build_object('status', 'ended', 'label', case v_trip.status when 'arrived' then 'Trip completed' else 'Trip cancelled' end,
      'source', v_last.source, 'latitude', v_last.latitude, 'longitude', v_last.longitude, 'recorded_at', v_last.recorded_at,
      'is_live', false, 'is_estimate', false, 'confidence', null, 'device_configured', v_has_device);
  end if;

  select o.latitude, o.longitude, o.recorded_at into v_trk from public.vehicle_location_observations o
    where o.bus_id = v_trip.bus_id and o.source = 'tracker' and o.recorded_at >= v_from
    order by o.recorded_at desc limit 1;

  if v_trk.recorded_at is not null and extract(epoch from (now() - v_trk.recorded_at)) <= v_fresh then
    v_status := 'live_tracker'; v_source := 'tracker'; v_lat := v_trk.latitude; v_lng := v_trk.longitude; v_ts := v_trk.recorded_at;
    v_label := 'Live — GPS Tracker';
  end if;

  if v_status is null and v_bus.allow_driver_fallback then
    select o.latitude, o.longitude, o.recorded_at into v_drv from public.vehicle_location_observations o
      where o.bus_id = v_trip.bus_id and o.source = 'driver_device' and o.recorded_at >= v_from
      order by o.recorded_at desc limit 1;
    if v_drv.recorded_at is not null and extract(epoch from (now() - v_drv.recorded_at)) <= v_fresh then
      v_status := 'live_verified_fallback'; v_source := 'driver_device'; v_lat := v_drv.latitude; v_lng := v_drv.longitude; v_ts := v_drv.recorded_at;
      v_label := 'Live — Verified Fallback';
    end if;
  end if;

  if v_status is null then
    select * into v_est from private.passenger_estimate(p_trip_id);
    if v_est.latitude is not null then
      v_status := 'estimated_passenger'; v_source := 'passenger_assisted'; v_lat := v_est.latitude; v_lng := v_est.longitude;
      v_ts := v_est.recorded_at; v_conf := v_est.confidence; v_label := 'Estimated — Passenger Assisted';
    end if;
  end if;

  if v_status is null then
    select o.latitude, o.longitude, o.recorded_at, o.source into v_last from public.vehicle_location_observations o
      where o.bus_id = v_trip.bus_id and o.recorded_at >= v_from
        and (o.source = 'tracker' or (o.source = 'driver_device' and v_bus.allow_driver_fallback))
      order by o.recorded_at desc limit 1;
    if v_last.recorded_at is not null then
      v_source := v_last.source; v_lat := v_last.latitude; v_lng := v_last.longitude; v_ts := v_last.recorded_at;
      if extract(epoch from (now() - v_ts)) <= v_offline then
        v_status := 'stale'; v_label := 'Stale — last known location';
      else
        v_status := 'offline'; v_label := 'Offline — last known location';
      end if;
    elsif not v_has_device and not v_bus.allow_driver_fallback then
      v_status := 'not_configured'; v_label := 'GPS tracking not configured';
    elsif v_trip.status = 'departed' then
      v_status := 'offline'; v_label := 'Offline — vehicle location unavailable';
    else
      v_status := 'not_started'; v_label := 'Tracking not started';
    end if;
  end if;

  return jsonb_build_object(
    'status', v_status, 'label', v_label, 'source', v_source,
    'latitude', v_lat, 'longitude', v_lng, 'recorded_at', v_ts,
    'age_seconds', case when v_ts is null then null else round(extract(epoch from (now() - v_ts))) end,
    'confidence', v_conf,
    'is_live', v_status in ('live_tracker', 'live_verified_fallback'),
    'is_estimate', v_status = 'estimated_passenger',
    'device_configured', v_has_device);
end;
$$;
revoke execute on function private.compute_tracking(uuid) from public, anon, authenticated;

-- denormalise the decision onto the trip + tell listeners (no coordinates in the ping)
create or replace function private.refresh_trip_location(p_trip_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  t jsonb := private.compute_tracking(p_trip_id);
begin
  update public.bus_trips set
    location_status = t ->> 'status',
    location_source = nullif(t ->> 'source', ''),
    location_confidence = (t ->> 'confidence')::numeric,
    current_latitude = coalesce((t ->> 'latitude')::numeric, current_latitude),
    current_longitude = coalesce((t ->> 'longitude')::numeric, current_longitude),
    last_location_update = coalesce((t ->> 'recorded_at')::timestamptz, last_location_update)
  where id = p_trip_id;
  begin
    perform realtime.send(jsonb_build_object('status', t ->> 'status'), 'tracking', 'trip:' || p_trip_id || ':track', true);
  exception when others then null; end;
end;
$$;
revoke execute on function private.refresh_trip_location(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- reads
-- ---------------------------------------------------------------------
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

  return private.compute_tracking(p_trip_id) || jsonb_build_object(
    'trip_id', p_trip_id, 'trip_status', v_trip.status, 'as_of', now(),
    'milestones', v_events, 'device', v_dev);
end;
$$;

create or replace function public.get_bus_gps_status(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  d public.gps_devices;
  o record;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then raise exception 'Not authorized'; end if;

  select dv.* into d from public.bus_gps_assignments a join public.gps_devices dv on dv.id = a.device_id
    where a.bus_id = p_bus_id and a.unassigned_at is null;
  if d.id is null then
    return jsonb_build_object('configured', false, 'status_label', 'Not Configured', 'allow_driver_fallback', v_bus.allow_driver_fallback);
  end if;

  select latitude, longitude, recorded_at, source into o from public.vehicle_location_observations
    where bus_id = p_bus_id and source = 'tracker' order by recorded_at desc limit 1;

  return jsonb_build_object(
    'configured', true,
    'device', jsonb_build_object(
      'id', d.id, 'name', d.name, 'device_identifier', d.device_identifier, 'imei', d.imei, 'serial_no', d.serial_no,
      'sim_ref', d.sim_ref, 'installed_on', d.installed_on, 'notes', d.notes,
      'activation_status', d.activation_status, 'connection_status', d.connection_status,
      'last_communication_at', d.last_communication_at, 'provider_configured', d.provider is not null),
    'status_label', case
        when d.activation_status <> 'active' then 'Awaiting activation by thirty8'
        when d.connection_status = 'online' then 'Connected'
        when d.connection_status = 'error' then 'Connection error'
        when d.connection_status = 'offline' then 'Offline'
        else 'Not connected yet' end,
    'last_location', case when o.recorded_at is null then null
        else jsonb_build_object('latitude', o.latitude, 'longitude', o.longitude, 'recorded_at', o.recorded_at, 'source', o.source) end,
    'tracking_source', 'GPS tracker',
    'allow_driver_fallback', v_bus.allow_driver_fallback);
end;
$$;

-- ---------------------------------------------------------------------
-- operator device configuration (owner admin only; no credentials, no provider)
-- ---------------------------------------------------------------------
create or replace function public.operator_register_gps_device(
  p_bus_id uuid, p_device_identifier text, p_name text default null, p_imei text default null,
  p_serial_no text default null, p_sim_ref text default null, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_dev uuid;
  v_id text := btrim(coalesce(p_device_identifier, ''));
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_admin(v_bus.operator_id) then raise exception 'Only the operator admin can configure tracking'; end if;
  if not private.operator_service_active(v_bus.operator_id, 'bus') then
    raise exception 'service_inactive: the Bus service is not active for this operator';
  end if;
  if v_id = '' then raise exception 'A device identifier is required'; end if;
  if exists (select 1 from public.bus_gps_assignments where bus_id = p_bus_id and unassigned_at is null) then
    raise exception 'device_already_assigned: this bus already has a tracker. Disconnect it first.';
  end if;
  if exists (select 1 from public.gps_devices d join public.bus_gps_assignments a on a.device_id = d.id and a.unassigned_at is null
             where d.device_identifier = v_id) then
    raise exception 'device_already_assigned: this tracker is already assigned to a bus';
  end if;

  -- re-use a previously registered (now unassigned) device with the same identifier, else create one
  select id into v_dev from public.gps_devices where device_identifier = v_id and provider is null limit 1;
  if v_dev is null then
    insert into public.gps_devices (name, device_identifier, imei, serial_no, sim_ref, notes, created_by)
    values (nullif(btrim(p_name), ''), v_id, nullif(btrim(p_imei), ''), nullif(btrim(p_serial_no), ''), nullif(btrim(p_sim_ref), ''),
            nullif(btrim(p_notes), ''), (select auth.uid()))
    returning id into v_dev;
  else
    update public.gps_devices set name = nullif(btrim(p_name), ''), imei = nullif(btrim(p_imei), ''), serial_no = nullif(btrim(p_serial_no), ''),
           sim_ref = nullif(btrim(p_sim_ref), ''), notes = nullif(btrim(p_notes), ''), activation_status = 'registered',
           connection_status = 'never_connected'
     where id = v_dev;
  end if;
  insert into public.bus_gps_assignments (device_id, bus_id, assigned_by) values (v_dev, p_bus_id, (select auth.uid()));
  perform private.write_audit('gps_device.register', 'bus', p_bus_id, null, jsonb_build_object('device_identifier', v_id));
  return public.get_bus_gps_status(p_bus_id);
end;
$$;

create or replace function public.operator_update_gps_device(
  p_bus_id uuid, p_name text default null, p_imei text default null, p_serial_no text default null,
  p_sim_ref text default null, p_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_dev uuid;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_admin(v_bus.operator_id) then raise exception 'Only the operator admin can configure tracking'; end if;
  select device_id into v_dev from public.bus_gps_assignments where bus_id = p_bus_id and unassigned_at is null;
  if v_dev is null then raise exception 'No tracker is configured for this bus'; end if;
  update public.gps_devices set name = nullif(btrim(p_name), ''), imei = nullif(btrim(p_imei), ''), serial_no = nullif(btrim(p_serial_no), ''),
         sim_ref = nullif(btrim(p_sim_ref), ''), notes = nullif(btrim(p_notes), '') where id = v_dev;
  perform private.write_audit('gps_device.update', 'bus', p_bus_id, null, jsonb_build_object('device_id', v_dev));
  return public.get_bus_gps_status(p_bus_id);
end;
$$;

create or replace function public.operator_disconnect_gps_device(p_bus_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_dev uuid;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_admin(v_bus.operator_id) then raise exception 'Only the operator admin can configure tracking'; end if;
  select device_id into v_dev from public.bus_gps_assignments where bus_id = p_bus_id and unassigned_at is null;
  if v_dev is null then raise exception 'No tracker is configured for this bus'; end if;
  update public.bus_gps_assignments set unassigned_at = now() where device_id = v_dev and unassigned_at is null;
  update public.gps_devices set activation_status = 'inactive', connection_status = 'never_connected' where id = v_dev;
  perform private.write_audit('gps_device.disconnect', 'bus', p_bus_id, null, jsonb_build_object('device_id', v_dev));
  return public.get_bus_gps_status(p_bus_id);
end;
$$;

-- ---------------------------------------------------------------------
-- admin device management (provider-neutral)
-- ---------------------------------------------------------------------
create or replace function public.admin_save_gps_device(p_device_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := p_device_id;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  if v_id is null then
    if coalesce(btrim(p_data ->> 'device_identifier'), '') = '' then raise exception 'A device identifier is required'; end if;
    insert into public.gps_devices (name, provider, integration_type, device_identifier, imei, serial_no, sim_ref, installed_on, notes, provider_config_ref, created_by)
    values (p_data ->> 'name', nullif(btrim(p_data ->> 'provider'), ''), p_data ->> 'integration_type', btrim(p_data ->> 'device_identifier'),
            nullif(btrim(p_data ->> 'imei'), ''), p_data ->> 'serial_no', p_data ->> 'sim_ref', (p_data ->> 'installed_on')::date,
            p_data ->> 'notes', nullif(btrim(p_data ->> 'provider_config_ref'), ''), (select auth.uid()))
    returning id into v_id;
  else
    update public.gps_devices set
      name = case when p_data ? 'name' then p_data ->> 'name' else name end,
      provider = case when p_data ? 'provider' then nullif(btrim(p_data ->> 'provider'), '') else provider end,
      integration_type = case when p_data ? 'integration_type' then p_data ->> 'integration_type' else integration_type end,
      device_identifier = case when p_data ? 'device_identifier' then btrim(p_data ->> 'device_identifier') else device_identifier end,
      imei = case when p_data ? 'imei' then nullif(btrim(p_data ->> 'imei'), '') else imei end,
      serial_no = case when p_data ? 'serial_no' then p_data ->> 'serial_no' else serial_no end,
      sim_ref = case when p_data ? 'sim_ref' then p_data ->> 'sim_ref' else sim_ref end,
      installed_on = case when p_data ? 'installed_on' then (p_data ->> 'installed_on')::date else installed_on end,
      notes = case when p_data ? 'notes' then p_data ->> 'notes' else notes end,
      provider_config_ref = case when p_data ? 'provider_config_ref' then nullif(btrim(p_data ->> 'provider_config_ref'), '') else provider_config_ref end
    where id = v_id;
    if not found then raise exception 'Device not found'; end if;
  end if;
  perform private.write_audit('gps_device.save', 'gps_device', v_id, null, p_data - 'provider_config_ref');
  return v_id;
exception when unique_violation then
  raise exception 'device_exists: a device with this identifier and provider is already registered';
end;
$$;

create or replace function public.admin_assign_gps_device(p_device_id uuid, p_bus_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  if not exists (select 1 from public.gps_devices where id = p_device_id) then raise exception 'Device not found'; end if;
  if not exists (select 1 from public.buses where id = p_bus_id) then raise exception 'Bus not found'; end if;
  update public.bus_gps_assignments set unassigned_at = now()
   where unassigned_at is null and (device_id = p_device_id or bus_id = p_bus_id);
  insert into public.bus_gps_assignments (device_id, bus_id, assigned_by) values (p_device_id, p_bus_id, (select auth.uid()));
  update public.gps_devices set connection_status = 'never_connected', last_communication_at = null where id = p_device_id;
  perform private.write_audit('gps_device.assign', 'gps_device', p_device_id, null, jsonb_build_object('bus_id', p_bus_id));
end;
$$;

create or replace function public.admin_unassign_gps_device(p_device_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  update public.bus_gps_assignments set unassigned_at = now() where device_id = p_device_id and unassigned_at is null;
  update public.gps_devices set connection_status = 'never_connected' where id = p_device_id;
  perform private.write_audit('gps_device.unassign', 'gps_device', p_device_id, null, null);
end;
$$;

create or replace function public.admin_set_gps_device_state(p_device_id uuid, p_state text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.gps_devices;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  if p_state not in ('registered', 'active', 'inactive', 'retired') then raise exception 'Unknown state %', p_state; end if;
  select * into d from public.gps_devices where id = p_device_id;
  if d.id is null then raise exception 'Device not found'; end if;
  if p_state = 'active' then
    if d.provider is null then raise exception 'provider_required: choose the tracking provider before activating the device'; end if;
    if not exists (select 1 from public.bus_gps_assignments where device_id = p_device_id and unassigned_at is null) then
      raise exception 'assignment_required: assign the device to a bus before activating it';
    end if;
  end if;
  update public.gps_devices set activation_status = p_state where id = p_device_id;
  perform private.write_audit('gps_device.state', 'gps_device', p_device_id, jsonb_build_object('state', d.activation_status), jsonb_build_object('state', p_state));
end;
$$;

create or replace function public.admin_set_bus_driver_fallback(p_bus_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  update public.buses set allow_driver_fallback = p_enabled where id = p_bus_id;
  if not found then raise exception 'Bus not found'; end if;
  perform private.write_audit('bus.driver_fallback', 'bus', p_bus_id, null, jsonb_build_object('enabled', p_enabled));
end;
$$;

create or replace function public.admin_list_gps_devices()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) into v_rows
  from (
    select d.created_at, jsonb_build_object(
      'id', d.id, 'name', d.name, 'provider', d.provider, 'integration_type', d.integration_type,
      'device_identifier', d.device_identifier, 'imei', d.imei, 'serial_no', d.serial_no, 'sim_ref', d.sim_ref,
      'installed_on', d.installed_on, 'notes', d.notes, 'provider_config_ref', d.provider_config_ref,
      'activation_status', d.activation_status, 'connection_status', d.connection_status,
      'last_communication_at', d.last_communication_at, 'last_error', d.last_error,
      'bus_id', b.id, 'bus_registration', b.registration_number, 'operator_name', o.name,
      'last_location', (select jsonb_build_object('latitude', v.latitude, 'longitude', v.longitude, 'recorded_at', v.recorded_at)
                         from public.vehicle_location_observations v
                         where v.device_id = d.id order by v.recorded_at desc limit 1)) as j
    from public.gps_devices d
    left join public.bus_gps_assignments a on a.device_id = d.id and a.unassigned_at is null
    left join public.buses b on b.id = a.bus_id
    left join public.operators o on o.id = b.operator_id
  ) x;
  return jsonb_build_object('devices', v_rows);
end;
$$;

create or replace function public.admin_list_gps_integration_events(p_device_id uuid default null, p_limit int default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  return jsonb_build_object('events', coalesce((
    select jsonb_agg(jsonb_build_object('id', e.id, 'device_id', e.device_id, 'level', e.level, 'message', e.message, 'created_at', e.created_at) order by e.created_at desc)
    from (select * from public.gps_integration_events where p_device_id is null or device_id = p_device_id
          order by created_at desc limit greatest(least(p_limit, 500), 1)) e), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------------
-- ingest (service role only): the provider adapter calls this with a parsed fix
-- ---------------------------------------------------------------------
create or replace function public.ingest_tracker_location(
  p_provider text, p_device_identifier text, p_latitude numeric, p_longitude numeric,
  p_recorded_at timestamptz default now(), p_accuracy_m numeric default null,
  p_speed_kmh numeric default null, p_heading numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.gps_devices;
  v_bus uuid;
  v_trip uuid;
begin
  select * into d from public.gps_devices where device_identifier = p_device_identifier and coalesce(provider, '') = coalesce(p_provider, '');
  if d.id is null then
    return jsonb_build_object('accepted', false, 'reason', 'unknown_device');
  end if;
  if d.activation_status <> 'active' then
    insert into public.gps_integration_events (device_id, level, message) values (d.id, 'warning', 'Fix received from a device that is not active');
    return jsonb_build_object('accepted', false, 'reason', 'device_not_active');
  end if;
  select bus_id into v_bus from public.bus_gps_assignments where device_id = d.id and unassigned_at is null;
  if v_bus is null then
    insert into public.gps_integration_events (device_id, level, message) values (d.id, 'warning', 'Fix received from a device that is not assigned to a bus');
    return jsonb_build_object('accepted', false, 'reason', 'device_not_assigned');
  end if;
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180
     or (p_latitude = 0 and p_longitude = 0) then
    update public.gps_devices set last_error = 'Invalid coordinates received', connection_status = 'error', last_communication_at = now() where id = d.id;
    insert into public.gps_integration_events (device_id, level, message) values (d.id, 'error', 'Invalid coordinates received');
    return jsonb_build_object('accepted', false, 'reason', 'invalid_coordinates');
  end if;
  if p_recorded_at > now() + interval '2 minutes' then
    insert into public.gps_integration_events (device_id, level, message) values (d.id, 'warning', 'Fix timestamp is in the future');
    return jsonb_build_object('accepted', false, 'reason', 'timestamp_in_future');
  end if;

  select id into v_trip from public.bus_trips
    where bus_id = v_bus and status in ('boarding', 'departed') order by departure_at desc limit 1;
  insert into public.vehicle_location_observations (bus_id, trip_id, source, device_id, latitude, longitude, accuracy_m, speed_kmh, heading, recorded_at)
  values (v_bus, v_trip, 'tracker', d.id, p_latitude, p_longitude, p_accuracy_m, p_speed_kmh, p_heading, p_recorded_at);
  update public.gps_devices set connection_status = 'online', last_communication_at = now(), last_error = null where id = d.id;
  if v_trip is not null then perform private.refresh_trip_location(v_trip); end if;
  return jsonb_build_object('accepted', true, 'trip_id', v_trip);
end;
$$;

-- driver/conductor phone (a fallback source, used only if an admin enabled it for the bus)
drop function public.update_bus_location(uuid, numeric, numeric);
create or replace function public.update_bus_location(
  p_trip_id uuid, p_latitude numeric, p_longitude numeric, p_accuracy_m numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
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

  insert into public.vehicle_location_observations (bus_id, trip_id, source, user_id, latitude, longitude, accuracy_m, recorded_at)
  values (v_trip.bus_id, p_trip_id, 'driver_device', (select auth.uid()), p_latitude, p_longitude, p_accuracy_m, now());

  insert into public.bus_trip_events (trip_id, latitude, longitude, event_type)
  values (p_trip_id, p_latitude, p_longitude, 'location_update');

  for v_point in
    select name, latitude, longitude, 'boarding' as point_type from public.boarding_points where route_id = v_trip.route_id and latitude is not null
    union all
    select name, latitude, longitude, 'dropping' as point_type from public.dropping_points where route_id = v_trip.route_id and latitude is not null
  loop
    if private.haversine_km(p_latitude, p_longitude, v_point.latitude, v_point.longitude) <= 0.2
       -- one milestone per stop per 10 minutes, not one per ping
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
  return jsonb_build_object('trip_id', p_trip_id, 'milestone_reached', v_milestone, 'point_name', v_matched);
end;
$$;

-- ---------------------------------------------------------------------
-- passenger-assisted location (consent based; flag defaults OFF)
-- ---------------------------------------------------------------------
create or replace function public.grant_passenger_location_consent(p_trip_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then raise exception 'Must be signed in'; end if;
  if not private.setting_bool('passenger_tracking_enabled', false) then
    raise exception 'feature_disabled: passenger location sharing is not available';
  end if;
  if not exists (select 1 from public.booking_items bi join public.bookings b on b.id = bi.booking_id
                 where bi.trip_id = p_trip_id and b.customer_id = (select auth.uid()) and bi.status in ('confirmed', 'completed')) then
    raise exception 'You need a confirmed booking on this trip';
  end if;
  insert into public.passenger_location_consent (user_id, trip_id) values ((select auth.uid()), p_trip_id)
  on conflict (user_id, trip_id) do update set granted_at = now(), revoked_at = null;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.revoke_passenger_location_consent(p_trip_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.passenger_location_consent set revoked_at = now()
   where user_id = (select auth.uid()) and trip_id = p_trip_id and revoked_at is null;
  -- revoking also deletes what this passenger already shared for the trip
  delete from public.vehicle_location_observations
   where user_id = (select auth.uid()) and trip_id = p_trip_id and source = 'passenger_assisted';
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.submit_passenger_location(p_trip_id uuid, p_latitude numeric, p_longitude numeric, p_accuracy_m numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'Must be signed in'; end if;
  if not private.setting_bool('passenger_tracking_enabled', false) then
    raise exception 'feature_disabled: passenger location sharing is not available';
  end if;
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  if v_trip.status not in ('boarding', 'departed') then raise exception 'trip_not_in_progress: location is only shared while the trip is running'; end if;
  if not exists (select 1 from public.passenger_location_consent where user_id = v_uid and trip_id = p_trip_id and revoked_at is null) then
    raise exception 'consent_required: location sharing was not allowed for this trip';
  end if;
  if not exists (select 1 from public.booking_items bi join public.bookings b on b.id = bi.booking_id
                 where bi.trip_id = p_trip_id and b.customer_id = v_uid and bi.status in ('confirmed', 'completed')) then
    raise exception 'You need a confirmed booking on this trip';
  end if;
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    raise exception 'invalid_coordinates: latitude/longitude out of range';
  end if;
  if exists (select 1 from public.vehicle_location_observations
             where user_id = v_uid and trip_id = p_trip_id and source = 'passenger_assisted'
               and recorded_at > now() - make_interval(secs => private.setting_num('passenger_sample_min_interval_seconds', 10))) then
    return jsonb_build_object('ok', true, 'throttled', true);
  end if;
  insert into public.vehicle_location_observations (bus_id, trip_id, source, user_id, latitude, longitude, accuracy_m, recorded_at)
  values (v_trip.bus_id, p_trip_id, 'passenger_assisted', v_uid, p_latitude, p_longitude, p_accuracy_m, now());
  return jsonb_build_object('ok', true, 'throttled', false);
end;
$$;

-- ---------------------------------------------------------------------
-- housekeeping: retention + device health
-- ---------------------------------------------------------------------
create or replace function private.purge_location_observations()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- passenger samples never outlive the trip by more than a day
  delete from public.vehicle_location_observations o
   where o.source = 'passenger_assisted'
     and (o.recorded_at < now() - interval '48 hours'
          or exists (select 1 from public.bus_trips t where t.id = o.trip_id and t.status in ('arrived', 'cancelled') and t.updated_at < now() - interval '24 hours'));
  delete from public.vehicle_location_observations where source in ('tracker', 'driver_device') and recorded_at < now() - interval '90 days';
  delete from public.passenger_location_consent c
   using public.bus_trips t where t.id = c.trip_id and t.status in ('arrived', 'cancelled') and t.updated_at < now() - interval '24 hours';
end;
$$;

create or replace function private.mark_stale_gps_devices()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.gps_devices set connection_status = 'offline'
   where activation_status = 'active' and connection_status = 'online'
     and last_communication_at < now() - make_interval(secs => private.setting_num('tracker_offline_seconds', 900));
end;
$$;
revoke execute on function private.purge_location_observations() from public, anon, authenticated;
revoke execute on function private.mark_stale_gps_devices() from public, anon, authenticated;
select cron.schedule('purge-location-observations', '17 3 * * *', $$select private.purge_location_observations();$$);
select cron.schedule('mark-stale-gps-devices', '*/5 * * * *', $$select private.mark_stale_gps_devices();$$);

-- ---------------------------------------------------------------------
-- grants + realtime listening for the tracking channel
-- ---------------------------------------------------------------------
revoke execute on function public.get_trip_tracking(uuid) from public, anon;
revoke execute on function public.get_bus_gps_status(uuid) from public, anon;
revoke execute on function public.operator_register_gps_device(uuid, text, text, text, text, text, text) from public, anon;
revoke execute on function public.operator_update_gps_device(uuid, text, text, text, text, text) from public, anon;
revoke execute on function public.operator_disconnect_gps_device(uuid) from public, anon;
revoke execute on function public.admin_save_gps_device(uuid, jsonb) from public, anon;
revoke execute on function public.admin_assign_gps_device(uuid, uuid) from public, anon;
revoke execute on function public.admin_unassign_gps_device(uuid) from public, anon;
revoke execute on function public.admin_set_gps_device_state(uuid, text) from public, anon;
revoke execute on function public.admin_set_bus_driver_fallback(uuid, boolean) from public, anon;
revoke execute on function public.admin_list_gps_devices() from public, anon;
revoke execute on function public.admin_list_gps_integration_events(uuid, int) from public, anon;
revoke execute on function public.update_bus_location(uuid, numeric, numeric, numeric) from public, anon;
revoke execute on function public.grant_passenger_location_consent(uuid) from public, anon;
revoke execute on function public.revoke_passenger_location_consent(uuid) from public, anon;
revoke execute on function public.submit_passenger_location(uuid, numeric, numeric, numeric) from public, anon;
revoke execute on function public.ingest_tracker_location(text, text, numeric, numeric, timestamptz, numeric, numeric, numeric) from public, anon, authenticated;
grant execute on function public.get_trip_tracking(uuid) to authenticated;
grant execute on function public.get_bus_gps_status(uuid) to authenticated;
grant execute on function public.operator_register_gps_device(uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.operator_update_gps_device(uuid, text, text, text, text, text) to authenticated;
grant execute on function public.operator_disconnect_gps_device(uuid) to authenticated;
grant execute on function public.admin_save_gps_device(uuid, jsonb) to authenticated;
grant execute on function public.admin_assign_gps_device(uuid, uuid) to authenticated;
grant execute on function public.admin_unassign_gps_device(uuid) to authenticated;
grant execute on function public.admin_set_gps_device_state(uuid, text) to authenticated;
grant execute on function public.admin_set_bus_driver_fallback(uuid, boolean) to authenticated;
grant execute on function public.admin_list_gps_devices() to authenticated;
grant execute on function public.admin_list_gps_integration_events(uuid, int) to authenticated;
grant execute on function public.update_bus_location(uuid, numeric, numeric, numeric) to authenticated;
grant execute on function public.grant_passenger_location_consent(uuid) to authenticated;
grant execute on function public.revoke_passenger_location_consent(uuid) to authenticated;
grant execute on function public.submit_passenger_location(uuid, numeric, numeric, numeric) to authenticated;
grant execute on function public.ingest_tracker_location(text, text, numeric, numeric, timestamptz, numeric, numeric, numeric) to service_role;

create policy trip_track_broadcast_listen on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) ~ '^trip:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:track$'
    and exists (
      select 1 from public.bus_trips t
      where t.id = split_part((select realtime.topic()), ':', 2)::uuid
        and (private.is_operator_staff(t.operator_id) or private.is_platform_admin()
             or exists (select 1 from public.booking_items bi join public.bookings b on b.id = bi.booking_id
                        where bi.trip_id = t.id and b.customer_id = (select auth.uid()) and bi.status in ('confirmed', 'completed')))
    )
  );
