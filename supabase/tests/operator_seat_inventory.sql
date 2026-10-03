-- =========================================================================
-- Checks for 20261002001700_realtime_seat_inventory.sql
--   * seat revisions are monotonic; available_seats follows every change
--   * double booking: the second customer cannot take a held/booked seat
--   * hold expiry (effective status immediately, cron frees it), hold renewal rules
--   * a stale payment-failure event cannot free another customer's seat
--   * operator block / release rules, audit and isolation
--   * Broadcast payloads carry seat id/status/rev only; listening policies exist
--   * operator seat map: occupancy from seat inventory, booking reference but no passenger data
-- Real Realtime delivery and true two-session concurrency are verified on a Supabase branch
-- (this harness is single-connection); the row-lock contract is asserted via sequential attempts.
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

create function pg_temp.trip_row() returns public.bus_trips language sql security definer as $f$
  select * from public.bus_trips where id = (select id from t_ref where tag = 'TRIP') $f$;
grant execute on function pg_temp.trip_row() to authenticated;

-- ---- 1. revisions + counter ----------------------------------------------
select pg_temp.as_server();
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  r1 bigint; r2 bigint;
begin
  if (select available_seats from public.bus_trips where id = v_trip) <> 4 then
    raise exception 'FAIL 1a: fresh trip should have 4 available, got %', (select available_seats from public.bus_trips where id = v_trip);
  end if;
  select rev into r1 from public.trip_seats where trip_id = v_trip order by seat_id limit 1;
  update public.trip_seats set status = 'blocked' where id = (select id from public.trip_seats where trip_id = v_trip order by seat_id limit 1);
  select rev into r2 from public.trip_seats where trip_id = v_trip order by seat_id limit 1;
  if r2 <> r1 + 1 then raise exception 'FAIL 1b: rev must increase by one (% -> %)', r1, r2; end if;
  if (select available_seats from public.bus_trips where id = v_trip) <> 3 then
    raise exception 'FAIL 1c: counter must follow the seat change, got %', (select available_seats from public.bus_trips where id = v_trip);
  end if;
  update public.trip_seats set status = 'available' where trip_id = v_trip;
  if (select available_seats from public.bus_trips where id = v_trip) <> 4 then raise exception 'FAIL 1d: counter after release'; end if;
end $$;

-- ---- 2. double booking: C1 holds a seat, C2 cannot take it ---------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid := (pg_temp.t_seats(v_trip, 1))[1];
  h jsonb;
begin
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  h := public.create_seat_hold(v_trip, array[v_seat], 300);
  insert into t_ref values ('H1', (h ->> 'hold_id')::uuid);
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  begin
    perform public.create_seat_hold(v_trip, array[v_seat], 300);
    raise exception 'FAIL 2a: second customer held a seat that is already held';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'seat_unavailable%' then raise exception 'FAIL 2b: wrong error: %', sqlerrm; end if;
  end;
  perform pg_temp.as_server();
  if (select available_seats from public.bus_trips where id = v_trip) <> 3 then
    raise exception 'FAIL 2c: hold must reduce availability';
  end if;
end $$;

