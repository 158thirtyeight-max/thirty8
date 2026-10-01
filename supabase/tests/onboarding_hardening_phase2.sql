-- =========================================================================
-- Hardening phase 2 checks for 20261002000200_payment_confirmation_integrity.sql
-- confirm_booking_after_payment confirms only a still-pending booking with the right
-- amount and still-available seats; otherwise it records the payment and queues a
-- pending refund instead of overselling. Setup shared with onboarding_phase9.sql. Rolled back.
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


insert into auth.users (id, email) values ('eeeeeeee-0000-0000-0000-00000000000e', 'cust2@test.invalid');

-- clears bookings/payments/holds and frees every seat between scenarios
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
end $f$;

-- helper: a customer holds 1 seat (Origin->Middle) and books it; stores the order id under p_tag
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

-- ---- 1. happy path ------------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O1', 1);
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_order public.orders; r jsonb; n int;
begin
  select * into v_order from public.orders where id = (select id from t_ref where tag = 'O1');
  r := public.confirm_booking_after_payment(v_order.order_reference, 'pay_ok_1', v_order.amount_cents);
  if r ->> 'status' <> 'confirmed' then raise exception 'FAIL 1a: expected confirmed, got %', r; end if;
  if (select status from public.bookings where id = v_order.orderable_id) <> 'confirmed' then raise exception 'FAIL 1b: booking not confirmed'; end if;
  select count(*) into n from public.trip_seats ts join public.booking_items bi on bi.trip_seat_id = ts.id
    where bi.booking_id = v_order.orderable_id and ts.status = 'booked' and bi.status = 'confirmed';
  if n <> 1 then raise exception 'FAIL 1c: seat not booked/confirmed'; end if;
  if (select status from public.orders where id = v_order.id) <> 'paid' then raise exception 'FAIL 1d: order not paid'; end if;
  if exists (select 1 from public.refunds) then raise exception 'FAIL 1e: refund created on happy path'; end if;

  -- replay is a no-op
  r := public.confirm_booking_after_payment(v_order.order_reference, 'pay_ok_1', v_order.amount_cents);
  if not coalesce((r ->> 'already_processed')::boolean, false) then raise exception 'FAIL 1f: replay not idempotent: %', r; end if;
  if (select count(*) from public.payments where order_id = v_order.id) <> 1 then raise exception 'FAIL 1g: duplicate payment row'; end if;

  -- at most one captured payment per order, enforced by the database
  begin
    insert into public.payments (order_id, razorpay_payment_id, amount_cents, status) values (v_order.id, 'pay_dup', 1, 'captured');
    raise exception 'FAIL 1h: second captured payment for one order accepted';
  exception when unique_violation then null; end;
end $$;

-- ---- 2. wrong amount ----------------------------------------------------
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O2', 1);
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  v_order public.orders; r jsonb;
begin
  select * into v_order from public.orders where id = (select id from t_ref where tag = 'O2');
  r := public.confirm_booking_after_payment(v_order.order_reference, 'pay_amt', v_order.amount_cents - 100);
  if r ->> 'status' <> 'refund_pending' then raise exception 'FAIL 2a: wrong amount not refused: %', r; end if;
  if (select status from public.bookings where id = v_order.orderable_id) <> 'payment_pending' then raise exception 'FAIL 2b: booking changed on wrong amount'; end if;
  if exists (select 1 from public.trip_seats ts join public.booking_items bi on bi.trip_seat_id = ts.id where bi.booking_id = v_order.orderable_id and ts.status = 'booked') then
    raise exception 'FAIL 2c: seat booked on wrong amount';
  end if;
  if not exists (select 1 from public.refunds rf join public.payments p on p.id = rf.payment_id
                 where p.razorpay_payment_id = 'pay_amt' and rf.status = 'pending' and rf.amount_cents = v_order.amount_cents - 100) then
    raise exception 'FAIL 2d: pending refund for the amount actually paid not created';
  end if;
end $$;

-- ---- 3. booking expired, seat resold, then a late payment arrives -------
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O3', 1);
reset role;
select set_config('request.jwt.claims', '', true);

