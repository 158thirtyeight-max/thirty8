-- =========================================================================
-- Checks for 20261002002100_gps_tracking.sql
--   * unconfigured / awaiting activation / not started: nothing claims a device is connected
--   * one tracker per bus (and one bus per tracker); operators cannot see provider config
--   * ingest is service-role only and rejects unknown / inactive / invalid fixes
--   * source priority: fresh tracker > fallback (admin-enabled) > passenger aggregate > stale > offline
--   * a stale tracker is never shown as live; the tracker recovers as primary
--   * passenger-assisted: flag off by default, consent, >=3 independent users, route corridor,
--     revoke deletes samples, no client can read observations
--   * retention + device health jobs
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

create function pg_temp.pay(p_tag text) returns void language plpgsql security definer as $f$
declare o public.orders;
begin
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_' || p_tag, o.amount_cents);
end $f$;
grant execute on function pg_temp.pay(text) to authenticated;

create function pg_temp.track() returns jsonb language sql security definer as $f$
  select private.compute_tracking((select id from t_ref where tag = 'TRIP')) $f$;
create function pg_temp.set_obs_age(p_source text, p_seconds int) returns void language sql security definer as $f$
  update public.vehicle_location_observations set recorded_at = now() - make_interval(secs => p_seconds) where source = p_source $f$;
create function pg_temp.fix(p_lat numeric, p_lng numeric) returns jsonb language plpgsql security definer as $f$
declare r jsonb;
begin
  r := public.ingest_tracker_location('acme', 'TRK-1', p_lat, p_lng, now());
  return r;
end $f$;

create function pg_temp.depart() returns void language sql security definer as $f$
  update public.bus_trips set status = 'departed', departure_at = now() - interval '1 hour' where id = (select id from t_ref where tag = 'TRIP') $f$;
create function pg_temp.reschedule() returns void language sql security definer as $f$
  update public.bus_trips set status = 'scheduled', departure_at = (current_date + 2) + time '06:00' where id = (select id from t_ref where tag = 'TRIP') $f$;

insert into auth.users (id, email) values
  ('99999999-0000-0000-0000-000000000009', 'staff@test.invalid'),
  ('f1f1f1f1-0000-0000-0000-0000000000f1', 'cust3@test.invalid');
insert into public.user_roles (user_id, role, operator_id)
  values ('99999999-0000-0000-0000-000000000009', 'operator_staff', (select id from t_ops where tag = 'A'));

-- ---- 1. nothing configured --------------------------------------------------------------
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); v_trip uuid := (select id from t_ref where tag = 'TRIP'); t jsonb; g jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  g := public.get_bus_gps_status(v_bus);
  if (g ->> 'configured')::boolean then raise exception 'FAIL 1a: reported configured'; end if;
  t := public.get_trip_tracking(v_trip);
  if t ->> 'status' <> 'not_configured' or (t ->> 'is_live')::boolean then raise exception 'FAIL 1b: %', t; end if;
  if t -> 'latitude' <> 'null'::jsonb then raise exception 'FAIL 1c: invented coordinates %', t; end if;
  perform pg_temp.as_server();
end $$;