-- ---- 3. payment confirms -> seat booked; the other customer still cannot take it
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_order public.orders; r jsonb; v_booked uuid;
begin
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.create_booking((select hold_token from public.seat_holds where id = (select id from t_ref where tag = 'H1')),
    'c@test.invalid', '9876543210',
    '[{"full_name":"Pax One","age":30,"gender":"male","doc_type":"other","doc_number":"DOC1234X","phone":"9876543210"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform pg_temp.as_server();
  select * into v_order from public.orders order by created_at desc limit 1;
  r := public.confirm_booking_after_payment(v_order.order_reference, 'pay_seat_1', v_order.amount_cents);
  if r ->> 'status' <> 'confirmed' then raise exception 'FAIL 3a: payment should confirm, got %', r; end if;
  if not exists (select 1 from public.trip_seats where trip_id = v_trip and status = 'booked') then
    raise exception 'FAIL 3b: seat should be booked';
  end if;
  select seat_id into v_booked from public.trip_seats where trip_id = v_trip and status = 'booked' limit 1;
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  begin
    perform public.create_seat_hold(v_trip, array[v_booked], 300);
    raise exception 'FAIL 3c: booked seat was held again';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'seat_unavailable%' then raise exception 'FAIL 3d: wrong error: %', sqlerrm; end if;
  end;
  perform pg_temp.as_server();
end $$;

-- ---- 4. hold expiry: effective status first, cron frees it ----------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid := (pg_temp.t_seats(v_trip, 1, 1))[1];
  h jsonb; v_map jsonb; v_status text;
begin
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  h := public.create_seat_hold(v_trip, array[v_seat], 300);
  insert into t_ref values ('H2', (h ->> 'hold_id')::uuid);
  perform pg_temp.as_server();
  update public.seat_holds set expires_at = now() - interval '5 seconds' where id = (select id from t_ref where tag = 'H2');

  -- before the cron: the operator map already shows it as available
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  v_map := public.get_operator_trip_seat_map(v_trip);
  select e ->> 'status' into v_status from jsonb_array_elements(v_map -> 'seats') e where (e ->> 'seat_id')::uuid = v_seat;
  if v_status <> 'available' then raise exception 'FAIL 4a: expired hold must read available, got %', v_status; end if;

  perform pg_temp.as_server();
  perform private.expire_stale_seat_holds();
  if exists (select 1 from public.trip_seats where trip_id = v_trip and hold_id = (select id from t_ref where tag = 'H2')) then
    raise exception 'FAIL 4b: cron left the seat attached to the expired hold';
  end if;
  if (select status from public.seat_holds where id = (select id from t_ref where tag = 'H2')) <> 'expired' then
    raise exception 'FAIL 4c: hold must be marked expired';
  end if;
  if (select status from public.trip_seats where trip_id = v_trip and seat_id = v_seat) <> 'available' then
    raise exception 'FAIL 4d: seat must be available again';
  end if;
  -- and it can be taken by someone else
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.create_seat_hold(v_trip, array[v_seat], 300);
  perform pg_temp.as_server();
end $$;

-- ---- 5. hold renewal -------------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid := (pg_temp.t_seats(v_trip, 1, 2))[1];
  h jsonb; r jsonb; v_token uuid; v_before timestamptz; v_rev_before bigint; v_rev_after bigint;
begin
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  h := public.create_seat_hold(v_trip, array[v_seat], 60);
  v_token := (h ->> 'hold_token')::uuid;
  select expires_at into v_before from public.seat_holds where hold_token = v_token;
  select rev into v_rev_before from public.trip_seats where trip_id = v_trip and seat_id = v_seat;

  r := public.renew_seat_hold(v_token, 300);
  if (r ->> 'expires_at')::timestamptz <= v_before then raise exception 'FAIL 5a: renewal must extend the hold'; end if;
  select rev into v_rev_after from public.trip_seats where trip_id = v_trip and seat_id = v_seat;
  if v_rev_after <= v_rev_before then raise exception 'FAIL 5b: renewal must bump the seat rev so clients refresh'; end if;

  begin
    perform public.renew_seat_hold(v_token, 300);
    raise exception 'FAIL 5c: second renewal accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'renewal_not_allowed%' then raise exception 'FAIL 5d: %', sqlerrm; end if;
  end;

  -- another customer cannot renew it
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin
    perform public.renew_seat_hold(v_token, 300);
    raise exception 'FAIL 5e: another customer renewed my hold';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 6. stale payment-failure events cannot free someone else's seat -------
select pg_temp.as_server();
update public.trip_seats set status = 'available', hold_id = null;
update public.seat_holds set status = 'expired';
delete from public.refunds; delete from public.payments; delete from public.orders;
delete from public.booking_items; delete from public.passengers; delete from public.booking_status_history; delete from public.bookings;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid := (pg_temp.t_seats(v_trip, 1))[1];
  v_order1 text; h jsonb; v_taken uuid;
begin
  -- C1 books seat then the hold times out and C2 takes the seat
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'ORD1', 1);
  select order_reference into v_order1 from public.orders where id = (select id from t_ref where tag = 'ORD1');
  perform pg_temp.as_server();
  update public.seat_holds set expires_at = now() - interval '1 minute' where status = 'active';
  perform private.expire_stale_seat_holds();
  select ts.seat_id into v_taken from public.trip_seats ts where ts.id = (select trip_seat_id from public.booking_items limit 1);
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  h := public.create_seat_hold(v_trip, array[v_taken], 300);
  perform pg_temp.as_server();
  -- the late failure event for C1's order arrives
  perform public.handle_payment_failure(v_order1);
  if (select status from public.trip_seats where id = (select trip_seat_id from public.booking_items limit 1)) <> 'held' then
    raise exception 'FAIL 6a: stale failure freed a seat held by another customer';
  end if;
  -- repeating the event is harmless
  perform public.handle_payment_failure(v_order1);
