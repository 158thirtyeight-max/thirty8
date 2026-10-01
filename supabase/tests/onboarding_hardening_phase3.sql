-- =========================================================================
-- Hardening phase 3 checks for 20261002000300_booking_window_enforcement.sql
-- Booking windows, trip status/departure, cancel_booking seat handling, roll_trip_status.
-- Setup shared with onboarding_phase9.sql. Rolled back.
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
  ('eeeeeeee-0000-0000-0000-00000000000e', 'cust2@test.invalid'),
  ('ffffffff-0000-0000-0000-00000000000f', 'admin@test.invalid');
insert into public.user_roles (user_id, role) values ('ffffffff-0000-0000-0000-00000000000f', 'platform_admin');

create function pg_temp.reset_all() returns void language plpgsql as $f$
begin
  delete from public.refunds;
  delete from public.payments;
  delete from public.orders;
  delete from public.booking_items;
  delete from public.passengers;
  delete from public.booking_status_history;
  delete from public.bookings;
  update public.trip_seats set status = 'available', hold_id = null;
  delete from public.seat_holds;
  update public.bus_trips set status = 'scheduled', departure_at = (current_date + 2) + time '06:00',
    booking_open_at = now() - interval '1 day', booking_close_at = null,
    available_seats = (select count(*) from public.trip_seats where trip_id = bus_trips.id);
end $f$;

-- hold + (optionally) book 1 seat as the given user; stores order id under p_tag
create function pg_temp.book(p_user uuid, p_tag text, p_seat_no int) returns void language plpgsql as $f$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid; h jsonb; bk jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  v_seat := (pg_temp.t_seats(v_trip, 1, p_seat_no - 1, false))[1];
  h := public.create_seat_hold(v_trip, array[v_seat], 300,
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  bk := public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
         '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"}]'::jsonb,
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  delete from t_ref where tag = p_tag;
  insert into t_ref values (p_tag, (bk ->> 'order_id')::uuid);
end $f$;
grant execute on function pg_temp.book(uuid, text, int) to authenticated;

-- ---- 1. open trip is searchable, shows a seat map and can be held --------
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  res jsonb; h jsonb;
begin
  res := public.search_trips(v_src, v_dst, current_date + 2);
  if not exists (select 1 from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip) then
    raise exception 'FAIL 1a: open trip missing from search';
  end if;
  if public.get_trip_seat_map(v_trip) is null then raise exception 'FAIL 1b: open trip has no seat map'; end if;
  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 1), 300);
  perform public.release_seat_hold((h ->> 'hold_token')::uuid);
end $$;

-- ---- 2. each way a trip can be closed to sales ---------------------------
reset role;
select set_config('request.jwt.claims', '', true);
create function pg_temp.expect_closed(p_label text) returns void language plpgsql as $f$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  res jsonb;
begin
  res := public.search_trips(v_src, v_dst, current_date + 2);
  if exists (select 1 from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip) then
    raise exception 'FAIL %: closed trip still in search', p_label;
  end if;
  if public.get_trip_seat_map(v_trip) is not null then
    raise exception 'FAIL %: closed trip still has a seat map', p_label;
  end if;
  begin
    perform public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 1), 300);
    raise exception 'FAIL %: hold accepted on a closed trip', p_label;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'trip_closed%' then raise exception 'FAIL %: unexpected error %', p_label, sqlerrm; end if;
  end;
end $f$;
grant execute on function pg_temp.expect_closed(text) to authenticated;

-- 2a. sales window already closed (departure minus cutoff has passed)
update public.bus_trips set booking_close_at = now() - interval '1 minute';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.expect_closed('2a');
reset role; select set_config('request.jwt.claims', '', true);
update public.bus_trips set booking_close_at = null;

-- 2b. sales window not open yet
update public.bus_trips set booking_open_at = now() + interval '1 day';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.expect_closed('2b');
reset role; select set_config('request.jwt.claims', '', true);
update public.bus_trips set booking_open_at = now() - interval '1 day';

-- 2c. already departed (cron has not rolled the status yet)
update public.bus_trips set departure_at = now() - interval '1 minute';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.expect_closed('2c');
reset role; select set_config('request.jwt.claims', '', true);
update public.bus_trips set departure_at = (current_date + 2) + time '06:00';

-- 2d. cancelled trip
update public.bus_trips set status = 'cancelled';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.expect_closed('2d');
reset role; select set_config('request.jwt.claims', '', true);
update public.bus_trips set status = 'scheduled';

-- ---- 3. create_booking: window enforced at hold time, departure at booking time
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  h jsonb;
begin
  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 1), 300,
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform set_config('t.hold', h ->> 'hold_token', true);
end $$;
reset role; select set_config('request.jwt.claims', '', true);

