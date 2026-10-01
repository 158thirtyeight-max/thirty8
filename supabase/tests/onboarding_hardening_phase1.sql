-- =========================================================================
-- Hardening phase 1 checks for 20261002000100_booking_hold_integrity.sql
--   * hold lifetime is clamped server-side
--   * one hold can back only one booking (hold_already_used)
--   * at most one confirmed item per trip seat (unique index)
-- Setup (operator, bus, layout, route, fares, active bus, trip) is shared with
-- onboarding_phase9.sql. Everything is rolled back.
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


-- ---- 1. hold lifetime clamp --------------------------------------------
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  seats uuid[];
  h jsonb; secs numeric;
begin
  seats := pg_temp.t_seats(v_trip, 3, 0, false);

  -- absurdly long TTL is capped at 10 minutes
  h := public.create_seat_hold(v_trip, seats[1:1], 999999999);
  secs := extract(epoch from ((h ->> 'expires_at')::timestamptz - now()));
  if secs > 601 then raise exception 'FAIL 1a: TTL not capped (% s)', secs; end if;
  if secs < 590 then raise exception 'FAIL 1a2: capped TTL should be ~600s, got % s', secs; end if;
  perform public.release_seat_hold((h ->> 'hold_token')::uuid);

  -- negative / zero TTL is raised to 30 seconds
  h := public.create_seat_hold(v_trip, seats[1:1], -500);
  secs := extract(epoch from ((h ->> 'expires_at')::timestamptz - now()));
  if secs < 29 or secs > 31 then raise exception 'FAIL 1b: negative TTL should become 30s, got % s', secs; end if;
  perform public.release_seat_hold((h ->> 'hold_token')::uuid);

  -- null TTL falls back to the 5 minute default
  h := public.create_seat_hold(v_trip, seats[1:1], null);
  secs := extract(epoch from ((h ->> 'expires_at')::timestamptz - now()));
  if secs < 295 or secs > 301 then raise exception 'FAIL 1c: null TTL should become 300s, got % s', secs; end if;
  perform public.release_seat_hold((h ->> 'hold_token')::uuid);

  -- a normal TTL is honoured
  h := public.create_seat_hold(v_trip, seats[1:1], 120);
  secs := extract(epoch from ((h ->> 'expires_at')::timestamptz - now()));
  if secs < 119 or secs > 121 then raise exception 'FAIL 1d: 120s TTL not honoured, got % s', secs; end if;
  perform public.release_seat_hold((h ->> 'hold_token')::uuid);
end $$;

-- ---- 2. one booking per hold -------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  seats uuid[]; h jsonb; bk jsonb; n int;
  pax jsonb := '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"},{"full_name":"B","age":30,"gender":"female","phone":"9876543211"}]';
begin
  seats := pg_temp.t_seats(v_trip, 2, 0, false);
  h := public.create_seat_hold(v_trip, seats, 300, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  bk := public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210', pax, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));

  begin
    perform public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210', pax, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
    raise exception 'FAIL 2a: second booking accepted for the same hold';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'hold_already_used%' then raise exception 'FAIL 2a: unexpected error %', sqlerrm; end if;
  end;

  select count(*) into n from public.bookings where customer_id = 'dddddddd-0000-0000-0000-00000000000d';
  if n <> 1 then raise exception 'FAIL 2b: expected exactly 1 booking, found %', n; end if;
  select count(*) into n from public.orders where customer_id = 'dddddddd-0000-0000-0000-00000000000d';
  if n <> 1 then raise exception 'FAIL 2c: expected exactly 1 order, found %', n; end if;
  select count(*) into n from public.booking_items where booking_id = (bk ->> 'booking_id')::uuid;
  if n <> 2 then raise exception 'FAIL 2d: expected 2 booking items, found %', n; end if;
  perform set_config('t.booking', bk ->> 'booking_id', true);
end $$;

-- a different hold on different seats still books normally (the guard is per hold)
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  seats uuid[]; h jsonb; bk jsonb;
begin
  seats := pg_temp.t_seats(v_trip, 1, 0, true);
  h := public.create_seat_hold(v_trip, seats, 300, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  bk := public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"C","age":30,"gender":"male","phone":"9876543212"}]'::jsonb, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  if bk ->> 'booking_id' is null then raise exception 'FAIL 2e: normal booking on a fresh hold failed'; end if;