-- time passes: the hold expires, the booking expires (cron), the seat is freed
update public.seat_holds set status = 'expired', expires_at = now() - interval '1 minute';
update public.trip_seats set status = 'available', hold_id = null;
update public.bookings set status = 'expired';
update public.booking_items set status = 'expired';
update public.orders set status = 'cancelled' where id = (select id from t_ref where tag = 'O3');

-- another customer buys the same seat and pays
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('eeeeeeee-0000-0000-0000-00000000000e', 'O3B', 1);
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  o3b public.orders; o3 public.orders; r jsonb;
begin
  select * into o3b from public.orders where id = (select id from t_ref where tag = 'O3B');
  select * into o3 from public.orders where id = (select id from t_ref where tag = 'O3');
  r := public.confirm_booking_after_payment(o3b.order_reference, 'pay_b', o3b.amount_cents);
  if r ->> 'status' <> 'confirmed' then raise exception 'FAIL 3a: second customer not confirmed: %', r; end if;

  -- the first customer late payment must NOT take the seat back
  r := public.confirm_booking_after_payment(o3.order_reference, 'pay_late', o3.amount_cents);
  if r ->> 'status' <> 'refund_pending' then raise exception 'FAIL 3b: late payment on expired booking not refused: %', r; end if;
  if (select status from public.bookings where id = o3.orderable_id) <> 'expired' then raise exception 'FAIL 3c: expired booking was revived'; end if;
  if (select count(*) from public.booking_items where status = 'confirmed') <> 1 then raise exception 'FAIL 3d: seat is confirmed more than once'; end if;
  if not exists (select 1 from public.refunds rf join public.payments p on p.id = rf.payment_id
                 where p.razorpay_payment_id = 'pay_late' and rf.status = 'pending' and rf.amount_cents = o3.amount_cents) then
    raise exception 'FAIL 3e: refund for the late payment not queued';
  end if;
end $$;

-- ---- 4. hold expired but the seat was never resold: payment is honoured --
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O4', 1);
reset role;
select set_config('request.jwt.claims', '', true);
update public.seat_holds set status = 'expired', expires_at = now() - interval '1 minute';
update public.trip_seats set status = 'available', hold_id = null;   -- freed by the hold-expiry job; booking still payment_pending

do $$
declare
  o public.orders; r jsonb;
begin
  select * into o from public.orders where id = (select id from t_ref where tag = 'O4');
  r := public.confirm_booking_after_payment(o.order_reference, 'pay_ok_4', o.amount_cents);
  if r ->> 'status' <> 'confirmed' then raise exception 'FAIL 4a: free seat + pending booking should confirm: %', r; end if;
  if not exists (select 1 from public.trip_seats ts join public.booking_items bi on bi.trip_seat_id = ts.id
                 where bi.booking_id = o.orderable_id and ts.status = 'booked') then
    raise exception 'FAIL 4b: seat not booked';
  end if;
end $$;

-- ---- 5. seat taken by someone else while the booking is still pending ----
select pg_temp.reset_all();
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O5', 1);
reset role;
select set_config('request.jwt.claims', '', true);
update public.seat_holds set status = 'expired', expires_at = now() - interval '1 minute';
update public.trip_seats set status = 'available', hold_id = null;
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.book('eeeeeeee-0000-0000-0000-00000000000e', 'O5B', 1);
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  o5 public.orders; o5b public.orders; r jsonb;
begin
  select * into o5 from public.orders where id = (select id from t_ref where tag = 'O5');
  select * into o5b from public.orders where id = (select id from t_ref where tag = 'O5B');
  perform public.confirm_booking_after_payment(o5b.order_reference, 'pay_5b', o5b.amount_cents);
  r := public.confirm_booking_after_payment(o5.order_reference, 'pay_5', o5.amount_cents);
  if r ->> 'status' <> 'refund_pending' then raise exception 'FAIL 5a: seat taken by another booking, payment still confirmed: %', r; end if;
  if (select count(*) from public.booking_items where status = 'confirmed') <> 1 then raise exception 'FAIL 5b: oversold'; end if;
end $$;

rollback;