end $$;

-- a failure event for an already paid order is ignored
select pg_temp.as_server();
update public.trip_seats set status = 'available', hold_id = null;
update public.seat_holds set status = 'expired';
delete from public.refunds; delete from public.payments; delete from public.orders;
delete from public.booking_items; delete from public.passengers; delete from public.booking_status_history; delete from public.bookings;
do $$
declare v_order public.orders;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'ORD2', 1);
  perform pg_temp.as_server();
  select * into v_order from public.orders where id = (select id from t_ref where tag = 'ORD2');
  perform public.confirm_booking_after_payment(v_order.order_reference, 'pay_ok', v_order.amount_cents);
  perform public.handle_payment_failure(v_order.order_reference);
  if (select status from public.bookings where id = v_order.orderable_id) <> 'confirmed' then
    raise exception 'FAIL 6b: failure event undid a paid booking';
  end if;
  if not exists (select 1 from public.trip_seats where status = 'booked') then
    raise exception 'FAIL 6c: failure event freed a paid seat';
  end if;
end $$;

-- ---- 7. operator block / release -------------------------------------------
select pg_temp.as_server();
update public.trip_seats set status = 'available', hold_id = null;
update public.seat_holds set status = 'expired';
delete from public.refunds; delete from public.payments; delete from public.orders;
delete from public.booking_items; delete from public.passengers; delete from public.booking_status_history; delete from public.bookings;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_a uuid := (select id from t_ops where tag = 'A');
  v_seats uuid[] := pg_temp.t_seats(v_trip, 2);
  r jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin
    perform public.operator_block_seats(v_trip, v_seats, '');
    raise exception 'FAIL 7a: blocked without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  r := public.operator_block_seats(v_trip, v_seats, 'Reserved for crew');
  if (select count(*) from public.bus_trips b join public.trip_seats s on s.trip_id = b.id where b.id = v_trip and s.status = 'blocked') <> 2 then
    raise exception 'FAIL 7b: two seats should be blocked';
  end if;
  if (select available_seats from public.bus_trips where id = v_trip) <> 2 then raise exception 'FAIL 7c: counter after block'; end if;

  -- customers cannot hold blocked seats
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin
    perform public.create_seat_hold(v_trip, v_seats, 300);
    raise exception 'FAIL 7d: customer held a blocked seat';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- other operators and customers cannot block/release
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin
    perform public.operator_release_seats(v_trip, v_seats);
    raise exception 'FAIL 7e: other operator released seats';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin
    perform public.operator_block_seats(v_trip, pg_temp.t_seats(v_trip, 1, 3), 'x');
    raise exception 'FAIL 7f: customer blocked a seat';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- only available seats can be blocked; only blocked seats can be released
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin
    perform public.operator_block_seats(v_trip, v_seats, 'again');
    raise exception 'FAIL 7g: blocked an already blocked seat';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.operator_release_seats(v_trip, pg_temp.t_seats(v_trip, 1, 3));
    raise exception 'FAIL 7h: released a seat that was not blocked';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform public.operator_release_seats(v_trip, v_seats);
  if (select available_seats from public.bus_trips where id = v_trip) <> 4 then raise exception 'FAIL 7i: counter after release'; end if;

  -- audited
  perform pg_temp.as_server();
  if (select count(*) from public.audit_logs where entity_type = 'bus_trip' and action in ('trip_seat.block', 'trip_seat.release')) <> 2 then
    raise exception 'FAIL 7j: block/release must be audited';
  end if;

  -- no blocking after departure
  update public.bus_trips set status = 'departed' where id = v_trip;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin
    perform public.operator_block_seats(v_trip, pg_temp.t_seats(v_trip, 1), 'late');
    raise exception 'FAIL 7k: blocked a seat after departure';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  update public.bus_trips set status = 'scheduled' where id = v_trip;
end $$;

-- ---- 8. operator seat map: occupancy from inventory; multi-seat booking; no passenger data
select pg_temp.as_server();
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seats uuid[] := pg_temp.t_seats(v_trip, 2);
  h jsonb; m jsonb; v_ref text;