-- the sales window closes while the customer is on the passenger screen: booking still allowed
update public.bus_trips set booking_close_at = now() - interval '1 minute';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare bk jsonb;
begin
  bk := public.create_booking(current_setting('t.hold')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  if bk ->> 'booking_id' is null then raise exception 'FAIL 3a: booking inside the hold lifetime refused after the sales window closed'; end if;
end $$;
reset role; select set_config('request.jwt.claims', '', true);

-- but never once the bus has left
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  h jsonb;
begin
  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 1), 300,
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform set_config('t.hold', h ->> 'hold_token', true);
end $$;
reset role; select set_config('request.jwt.claims', '', true);
update public.bus_trips set departure_at = now() - interval '1 minute';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.create_booking(current_setting('t.hold')::uuid, 'c@test.invalid', '9876543210',
      '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"}]'::jsonb,
      (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
    raise exception 'FAIL 3b: booking accepted for a trip that has departed';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'trip_closed%' then raise exception 'FAIL 3b: unexpected error %', sqlerrm; end if;
  end;
end $$;
reset role; select set_config('request.jwt.claims', '', true);

-- ---- 4. cancel_booking: seat counter, departed trips, stale pending bookings
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O4', 1);
reset role; select set_config('request.jwt.claims', '', true);

do $$
declare
  o public.orders; r jsonb; v_trip uuid := (select id from t_ref where tag = 'TRIP');
begin
  select * into o from public.orders where id = (select id from t_ref where tag = 'O4');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_c1', o.amount_cents);
  if (select available_seats from public.bus_trips where id = v_trip) <> (select count(*) from public.trip_seats where trip_id = v_trip and status = 'available') then
    raise exception 'FAIL 4a: setup - counter not in sync after confirmation';
  end if;
  perform set_config('t.bk4', o.orderable_id::text, true);
end $$;

-- departed: the customer cannot cancel, an admin can
update public.bus_trips set departure_at = now() - interval '1 minute';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.cancel_booking(current_setting('t.bk4')::uuid, 'changed my mind');
    raise exception 'FAIL 4b: customer cancelled a booking on a departed trip';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'trip_departed%' then raise exception 'FAIL 4b: unexpected error %', sqlerrm; end if;
  end;
end $$;
reset role; select set_config('request.jwt.claims', '', true);
update public.bus_trips set departure_at = (current_date + 2) + time '06:00';

-- before departure: the customer cancels, seat is freed and the counter follows
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); r jsonb;
begin
  r := public.cancel_booking(current_setting('t.bk4')::uuid, 'changed my mind');
  if r ->> 'status' <> 'cancelled' then raise exception 'FAIL 4c: cancel failed: %', r; end if;
  if r ->> 'refund_id' is null then raise exception 'FAIL 4c2: confirmed booking cancelled without a refund row'; end if;
end $$;
reset role; select set_config('request.jwt.claims', '', true);
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP');
begin
  if (select count(*) from public.trip_seats where trip_id = v_trip and status <> 'available') <> 0 then raise exception 'FAIL 4d: seat not freed'; end if;
  if (select available_seats from public.bus_trips where id = v_trip) <> (select count(*) from public.trip_seats where trip_id = v_trip) then
    raise exception 'FAIL 4e: available_seats not refreshed after cancel';
  end if;
end $$;

-- admin can cancel after departure
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O4B', 1);
reset role; select set_config('request.jwt.claims', '', true);
do $$
declare o public.orders;
begin
  select * into o from public.orders where id = (select id from t_ref where tag = 'O4B');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_c2', o.amount_cents);
  perform set_config('t.bk4b', o.orderable_id::text, true);
end $$;
update public.bus_trips set departure_at = now() - interval '1 minute';
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-00000000000f","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if public.cancel_booking(current_setting('t.bk4b')::uuid, 'ops') ->> 'status' <> 'cancelled' then raise exception 'FAIL 4f: admin cancel failed'; end if;
end $$;
reset role; select set_config('request.jwt.claims', '', true);

-- stale pending booking: its hold expired, the seat was resold; cancelling it must not free the new owner's seat
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O4C', 1);
reset role; select set_config('request.jwt.claims', '', true);
update public.seat_holds set status = 'expired', expires_at = now() - interval '1 minute';
update public.trip_seats set status = 'available', hold_id = null;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('eeeeeeee-0000-0000-0000-00000000000e', 'O4D', 1);
reset role; select set_config('request.jwt.claims', '', true);
do $$
declare o4d public.orders; o4c public.orders; v_trip uuid := (select id from t_ref where tag = 'TRIP');
begin
  select * into o4d from public.orders where id = (select id from t_ref where tag = 'O4D');
  select * into o4c from public.orders where id = (select id from t_ref where tag = 'O4C');
  perform public.confirm_booking_after_payment(o4d.order_reference, 'pay_c4d', o4d.amount_cents);
  perform set_config('t.bk4c', o4c.orderable_id::text, true);
end $$;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$ begin perform public.cancel_booking(current_setting('t.bk4c')::uuid, 'stale'); end $$;
reset role; select set_config('request.jwt.claims', '', true);
do $$
begin
  if (select count(*) from public.trip_seats ts join public.booking_items bi on bi.trip_seat_id = ts.id
      where bi.status = 'confirmed' and ts.status = 'booked') <> 1 then
    raise exception 'FAIL 4g: cancelling a stale pending booking freed a seat that now belongs to another confirmed booking';
  end if;
end $$;

-- ---- 5. roll_trip_status also rolls trips that were missed for more than a day
select pg_temp.reset_all();
update public.bus_trips set departure_at = now() - interval '3 days', arrival_at = now() - interval '3 days' + interval '4 hours';
do $$
begin
  perform private.roll_trip_status();
  if (select status from public.bus_trips limit 1) <> 'arrived' then
    raise exception 'FAIL 5: a trip that departed 3 days ago is still %', (select status from public.bus_trips limit 1);
  end if;
end $$;

rollback;
