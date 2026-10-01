-- =========================================================================
-- Hardening phase 4 checks for 20261002000400_operator_write_lockdown.sql
-- Operators cannot write routes/points/services/trips/fares directly; set_trip_status is the
-- controlled path; ownership guards hold. Setup shared with onboarding_phase9.sql. Rolled back.
-- =========================================================================
-- Phase 9 checks for 20260926000800_fare_engine.sql
-- The fare engine must give the SAME price in search, seat map, hold quote and
-- booking. Run after pushing migrations (see onboarding_phase2.sql header).
-- Everything is rolled back.
-- =========================================================================
begin;

-- Seat ids of a trip, read with definer rights: since 20261002000600 customers can no longer read
-- trip_seats directly (a real client gets seat ids from get_trip_seat_map).
create function pg_temp.t_seats(p_trip uuid, p_n int, p_skip int default 0, p_avail boolean default false) returns uuid[]
language sql security definer as $f$
  select array_agg(seat_id) from (
    select seat_id from public.trip_seats
    where trip_id = p_trip and (not p_avail or status = 'available')
    order by seat_id offset p_skip limit p_n) x
$f$;
grant execute on function pg_temp.t_seats(uuid, int, int, boolean) to authenticated, anon;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('dddddddd-0000-0000-0000-00000000000d', 'cust@test.invalid');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;
create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;

insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Src') returning id)
  insert into t_ref select 'SRC', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Mid') returning id)
  insert into t_ref select 'MID', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Dst') returning id)
  insert into t_ref select 'DST', id from c;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;

-- bus with a 3-seat layout, a 3-stop route, fares and charges
insert into t_ref select 'BUS', (public.create_bus((select id from t_ops where tag = 'A'), 'Fare Bus', 'AN01F0001', 'ac_seater', 3)).id;

do $$
declare
  v_bus uuid := (select id from t_ref where tag = 'BUS');
  r jsonb;