-- ---- 2. operator registers a device (awaiting admin activation) ----------------------------------
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); v_a uuid := (select id from t_ops where tag = 'A'); g jsonb; v_bus2 uuid;
begin
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  begin perform public.operator_register_gps_device(v_bus, 'TRK-1', 'Roof tracker'); raise exception 'FAIL 2a: staff configured a tracker';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.operator_register_gps_device(v_bus, 'TRK-1', 'x'); raise exception 'FAIL 2b: operator B configured operator A bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.operator_register_gps_device(v_bus, '', 'x'); raise exception 'FAIL 2c: empty identifier';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.operator_register_gps_device(v_bus, 'TRK-1', 'Roof tracker', '12345'); raise exception 'FAIL 2d: bad IMEI';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  g := public.operator_register_gps_device(v_bus, 'TRK-1', 'Roof tracker', '356938035643809', 'SN-9', '8991000000', 'under the dash');
  if not (g ->> 'configured')::boolean or g ->> 'status_label' <> 'Awaiting activation by thirty8' then raise exception 'FAIL 2e: %', g; end if;
  if g -> 'device' ->> 'connection_status' <> 'never_connected' or (g -> 'device' ->> 'provider_configured')::boolean then raise exception 'FAIL 2f: must not claim a connection or a provider %', g; end if;
  if g::text like '%provider_config_ref%' then raise exception 'FAIL 2g: provider config leaked to operator'; end if;

  -- one tracker per bus; the same tracker cannot sit on two buses
  begin perform public.operator_register_gps_device(v_bus, 'TRK-2', 'second'); raise exception 'FAIL 2h: two trackers on one bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  v_bus2 := (public.create_bus(v_a, 'Bus 2', 'AN01F0002', 'ac_seater', 4)).id;
  insert into t_ref values ('BUS2', v_bus2);
  begin perform public.operator_register_gps_device(v_bus2, 'TRK-1', 'same tracker'); raise exception 'FAIL 2i: one tracker on two buses';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'device_already_assigned%' then raise exception 'FAIL 2j: %', sqlerrm; end if;
  end;

  -- operators cannot read the registry tables
  begin perform 1 from public.gps_devices; raise exception 'FAIL 2k: operator read gps_devices';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();
  begin
    insert into public.bus_gps_assignments (device_id, bus_id) select device_id, (select id from t_ref where tag = 'BUS2') from public.bus_gps_assignments limit 1;
    raise exception 'FAIL 2l: DB allowed one tracker on two buses';
  exception when unique_violation then null; end;

  -- still not connected: tracking is not configured until an admin activates it
  if (pg_temp.track() ->> 'status') <> 'not_configured' then raise exception 'FAIL 2m: registered device must not enable tracking'; end if;
end $$;

-- ---- 3. admin activation needs a provider; ingest is service-role only --------------------------------------
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); v_dev uuid := (select id from public.gps_devices where device_identifier = 'TRK-1'); r jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.admin_set_gps_device_state(v_dev, 'active'); raise exception 'FAIL 3a: operator activated a device';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  begin perform public.admin_set_gps_device_state(v_dev, 'active'); raise exception 'FAIL 3b: activated without a provider';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'provider_required%' then raise exception 'FAIL 3c: %', sqlerrm; end if;
  end;
  perform public.admin_save_gps_device(v_dev, '{"provider":"acme","integration_type":"http_push","provider_config_ref":"ACME_SECRET"}'::jsonb);
  perform public.admin_set_gps_device_state(v_dev, 'active');
  r := public.admin_list_gps_devices();
  if not exists (select 1 from jsonb_array_elements(r -> 'devices') e where e ->> 'device_identifier' = 'TRK-1' and e ->> 'provider_config_ref' = 'ACME_SECRET' and e ->> 'bus_registration' = 'AN01F0001') then
    raise exception 'FAIL 3d: admin list %', r;
  end if;

  -- activated but no fix yet: "not started", never "connected"
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if (public.get_trip_tracking((select id from t_ref where tag = 'TRIP')) ->> 'status') <> 'not_started' then raise exception 'FAIL 3e: configured, no fix, trip not started'; end if;
  if (public.get_bus_gps_status(v_bus) ->> 'status_label') <> 'Not connected yet' then raise exception 'FAIL 3f: %', public.get_bus_gps_status(v_bus) ->> 'status_label'; end if;
  if public.get_bus_gps_status(v_bus)::text like '%ACME_SECRET%' then raise exception 'FAIL 3g: provider reference leaked'; end if;

  -- authenticated users cannot push fixes
  begin perform public.ingest_tracker_location('acme', 'TRK-1', 11.7, 92.7); raise exception 'FAIL 3h: a client called ingest';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();
