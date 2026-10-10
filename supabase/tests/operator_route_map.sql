-- =========================================================================
-- Checks for 20261008000100_route_map_geometry.sql
--   * get_trip_route_map: ordered stops, direction, the customer's own pickup / drop, authorization
--   * route geometry: staff-only inputs, service-role-only save, stale geometry never reported current
--   * tracking carries speed / heading / accuracy; phone fixes are gated and throttled
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

insert into auth.users (id, email) values ('99999999-0000-0000-0000-000000000009', 'staff@test.invalid');
insert into public.user_roles (user_id, role, operator_id)
  values ('99999999-0000-0000-0000-000000000009', 'operator_staff', (select id from t_ops where tag = 'A'));

-- stop coordinates (Port Blair -> Rangat -> Diglipur style corridor)
update public.locations set latitude = 11.6234, longitude = 92.7265 where id = (select id from t_ref where tag = 'SRC');
update public.locations set latitude = 12.4900, longitude = 92.9200 where id = (select id from t_ref where tag = 'MID');
update public.locations set latitude = 13.2700, longitude = 93.0000 where id = (select id from t_ref where tag = 'DST');
update public.boarding_points set latitude = null, longitude = null where route_id = (select id from t_ref where tag = 'ROUTE');
update public.dropping_points set latitude = null, longitude = null where route_id = (select id from t_ref where tag = 'ROUTE');

-- ---- 1. the map: ordered stops, direction, authorization ------------------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); m jsonb;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'P1', 1);
  perform pg_temp.as_server();
  perform pg_temp.pay('P1');

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  m := public.get_trip_route_map(v_trip);
  if jsonb_array_length(m -> 'stops') <> 3 then raise exception 'FAIL 1a: expected 3 stops %', m -> 'stops'; end if;
  if m -> 'stops' -> 0 ->> 'name' <> (select name from public.locations where id = (select id from t_ref where tag = 'SRC'))
     or m -> 'stops' -> 2 ->> 'name' <> (select name from public.locations where id = (select id from t_ref where tag = 'DST')) then
    raise exception 'FAIL 1b: stops not in travel order %', m -> 'stops'; end if;
  if (m -> 'stops' -> 1 ->> 'latitude')::numeric <> 12.49 then raise exception 'FAIL 1c: location coordinates not used as fallback %', m -> 'stops' -> 1; end if;
  if m ->> 'direction' <> 'outbound' then raise exception 'FAIL 1d: direction %', m ->> 'direction'; end if;
  if m -> 'geometry' <> 'null'::jsonb then raise exception 'FAIL 1e: invented geometry %', m -> 'geometry'; end if;
  if m -> 'my_pickup_location_id' <> 'null'::jsonb then raise exception 'FAIL 1f: staff got a customer pickup'; end if;

  -- booked customer: sees own pickup / drop
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  m := public.get_trip_route_map(v_trip);
  if (m ->> 'my_pickup_location_id')::uuid <> (select id from t_ref where tag = 'SRC')
     or (m ->> 'my_drop_location_id')::uuid <> (select id from t_ref where tag = 'MID') then
    raise exception 'FAIL 1g: own pickup/drop wrong %', m; end if;

  -- unbooked customer and the other operator are refused
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  begin perform public.get_trip_route_map(v_trip); raise exception 'FAIL 1h: non-passenger read the trip map';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_trip_route_map(v_trip); raise exception 'FAIL 1i: other operator read the trip map';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 2. geometry: inputs are staff-only, saving is service-role only, stale is never current --------------------
do $$
declare v_route uuid := (select id from t_ref where tag = 'ROUTE'); v_trip uuid := (select id from t_ref where tag = 'TRIP');
        i jsonb; r jsonb; m jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  i := public.get_route_geometry_inputs(v_route);
  if jsonb_array_length(i -> 'waypoints') <> 3 or (i ->> 'is_current')::boolean then raise exception 'FAIL 2a: %', i; end if;

  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.get_route_geometry_inputs(v_route); raise exception 'FAIL 2b: customer read geometry inputs';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_route_geometry_inputs(v_route); raise exception 'FAIL 2c: other operator read geometry inputs';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.save_route_geometry(v_route, i ->> 'stops_hash', '_p~iF~ps|U_ulLnnqC', 100, 10); raise exception 'FAIL 2d: client saved geometry';
  exception when insufficient_privilege then null; end;
  begin perform 1 from public.route_geometries; raise exception 'FAIL 2e: client read route_geometries';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  set local role service_role;
  r := public.save_route_geometry(v_route, 'not-the-hash', '_p~iF~ps|U_ulLnnqC', 100, 10);
  if (r ->> 'saved')::boolean then raise exception 'FAIL 2f: saved geometry for the wrong stops'; end if;
  r := public.save_route_geometry(v_route, i ->> 'stops_hash', '_p~iF~ps|U_ulLnnqC', 123456, 7200);
  if not (r ->> 'saved')::boolean then raise exception 'FAIL 2g: %', r; end if;
  reset role;

  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  m := public.get_trip_route_map(v_trip);
  if not (m -> 'geometry' ->> 'is_current')::boolean or m -> 'geometry' ->> 'polyline6' is null then raise exception 'FAIL 2h: %', m -> 'geometry'; end if;
  perform pg_temp.as_server();

  -- a stop moves: the stored geometry is no longer the route
  update public.locations set latitude = 12.6000 where id = (select id from t_ref where tag = 'MID');
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  m := public.get_trip_route_map(v_trip);
  if (m -> 'geometry' ->> 'is_current')::boolean then raise exception 'FAIL 2i: stale geometry reported current'; end if;
  perform pg_temp.as_server();
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if (public.get_route_geometry_inputs(v_route) ->> 'is_current')::boolean then raise exception 'FAIL 2j: stale geometry not flagged for rebuild'; end if;
  perform pg_temp.as_server();
