-- =========================================================================
-- Checks for 20261002002000_trip_booking_analytics.sql
--   * stats come from the seat inventory: multi-seat bookings, pending vs confirmed, cancelled
--   * trend is cumulative over real timestamps; cancellations subtract
--   * staff of the trip's operator only
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

-- C1: ONE booking with TWO seats (confirmed); C2: one seat (confirmed, then cancelled);
-- C1 also holds the last seat without paying (pending)
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  h jsonb; o public.orders; v_cancel uuid;
begin
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 2), 300, (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"A","age":30,"gender":"male","doc_type":"other","doc_number":"DOC1234X","phone":"9111111111"},{"full_name":"B","age":28,"gender":"female","doc_type":"other","doc_number":"DOC1234X","phone":"9111111111"}]'::jsonb,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  perform pg_temp.as_server();
  select * into o from public.orders order by created_at desc limit 1;
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_two', o.amount_cents);

  perform pg_temp.book('eeeeeeee-0000-0000-0000-00000000000e', 'O2', 3);
  perform pg_temp.as_server();
  perform pg_temp.pay('O2');
  select b.id into v_cancel from public.bookings b where b.customer_id = 'eeeeeeee-0000-0000-0000-00000000000e';
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  perform public.cancel_booking(v_cancel, 'changed plans');

  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O3', 4);   -- held, never paid
  perform pg_temp.as_server();

  -- give the status history distinct, ordered timestamps (inside one transaction now() is constant)
  update public.booking_status_history set created_at = now() - interval '3 days'
    where to_status = 'confirmed' and booking_id = (select b.id from public.bookings b where b.customer_id = 'dddddddd-0000-0000-0000-00000000000d' and b.status = 'confirmed');
  update public.booking_status_history set created_at = now() - interval '2 days'
    where to_status = 'confirmed' and booking_id = v_cancel;
  update public.booking_status_history set created_at = now() - interval '1 day'
    where to_status = 'cancelled' and booking_id = v_cancel;
end $$;

-- ---- 1. stats ----------------------------------------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); s jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  s := public.get_trip_booking_stats(v_trip);
  if (s ->> 'capacity')::int <> 4 then raise exception 'FAIL 1a: capacity %', s; end if;
  if (s ->> 'confirmed_seats')::int <> 2 then raise exception 'FAIL 1b: a 2-seat booking is 2 confirmed seats, got %', s ->> 'confirmed_seats'; end if;
  if (s ->> 'pending_reservations')::int <> 1 then raise exception 'FAIL 1c: pending %', s ->> 'pending_reservations'; end if;
  if (s ->> 'available_seats')::int <> 1 then raise exception 'FAIL 1d: the cancelled seat is available again, got %', s ->> 'available_seats'; end if;
  if (s ->> 'cancelled_bookings')::int <> 1 or (s ->> 'cancelled_seats')::int <> 1 then raise exception 'FAIL 1e: cancelled %', s; end if;
  if (s ->> 'occupancy_pct')::numeric <> 50.0 then raise exception 'FAIL 1f: occupancy %', s ->> 'occupancy_pct'; end if;
  if (select sum((e ->> 'seats')::int) from jsonb_array_elements(s -> 'distribution') e where e ->> 'status' in ('confirmed', 'pending', 'blocked', 'available')) <> 4 then
    raise exception 'FAIL 1g: live distribution must add up to capacity';
  end if;
  -- operator staff may see operational stats
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  perform public.get_trip_booking_stats(v_trip);
  perform pg_temp.as_server();
end $$;

-- ---- 2. pending expires -> available, still not confirmed ---------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); s jsonb;
begin
  update public.seat_holds set expires_at = now() - interval '1 minute' where status = 'active';
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  s := public.get_trip_booking_stats(v_trip);
  if (s ->> 'pending_reservations')::int <> 0 or (s ->> 'available_seats')::int <> 2 or (s ->> 'confirmed_seats')::int <> 2 then
    raise exception 'FAIL 2a: expired hold must read as available %', s;
  end if;
  perform pg_temp.as_server();
end $$;

-- ---- 3. trend --------------------------------------------------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); t jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  t := public.get_trip_booking_trend(v_trip);
  if jsonb_array_length(t -> 'points') <> 3 then raise exception 'FAIL 3a: expected 3 events, got %', t -> 'points'; end if;
  if (t -> 'points' -> 0 ->> 'delta')::int <> 2 or (t -> 'points' -> 0 ->> 'cumulative_seats')::int <> 2 then raise exception 'FAIL 3b: 2-seat booking first %', t -> 'points' -> 0; end if;
  if (t -> 'points' -> 1 ->> 'cumulative_seats')::int <> 3 then raise exception 'FAIL 3c: %', t -> 'points' -> 1; end if;
  if (t -> 'points' -> 2 ->> 'delta')::int <> -1 or (t -> 'points' -> 2 ->> 'cumulative_seats')::int <> 2 then raise exception 'FAIL 3d: cancellation subtracts %', t -> 'points' -> 2; end if;
  if (t ->> 'capacity')::int <> 4 or t ->> 'departure_at' is null then raise exception 'FAIL 3e'; end if;
  if (t -> 'points' -> 0 ->> 'days_before_departure')::numeric < 4.9 then raise exception 'FAIL 3f: days before departure % (trip is 2 days out, booking 3 days ago)', t -> 'points' -> 0 ->> 'days_before_departure'; end if;
  -- the last cumulative value agrees with the seat inventory
  if (t -> 'points' -> 2 ->> 'cumulative_seats')::int <> (public.get_trip_booking_stats(v_trip) ->> 'confirmed_seats')::int then
    raise exception 'FAIL 3g: trend and stats disagree';
  end if;
  perform pg_temp.as_server();
end $$;

-- ---- 4. isolation ------------------------------------------------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP');
begin
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_trip_booking_stats(v_trip); raise exception 'FAIL 4a: operator B read stats';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.get_trip_booking_trend(v_trip); raise exception 'FAIL 4b: operator B read the trend';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.get_trip_booking_stats(v_trip); raise exception 'FAIL 4c: customer read stats';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

rollback;