end $$;

-- the trip is on the road
select pg_temp.depart();
-- route stops get coordinates (a corridor from (11.60,92.70) to (11.80,92.90))
update public.boarding_points set latitude = 11.60, longitude = 92.70 where id = (select id from t_ref where tag = 'B_ORIGIN');
update public.boarding_points set latitude = 11.70, longitude = 92.80 where id = (select id from t_ref where tag = 'B_MID');
update public.dropping_points set latitude = 11.70, longitude = 92.80 where id = (select id from t_ref where tag = 'D_MID');
update public.dropping_points set latitude = 11.80, longitude = 92.90 where id = (select id from t_ref where tag = 'D_DEST');

-- ---- 4. ingest as the service role ----------------------------------------------------------------------
do $$
declare v_dev uuid := (select id from public.gps_devices where device_identifier = 'TRK-1'); r jsonb; t jsonb;
begin
  set local role service_role;
  r := public.ingest_tracker_location('acme', 'UNKNOWN', 11.7, 92.7);
  if (r ->> 'accepted')::boolean or r ->> 'reason' <> 'unknown_device' then raise exception 'FAIL 4a: %', r; end if;
  r := public.ingest_tracker_location('acme', 'TRK-1', 0, 0);
  if (r ->> 'accepted')::boolean or r ->> 'reason' <> 'invalid_coordinates' then raise exception 'FAIL 4b: null-island fix accepted %', r; end if;
  r := public.ingest_tracker_location('acme', 'TRK-1', 95, 10);
  if (r ->> 'accepted')::boolean then raise exception 'FAIL 4c: out-of-range latitude accepted'; end if;
  r := public.ingest_tracker_location('acme', 'TRK-1', 11.7, 92.8, now() + interval '1 hour');
  if (r ->> 'accepted')::boolean or r ->> 'reason' <> 'timestamp_in_future' then raise exception 'FAIL 4d: %', r; end if;
  reset role;
  if (select connection_status from public.gps_devices where id = v_dev) <> 'error' then raise exception 'FAIL 4e: invalid data should flag the device'; end if;
  if not exists (select 1 from public.gps_integration_events where device_id = v_dev and level = 'error') then raise exception 'FAIL 4f: integration error not logged'; end if;

  set local role service_role;
  r := public.ingest_tracker_location('acme', 'TRK-1', 11.7, 92.8, now(), 8.5, 42, 90);
  reset role;
  if not (r ->> 'accepted')::boolean then raise exception 'FAIL 4g: %', r; end if;
  if (select connection_status from public.gps_devices where id = v_dev) <> 'online' or (select last_communication_at from public.gps_devices where id = v_dev) is null then
    raise exception 'FAIL 4h: device should be online after a real fix';
  end if;

  t := pg_temp.track();
  if t ->> 'status' <> 'live_tracker' or t ->> 'label' <> 'Live — GPS Tracker' or not (t ->> 'is_live')::boolean or t ->> 'source' <> 'tracker' then raise exception 'FAIL 4i: %', t; end if;
  if (select location_status from public.bus_trips where id = (select id from t_ref where tag = 'TRIP')) <> 'live_tracker' then raise exception 'FAIL 4j: trip not updated'; end if;
  if not exists (select 1 from realtime.sent_log where topic like '%:track') then raise exception 'FAIL 4k: no tracking ping'; end if;
  if exists (select 1 from realtime.sent_log where topic like '%:track' and payload::text ~ '(latitude|longitude)') then raise exception 'FAIL 4l: tracking ping carries coordinates'; end if;
end $$;