end $$;

-- ---- 3. live fix: speed / heading / accuracy, fallback gate, throttle -------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_bus uuid := (select id from t_ref where tag = 'BUS'); r jsonb; t jsonb;
begin
  update public.bus_trips set status = 'departed', departure_at = now() - interval '1 hour' where id = v_trip;

  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  r := public.update_bus_location(v_trip, 11.70, 92.80, 12, 40, 90);
  if (r ->> 'accepted')::boolean or r ->> 'reason' <> 'driver_fallback_disabled' then raise exception 'FAIL 3a: phone fix accepted without fallback %', r; end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_bus_driver_fallback(v_bus, true);
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  r := public.update_bus_location(v_trip, 11.70, 92.80, 12, 40, 90);
  if not (r ->> 'accepted')::boolean then raise exception 'FAIL 3b: %', r; end if;
  r := public.update_bus_location(v_trip, 11.7001, 92.8001, 12, 41, 91);
  if (r ->> 'accepted')::boolean or r ->> 'reason' <> 'throttled' then raise exception 'FAIL 3c: fix not throttled %', r; end if;

  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  t := public.get_trip_tracking(v_trip);
  if t ->> 'status' <> 'live_verified_fallback' then raise exception 'FAIL 3d: %', t; end if;
  if (t ->> 'speed_kmh')::numeric <> 40 or (t ->> 'heading')::numeric <> 90 or (t ->> 'accuracy_m')::numeric <> 12 then raise exception 'FAIL 3e: %', t; end if;

  -- a bad heading is dropped rather than invented
  perform pg_temp.as_server();
  update public.vehicle_location_observations set received_at = now() - interval '1 minute' where source = 'driver_device';
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  perform public.update_bus_location(v_trip, 11.7002, 92.8002, 12, -1, 400);
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  t := public.get_trip_tracking(v_trip);
  if t -> 'heading' <> 'null'::jsonb or t -> 'speed_kmh' <> 'null'::jsonb then raise exception 'FAIL 3f: invented heading/speed %', t; end if;
  perform pg_temp.as_server();
end $$;

rollback;
select 'ok';