begin
  r := public.save_bus_layout(v_bus, '{"rows":2,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"}
  ]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup layout: %', r -> 'errors'; end if;

  r := public.save_bus_route(v_bus, (select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'),
    100, '06:00', 240, '{1,2,3,4,5,6,7}', jsonb_build_array(
      jsonb_build_object('name','Origin','city_id',(select id from t_ref where tag='SRC'),'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Middle','city_id',(select id from t_ref where tag='MID'),'is_boarding',true,'is_dropping',true,'arrival_offset_min',120,'departure_offset_min',125),
      jsonb_build_object('name','Dest','city_id',(select id from t_ref where tag='DST'),'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup route: %', r -> 'errors'; end if;
end $$;

insert into t_ref select 'B_ORIGIN', id from public.boarding_points where city_id = (select id from t_ref where tag = 'SRC') and route_id = (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
insert into t_ref select 'B_MID',    id from public.boarding_points where city_id = (select id from t_ref where tag = 'MID') and route_id = (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
insert into t_ref select 'D_MID',    id from public.dropping_points where city_id = (select id from t_ref where tag = 'MID') and route_id = (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
insert into t_ref select 'D_DEST',   id from public.dropping_points where city_id = (select id from t_ref where tag = 'DST') and route_id = (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));

do $$
declare
  v_bus uuid := (select id from t_ref where tag = 'BUS');
  r jsonb;
begin
  -- base 500.00; Origin->Middle 200.00; Middle->Dest 300.00; anything->Dest 450.00; charges: 10.00 flat + 5%
  r := public.save_bus_fares(v_bus, jsonb_build_array(
      jsonb_build_object('seat_type','seater','base_fare_cents',50000),
      jsonb_build_object('seat_type','seater','base_fare_cents',20000,'from_point_id',(select id from t_ref where tag='B_ORIGIN'),'to_point_id',(select id from t_ref where tag='D_MID')),
      jsonb_build_object('seat_type','seater','base_fare_cents',30000,'from_point_id',(select id from t_ref where tag='B_MID'),'to_point_id',(select id from t_ref where tag='D_DEST')),
      jsonb_build_object('seat_type','seater','base_fare_cents',45000,'to_point_id',(select id from t_ref where tag='D_DEST'))
    ), jsonb_build_array(
      jsonb_build_object('name','Convenience fee','kind','flat','flat_cents',1000),
      jsonb_build_object('name','GST','kind','percent','percent',5)
    ));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup fares: %', r -> 'errors'; end if;

  -- validation: a bus with no base fare for a used seat type is invalid
  begin
    perform public.save_bus_fares(v_bus, '[]'::jsonb, '[]'::jsonb);
    if (public.validate_bus_fares(v_bus) ->> 'valid')::boolean then
      raise exception 'FAIL 0a: no fares reported valid';
    end if;
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  r := public.save_bus_fares(v_bus, jsonb_build_array(
      jsonb_build_object('seat_type','seater','base_fare_cents',50000),
      jsonb_build_object('seat_type','seater','base_fare_cents',20000,'from_point_id',(select id from t_ref where tag='B_ORIGIN'),'to_point_id',(select id from t_ref where tag='D_MID')),
      jsonb_build_object('seat_type','seater','base_fare_cents',30000,'from_point_id',(select id from t_ref where tag='B_MID'),'to_point_id',(select id from t_ref where tag='D_DEST')),
      jsonb_build_object('seat_type','seater','base_fare_cents',45000,'to_point_id',(select id from t_ref where tag='D_DEST'))
    ), jsonb_build_array(
      jsonb_build_object('name','Convenience fee','kind','flat','flat_cents',1000),
      jsonb_build_object('name','GST','kind','percent','percent',5)
    ));

  -- backwards point-to-point fare is refused
  begin
    perform public.save_bus_fares(v_bus, jsonb_build_array(
      jsonb_build_object('seat_type','seater','base_fare_cents',50000),
      jsonb_build_object('seat_type','seater','base_fare_cents',100,'from_point_id',(select id from t_ref where tag='B_MID'),'to_point_id',(select id from t_ref where tag='D_MID'))), '[]'::jsonb);
    raise exception 'FAIL 0b: same-stop fare accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- restore good fares
  perform public.save_bus_fares(v_bus, jsonb_build_array(
      jsonb_build_object('seat_type','seater','base_fare_cents',50000),
      jsonb_build_object('seat_type','seater','base_fare_cents',20000,'from_point_id',(select id from t_ref where tag='B_ORIGIN'),'to_point_id',(select id from t_ref where tag='D_MID')),
      jsonb_build_object('seat_type','seater','base_fare_cents',30000,'from_point_id',(select id from t_ref where tag='B_MID'),'to_point_id',(select id from t_ref where tag='D_DEST')),
      jsonb_build_object('seat_type','seater','base_fare_cents',45000,'to_point_id',(select id from t_ref where tag='D_DEST'))
    ), jsonb_build_array(
      jsonb_build_object('name','Convenience fee','kind','flat','flat_cents',1000),
      jsonb_build_object('name','GST','kind','percent','percent',5)));
end $$;

-- activate the bus/service and create a trip (server-side; the activation workflow arrives in Phase 11)
reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'active' where id = (select id from t_ref where tag = 'BUS');
update public.bus_services set status = 'active' where bus_id = (select id from t_ref where tag = 'BUS');
with s as (select id, operator_id, route_id, bus_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS')),
     t as (
       insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at)
       select id, operator_id, route_id, bus_id, current_date + 2, (current_date + 2) + time '06:00', (current_date + 2) + time '10:00' from s
       returning id)
insert into t_ref select 'TRIP', id from t;


insert into auth.users (id, email) values
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('ffffffff-0000-0000-0000-00000000000f', 'admin@test.invalid');
insert into public.user_roles (user_id, role) values ('ffffffff-0000-0000-0000-00000000000f', 'platform_admin');

-- a second, approved operator with a bus of its own
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved' where id = (select id from t_ops where tag = 'B');
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'BUS_B', (public.create_bus((select id from t_ops where tag = 'B'), 'B Bus', 'AN01F0002', 'ac_seater', 3)).id;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---- 1. operator A can read its data but not write it directly -----------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_op uuid := (select id from t_ops where tag = 'A');
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_svc uuid; v_route uuid; n int; before_fare int; after_fare int;
begin
  select id, route_id into v_svc, v_route from public.bus_services where operator_id = v_op limit 1;

  -- reads still work
  if not exists (select 1 from public.bus_routes where operator_id = v_op) then raise exception 'FAIL 1a: operator cannot read its routes'; end if;
  if not exists (select 1 from public.bus_trips where id = v_trip) then raise exception 'FAIL 1b: operator cannot read its trips'; end if;
  if not exists (select 1 from public.fare_rules where service_id = v_svc) then raise exception 'FAIL 1c: operator cannot read its fares'; end if;

  -- direct updates change nothing (no UPDATE policy -> 0 rows)
  select min(base_fare_cents) into before_fare from public.fare_rules where service_id = v_svc;
  update public.fare_rules set base_fare_cents = 1 where service_id = v_svc;
  get diagnostics n = row_count;
  select min(base_fare_cents) into after_fare from public.fare_rules where service_id = v_svc;
  if n <> 0 or after_fare <> before_fare then raise exception 'FAIL 1d: operator changed fares directly (% rows)', n; end if;

  update public.fare_charges set flat_cents = 1 where service_id = v_svc; get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 1e: operator changed fare charges directly'; end if;
  update public.bus_services set status = 'paused' where id = v_svc; get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 1f: operator changed its service directly'; end if;
  update public.bus_routes set distance_km = 1 where id = v_route; get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 1g: operator changed its route directly'; end if;
  update public.bus_trips set status = 'cancelled' where id = v_trip; get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 1h: operator changed trip status directly'; end if;
  update public.boarding_points set name = 'x' where route_id = v_route; get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 1i: operator changed boarding points directly'; end if;
  update public.dropping_points set name = 'x' where route_id = v_route; get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 1j: operator changed dropping points directly'; end if;
  delete from public.bus_trips where id = v_trip; get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 1k: operator deleted a trip directly'; end if;

  -- direct inserts are refused
  begin
    insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at)
    values (v_svc, v_op, v_route, (select id from t_ref where tag = 'BUS'), current_date + 9, (current_date + 9) + time '06:00');
    raise exception 'FAIL 1l: operator inserted a trip directly';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.bus_routes (operator_id, source_city_id, destination_city_id)
    values (v_op, (select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'));
    raise exception 'FAIL 1m: operator inserted a route directly';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.boarding_points (route_id, name, sequence_no) values (v_route, 'Hack', 99);
    raise exception 'FAIL 1n: operator inserted a boarding point directly';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---- 2. operator B cannot even see A's drafts through the operator policy, and cannot move A's trips
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.set_trip_status((select id from t_ref where tag = 'TRIP'), 'boarding');
    raise exception 'FAIL 2a: another operator changed this trip status';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'Not authorized%' then raise exception 'FAIL 2a: unexpected error %', sqlerrm; end if;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---- 3. set_trip_status: the controlled path ----------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  r jsonb;
begin
  begin
    perform public.set_trip_status(v_trip, 'arrived');
    raise exception 'FAIL 3a: scheduled -> arrived accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'invalid_transition%' then raise exception 'FAIL 3a: unexpected error %', sqlerrm; end if;
  end;
  begin
    perform public.set_trip_status(v_trip, 'flying');
    raise exception 'FAIL 3b: unknown status accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'invalid_status%' then raise exception 'FAIL 3b: unexpected error %', sqlerrm; end if;
  end;
  r := public.set_trip_status(v_trip, 'boarding');
  if r ->> 'status' <> 'boarding' then raise exception 'FAIL 3c: %', r; end if;
  r := public.set_trip_status(v_trip, 'departed');
  r := public.set_trip_status(v_trip, 'arrived');
  if (select status from public.bus_trips where id = v_trip) <> 'arrived' then raise exception 'FAIL 3d: status not arrived'; end if;
  begin
    perform public.set_trip_status(v_trip, 'cancelled');
    raise exception 'FAIL 3e: an arrived trip was cancelled';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'invalid_transition%' then raise exception 'FAIL 3e: unexpected error %', sqlerrm; end if;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  if (select count(*) from public.audit_logs where action = 'trip.status_changed') <> 3 then
    raise exception 'FAIL 3f: expected 3 audit rows for the status changes, found %', (select count(*) from public.audit_logs where action = 'trip.status_changed');
  end if;
end $$;

-- a trip with a live booking cannot be cancelled this way; one without can; an admin can too
update public.bus_trips set status = 'scheduled';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  h jsonb;
begin
  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 1), 300,
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  begin
    perform public.set_trip_status(v_trip, 'boarding');
    raise exception 'FAIL 3g: a customer changed a trip status';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'Not authorized%' then raise exception 'FAIL 3g: unexpected error %', sqlerrm; end if;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.set_trip_status((select id from t_ref where tag = 'TRIP'), 'cancelled');
    raise exception 'FAIL 3h: trip with a pending booking was cancelled';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'trip_has_bookings%' then raise exception 'FAIL 3h: unexpected error %', sqlerrm; end if;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
update public.booking_items set status = 'cancelled';
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-00000000000f","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if public.set_trip_status((select id from t_ref where tag = 'TRIP'), 'cancelled') ->> 'status' <> 'cancelled' then
    raise exception 'FAIL 3i: admin could not cancel a trip with no active bookings';
  end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- a suspended operator cannot move trips
update public.bus_trips set status = 'scheduled';
update public.operators set status = 'suspended' where id = (select id from t_ops where tag = 'A');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.set_trip_status((select id from t_ref where tag = 'TRIP'), 'boarding');
    raise exception 'FAIL 3j: suspended operator changed a trip status';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'Operator is not approved%' then raise exception 'FAIL 3j: unexpected error %', sqlerrm; end if;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved' where id = (select id from t_ops where tag = 'A');

-- ---- 4. ownership guards hold even for privileged writers ---------------
do $$
declare
  v_a uuid := (select id from t_ops where tag = 'A');
  v_b uuid := (select id from t_ops where tag = 'B');
  v_svc public.bus_services;
begin
  select * into v_svc from public.bus_services where operator_id = v_a limit 1;

  -- a trip of operator B pointing at operator A's service
  begin
    insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at)
    values (v_svc.id, v_b, v_svc.route_id, (select id from t_ref where tag = 'BUS_B'), current_date + 20, (current_date + 20) + time '06:00');
    raise exception 'FAIL 4a: a trip was created under another operator service';
  exception when check_violation then null; end;

  -- operator A trip using operator B's bus
  begin
    insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at)
    values (v_svc.id, v_a, v_svc.route_id, (select id from t_ref where tag = 'BUS_B'), current_date + 21, (current_date + 21) + time '06:00');
    raise exception 'FAIL 4b: a trip was created on another operator bus';
  exception when check_violation then null; end;

  -- trip route differing from its service route
  begin
    insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at)
    select v_svc.id, v_a, r.id, v_svc.bus_id, current_date + 22, (current_date + 22) + time '06:00'
    from public.bus_routes r where r.id <> v_svc.route_id limit 1;
    -- no other route may exist in this fixture; only fail if a row was actually inserted
    if found then raise exception 'FAIL 4c: a trip was created with a route that is not its service route'; end if;
  exception when check_violation then null; end;

  -- service on another operator's bus / route
  begin
    insert into public.bus_services (operator_id, route_id, bus_id, service_code, service_name, service_source_city_id, service_dest_city_id, default_departure_time, default_arrival_offset_minutes)
    values (v_a, v_svc.route_id, (select id from t_ref where tag = 'BUS_B'), 'BADSVC1', 'Bad', v_svc.service_source_city_id, v_svc.service_dest_city_id, '06:00', 60);
    raise exception 'FAIL 4d: a service was created on another operator bus';
  exception when check_violation then null; end;

  -- route on another operator's bus
  begin
    insert into public.bus_routes (operator_id, bus_id, source_city_id, destination_city_id)
    values (v_a, (select id from t_ref where tag = 'BUS_B'), (select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'));
    raise exception 'FAIL 4e: a route was created on another operator bus';
  exception when check_violation then null; end;

  -- legitimate generation through the RPC path still works (trigger accepts consistent rows)
  update public.bus_trips set status = 'scheduled';
end $$;

-- the supported path: generate_bus_trips as the owning operator creates consistent trips
update public.bus_services set schedule_configured = true, operating_days = '{1,2,3,4,5,6,7}' where bus_id = (select id from t_ref where tag = 'BUS');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  n := public.generate_bus_trips((select id from t_ref where tag = 'BUS'), current_date + 30, current_date + 36);
  if n < 1 then raise exception 'FAIL 4f: generate_bus_trips created no trips (% )', n; end if;
end $$;
reset role;

rollback;