-- ---- 5. a stale tracker is never live; tracker recovers --------------------------------------------------------
do $$
declare t jsonb;
begin
  perform pg_temp.set_obs_age('tracker', 300);   -- 5 minutes old
  t := pg_temp.track();
  if t ->> 'status' <> 'stale' or (t ->> 'is_live')::boolean or t ->> 'latitude' is null then raise exception 'FAIL 5a: stale tracker %', t; end if;
  perform pg_temp.set_obs_age('tracker', 1800);  -- 30 minutes old
  t := pg_temp.track();
  if t ->> 'status' <> 'offline' or (t ->> 'is_live')::boolean or t ->> 'latitude' is null then raise exception 'FAIL 5b: offline tracker keeps its last known point %', t; end if;
  set local role service_role;
  perform pg_temp.fix(11.71, 92.81);
  reset role;
  t := pg_temp.track();
  if t ->> 'status' <> 'live_tracker' then raise exception 'FAIL 5c: tracker did not recover as primary %', t; end if;
end $$;

-- ---- 6. driver device is a fallback only when an admin enabled it -----------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_bus uuid := (select id from t_ref where tag = 'BUS'); t jsonb; r jsonb; n int;
begin
  perform pg_temp.set_obs_age('tracker', 1800);
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  begin perform public.update_bus_location(v_trip, 95, 10); raise exception 'FAIL 6a: invalid coordinates accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  r := public.update_bus_location(v_trip, 11.70, 92.80, 12);
  perform pg_temp.as_server();
  if pg_temp.track() ->> 'status' = 'live_verified_fallback' then raise exception 'FAIL 6b: driver phone replaced the tracker without being enabled'; end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_bus_driver_fallback(v_bus, true);
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  perform public.update_bus_location(v_trip, 11.70, 92.80, 12);
  perform public.update_bus_location(v_trip, 11.7001, 92.8001, 12);
  perform pg_temp.as_server();
  t := pg_temp.track();
  if t ->> 'status' <> 'live_verified_fallback' or t ->> 'label' <> 'Live — Verified Fallback' then raise exception 'FAIL 6c: %', t; end if;
  select count(*) into n from public.bus_trip_events where trip_id = v_trip and event_type = 'milestone_arrived' and point_name = 'Middle';
  if n > 2 then raise exception 'FAIL 6d: repeated pings near a stop created % milestones', n; end if;

  -- a fresh tracker outranks the fallback
  set local role service_role; perform pg_temp.fix(11.72, 92.82); reset role;
  if pg_temp.track() ->> 'status' <> 'live_tracker' then raise exception 'FAIL 6e: tracker must outrank the fallback'; end if;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_bus_driver_fallback(v_bus, false);
  perform pg_temp.as_server();
end $$;

-- ---- 7. passenger-assisted: off by default, consent, aggregate, corridor ------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP');
begin
  perform pg_temp.reschedule();
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'P1', 1);
  perform pg_temp.book('eeeeeeee-0000-0000-0000-00000000000e', 'P2', 2);
  perform pg_temp.book('f1f1f1f1-0000-0000-0000-0000000000f1', 'P3', 3);
  perform pg_temp.as_server();
  perform pg_temp.pay('P1'); perform pg_temp.pay('P2'); perform pg_temp.pay('P3');
  perform pg_temp.depart();
  perform pg_temp.set_obs_age('tracker', 3600);   -- no usable tracker
  delete from public.vehicle_location_observations where source = 'driver_device';

  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.grant_passenger_location_consent(v_trip); raise exception 'FAIL 7a: consent accepted while the feature is off';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'feature_disabled%' then raise exception 'FAIL 7b: %', sqlerrm; end if;
  end;
  begin perform public.submit_passenger_location(v_trip, 11.65, 92.75); raise exception 'FAIL 7c: location accepted while the feature is off';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.admin_set_platform_setting('passenger_tracking_enabled', 'true'::jsonb); raise exception 'FAIL 7d: operator changed a platform setting';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  if pg_temp.track() ->> 'status' = 'estimated_passenger' then raise exception 'FAIL 7e: estimate with the flag off'; end if;
end $$;