begin
  -- one booking with TWO seats, confirmed
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  h := public.create_seat_hold(v_trip, v_seats, 300, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"Secret Name","age":30,"gender":"male","doc_type":"other","doc_number":"DOC1234X","phone":"9111111111"},{"full_name":"Other Secret","age":28,"gender":"female","doc_type":"other","doc_number":"DOC1234X","phone":"9222222222"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform pg_temp.as_server();
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_two', o.amount_cents) from public.orders o order by o.created_at desc limit 1;
  select booking_reference into v_ref from public.bookings order by created_at desc limit 1;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  m := public.get_operator_trip_seat_map(v_trip);
  if (m -> 'counts' ->> 'booked')::int <> 2 or (m -> 'counts' ->> 'available')::int <> 2 or (m -> 'counts' ->> 'total')::int <> 4 then
    raise exception 'FAIL 8a: counts %', m -> 'counts';
  end if;
  if (m -> 'counts' ->> 'occupancy_pct')::numeric <> 50.0 then raise exception 'FAIL 8b: occupancy %', m -> 'counts' ->> 'occupancy_pct'; end if;
  if (select count(*) from jsonb_array_elements(m -> 'seats') e where e ->> 'booking_reference' = v_ref and e ->> 'booking_status' = 'confirmed') <> 2 then
    raise exception 'FAIL 8c: both seats must show the booking reference';
  end if;
  if m::text like '%Secret%' or m::text like '%9111111111%' or m::text like '%9222222222%' then
    raise exception 'FAIL 8d: seat map leaked passenger data';
  end if;
  if m -> 'layout' ->> 'rows' is null or jsonb_array_length(m -> 'seats') <> 4 then
    raise exception 'FAIL 8e: layout/seats missing';
  end if;

  -- isolation
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin
    perform public.get_operator_trip_seat_map(v_trip);
    raise exception 'FAIL 8f: operator B read operator A seat map';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin
    perform public.get_operator_trip_seat_map(v_trip);
    raise exception 'FAIL 8g: customer read operator seat map';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  m := public.get_operator_trip_seat_map(v_trip);
  perform pg_temp.as_server();
end $$;

-- ---- 9. Broadcast: payloads carry seat id/status/rev only -------------------
select pg_temp.as_server();
delete from realtime.sent_log;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid := (pg_temp.t_seats(v_trip, 1, 3))[1];
  s record; found_seat boolean := false; h jsonb;
begin
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  h := public.create_seat_hold(v_trip, array[v_seat], 300, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"Pax","age":30,"gender":"male","doc_type":"other","doc_number":"DOC1234X","phone":"9333333333"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform pg_temp.as_server();

  for s in select * from realtime.sent_log where topic = 'trip:' || v_trip || ':seats' loop
    if s.private is not true then raise exception 'FAIL 9a: seat broadcast must use a private channel'; end if;
    if s.payload::text ~* '(hold|user|customer|booking|phone|name|email)' then
      raise exception 'FAIL 9b: seat broadcast leaks data: %', s.payload;
    end if;
    if exists (select 1 from jsonb_array_elements(s.payload -> 'seats') e
               where (e ->> 'seat_id')::uuid = v_seat and e ->> 'status' = 'held' and (e ->> 'rev')::bigint > 0) then
      found_seat := true;
    end if;
  end loop;
  if not found_seat then raise exception 'FAIL 9c: hold did not broadcast the held seat'; end if;

  -- ops channel pings on payment/booking changes, without amounts
  if not exists (select 1 from realtime.sent_log where topic = 'trip:' || v_trip || ':ops') then
    raise exception 'FAIL 9d: no ops ping was sent for booking changes';
  end if;
  if exists (select 1 from realtime.sent_log where topic like '%:ops' and payload::text ~* '(amount|cents|name|phone)') then
    raise exception 'FAIL 9e: ops ping leaks data';
  end if;
end $$;

-- ---- 10. listening policies ------------------------------------------------
do $$
begin
  if (select count(*) from pg_policies where schemaname = 'realtime' and tablename = 'messages'
        and policyname in ('trip_seats_broadcast_listen', 'trip_ops_broadcast_listen')) <> 2 then
    raise exception 'FAIL 10a: realtime.messages policies missing';
  end if;
  -- the seat topic policy admits only seat topics, the ops policy is operator/admin scoped
  if (select qual from pg_policies where policyname = 'trip_seats_broadcast_listen') not like '%:seats%' then
    raise exception 'FAIL 10b: seat policy not scoped to seat topics';
  end if;
  if (select qual from pg_policies where policyname = 'trip_ops_broadcast_listen') not like '%is_operator_staff%' then
    raise exception 'FAIL 10c: ops policy not scoped to trip operator';
  end if;
end $$;

select pg_temp.as_server();
rollback;