end $$;

-- a stale PENDING item from an expired hold must not block another customer booking the same seat
-- (regression for 20261002000150_fix_hold_guard.sql)
reset role;
select set_config('request.jwt.claims', '', true);
-- start from a clean seat state: earlier sections left every seat held/pending
update public.booking_items set status = 'expired';
update public.seat_holds set status = 'expired', expires_at = now() - interval '1 minute';
update public.trip_seats set status = 'available', hold_id = null;
insert into auth.users (id, email) values ('eeeeeeee-0000-0000-0000-00000000000e', 'cust2@test.invalid');
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid; h jsonb;
begin
  v_seat := (pg_temp.t_seats(v_trip, 1, 0, true))[1];
  h := public.create_seat_hold(v_trip, array[v_seat], 300, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"D","age":30,"gender":"male","phone":"9876543213"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform set_config('t.stale_seat', v_seat::text, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
-- the hold expires and its seat is freed, but the booking is still payment_pending (cron expires it 30 min after creation)
update public.seat_holds set status = 'expired', expires_at = now() - interval '1 minute'
  where id = (select hold_id from public.trip_seats where seat_id = current_setting('t.stale_seat')::uuid and trip_id = (select id from t_ref where tag = 'TRIP'));
update public.trip_seats set status = 'available', hold_id = null
  where seat_id = current_setting('t.stale_seat')::uuid and trip_id = (select id from t_ref where tag = 'TRIP');
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  h jsonb; bk jsonb;
begin
  h := public.create_seat_hold(v_trip, array[current_setting('t.stale_seat')::uuid], 300, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  bk := public.create_booking((h ->> 'hold_token')::uuid, 'c2@test.invalid', '9876543210',
    '[{"full_name":"E","age":30,"gender":"female","phone":"9876543214"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  if bk ->> 'booking_id' is null then raise exception 'FAIL 2f: resale after an expired hold was blocked'; end if;
end $$;

-- ---- 3. at most one confirmed item per trip seat ------------------------
reset role;
select set_config('request.jwt.claims', '', true);
do $$
declare
  v_booking uuid := current_setting('t.booking')::uuid;
  v_item public.booking_items;
  v_pax uuid;
begin
  -- pending items for the same seat are allowed (a pending item can outlive its hold)
  update public.booking_items set status = 'confirmed' where booking_id = v_booking;

  select * into v_item from public.booking_items where booking_id = v_booking limit 1;
  select id into v_pax from public.passengers where booking_id = v_booking limit 1;

  insert into public.bookings (booking_reference, customer_id, status)
  values ('THDUP00001', 'dddddddd-0000-0000-0000-00000000000d', 'payment_pending');

  -- a second CONFIRMED item for the same trip seat is rejected
  begin
    insert into public.booking_items (booking_id, trip_id, trip_seat_id, passenger_id, boarding_point_id, dropping_point_id, fare_cents, status)
    values ((select id from public.bookings where booking_reference = 'THDUP00001'),
            v_item.trip_id, v_item.trip_seat_id, v_pax, v_item.boarding_point_id, v_item.dropping_point_id, 100, 'confirmed');
    raise exception 'FAIL 3a: second confirmed item for the same seat accepted';
  exception when unique_violation then null;
  end;

  -- a PENDING item for the same seat is still allowed (resale after a hold expires)
  insert into public.booking_items (booking_id, trip_id, trip_seat_id, passenger_id, boarding_point_id, dropping_point_id, fare_cents, status)
  values ((select id from public.bookings where booking_reference = 'THDUP00001'),
          v_item.trip_id, v_item.trip_seat_id, v_pax, v_item.boarding_point_id, v_item.dropping_point_id, 100, 'payment_pending');

  -- confirming that second item is what the index blocks
  begin
    update public.booking_items set status = 'confirmed'
    where booking_id = (select id from public.bookings where booking_reference = 'THDUP00001');
    raise exception 'FAIL 3b: confirming a duplicate item for an already confirmed seat accepted';
  exception when unique_violation then null;
  end;
end $$;

rollback;