do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); t jsonb; r jsonb;
begin
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_platform_setting('passenger_tracking_enabled', 'true'::jsonb);

  -- no consent -> no samples; a non-passenger cannot join
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.submit_passenger_location(v_trip, 11.65, 92.75); raise exception 'FAIL 7f: sample without consent';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'consent_required%' then raise exception 'FAIL 7g: %', sqlerrm; end if;
  end;
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  begin perform public.grant_passenger_location_consent(v_trip); raise exception 'FAIL 7h: a non-passenger granted consent';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- two consenting passengers are not enough (3 independent users are required)
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.grant_passenger_location_consent(v_trip); perform public.submit_passenger_location(v_trip, 11.650, 92.750, 12);
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e'); perform public.grant_passenger_location_consent(v_trip); perform public.submit_passenger_location(v_trip, 11.6502, 92.7502, 15);
  perform pg_temp.as_server();
  t := pg_temp.track();
  if t ->> 'status' = 'estimated_passenger' then raise exception 'FAIL 7i: estimate from two passengers'; end if;
  if t ->> 'status' <> 'offline' then raise exception 'FAIL 7j: insufficient confidence must read as unavailable, got %', t; end if;

  -- the third passenger makes an estimate possible
  perform pg_temp.as_user('f1f1f1f1-0000-0000-0000-0000000000f1'); perform public.grant_passenger_location_consent(v_trip); perform public.submit_passenger_location(v_trip, 11.6501, 92.7501, 10);
  -- and throttling keeps one sample per interval
  r := public.submit_passenger_location(v_trip, 11.6501, 92.7501, 10);
  if not (r ->> 'throttled')::boolean then raise exception 'FAIL 7k: not throttled'; end if;
  perform pg_temp.as_server();
  t := pg_temp.track();
  if t ->> 'status' <> 'estimated_passenger' or not (t ->> 'is_estimate')::boolean or (t ->> 'is_live')::boolean
     or t ->> 'label' <> 'Estimated — Passenger Assisted' or (t ->> 'confidence')::numeric <> 0.5 then
    raise exception 'FAIL 7l: %', t;
  end if;

  -- a working tracker always wins over passenger data
  set local role service_role; perform pg_temp.fix(11.66, 92.76); reset role;
  t := pg_temp.track();
  if t ->> 'status' <> 'live_tracker' then raise exception 'FAIL 7m: passenger data replaced a live tracker %', t; end if;
  perform pg_temp.set_obs_age('tracker', 3600);
  if pg_temp.track() ->> 'status' <> 'estimated_passenger' then raise exception 'FAIL 7n: estimate should return when the tracker is gone'; end if;

  -- far from the route corridor: rejected
  update public.vehicle_location_observations set latitude = 12.50, longitude = 93.50 where source = 'passenger_assisted';
  if pg_temp.track() ->> 'status' = 'estimated_passenger' then raise exception 'FAIL 7o: estimate far from the route'; end if;
  update public.vehicle_location_observations set latitude = 11.65, longitude = 92.75 where source = 'passenger_assisted';
  if pg_temp.track() ->> 'status' <> 'estimated_passenger' then raise exception 'FAIL 7p'; end if;

  -- stale samples do not count
  update public.vehicle_location_observations set recorded_at = now() - interval '5 minutes' where source = 'passenger_assisted';
  if pg_temp.track() ->> 'status' = 'estimated_passenger' then raise exception 'FAIL 7q: estimate from stale samples'; end if;
  update public.vehicle_location_observations set recorded_at = now() where source = 'passenger_assisted';

  -- revoking consent removes that passenger's samples and the estimate
  perform pg_temp.as_user('f1f1f1f1-0000-0000-0000-0000000000f1'); perform public.revoke_passenger_location_consent(v_trip);
  perform pg_temp.as_server();
  if exists (select 1 from public.vehicle_location_observations where source = 'passenger_assisted' and user_id = 'f1f1f1f1-0000-0000-0000-0000000000f1') then
    raise exception 'FAIL 7r: revoked passenger samples kept';
  end if;
  if pg_temp.track() ->> 'status' = 'estimated_passenger' then raise exception 'FAIL 7s: estimate after a passenger revoked'; end if;
end $$;

-- ---- 8. nobody can read individual passenger locations --------------------------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); t jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform 1 from public.vehicle_location_observations; raise exception 'FAIL 8a: operator read raw observations';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform 1 from public.vehicle_location_observations; raise exception 'FAIL 8b: passenger read raw observations';
  exception when insufficient_privilege then null; end;
  -- a booked passenger may read the vehicle status, a stranger may not
  t := public.get_trip_tracking(v_trip);
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_trip_tracking(v_trip); raise exception 'FAIL 8c: operator B tracked operator A trip';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 9. reassignment and disconnect -------------------------------------------------------------------------------
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); v_bus2 uuid := (select id from t_ref where tag = 'BUS2');
        v_dev uuid := (select id from public.gps_devices where device_identifier = 'TRK-1');
begin
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_assign_gps_device(v_dev, v_bus2);
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if (public.get_bus_gps_status(v_bus) ->> 'configured')::boolean then raise exception 'FAIL 9a: tracker still on the old bus'; end if;
  if not (public.get_bus_gps_status(v_bus2) ->> 'configured')::boolean then raise exception 'FAIL 9b'; end if;
  perform public.operator_disconnect_gps_device(v_bus2);
  if (public.get_bus_gps_status(v_bus2) ->> 'configured')::boolean then raise exception 'FAIL 9c: disconnect failed'; end if;
  perform pg_temp.as_server();
  if (select activation_status from public.gps_devices where id = v_dev) <> 'inactive' then raise exception 'FAIL 9d: disconnected device must be inactive'; end if;
  -- an inactive device's fixes are refused
  set local role service_role;
  if (public.ingest_tracker_location('acme', 'TRK-1', 11.7, 92.8) ->> 'accepted')::boolean then raise exception 'FAIL 9e: fix accepted from an inactive device'; end if;
  reset role;
end $$;

-- ---- 10. retention + device health -----------------------------------------------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_bus uuid := (select id from t_ref where tag = 'BUS');
        v_dev uuid := (select id from public.gps_devices where device_identifier = 'TRK-1');
begin
  insert into public.vehicle_location_observations (bus_id, trip_id, source, user_id, latitude, longitude, recorded_at)
    values (v_bus, v_trip, 'passenger_assisted', 'dddddddd-0000-0000-0000-00000000000d', 11.6, 92.7, now() - interval '3 days');
  insert into public.vehicle_location_observations (bus_id, source, latitude, longitude, recorded_at)
    values (v_bus, 'tracker', 11.6, 92.7, now() - interval '100 days'), (v_bus, 'tracker', 11.6, 92.7, now() - interval '1 day');
  perform private.purge_location_observations();
  if exists (select 1 from public.vehicle_location_observations where source = 'passenger_assisted' and recorded_at < now() - interval '48 hours') then raise exception 'FAIL 10a: old passenger samples kept'; end if;
  if exists (select 1 from public.vehicle_location_observations where source = 'tracker' and recorded_at < now() - interval '90 days') then raise exception 'FAIL 10b: 100-day-old tracker data kept'; end if;
  if not exists (select 1 from public.vehicle_location_observations where source = 'tracker' and recorded_at > now() - interval '2 days') then raise exception 'FAIL 10c: recent data purged'; end if;

  update public.gps_devices set activation_status = 'active', connection_status = 'online', last_communication_at = now() - interval '1 hour' where id = v_dev;
  perform private.mark_stale_gps_devices();
  if (select connection_status from public.gps_devices where id = v_dev) <> 'offline' then raise exception 'FAIL 10d: silent device should read offline'; end if;
end $$;

rollback;
