-- =========================================================================
-- Checks for 20261002001600_operator_trip_list.sql
--   * buckets follow trip status; counts are per bucket
--   * seat counts come from trip_seats: held, sold (booked/boarded), blocked, available
--   * a booking with several seats counts every seat; expired holds count as free
--   * cross-operator isolation
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

do $$
declare
  v_a uuid := (select id from t_ops where tag = 'A');
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  r jsonb; item jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');

  -- 1. fresh trip: all 4 seats available
  r := public.list_operator_trips(v_a, 'upcoming');
  item := r -> 'items' -> 0;
  if (r -> 'counts' ->> 'upcoming')::int <> 1 or (r -> 'counts' ->> 'active')::int <> 0 then
    raise exception 'FAIL 1a: counts %', r -> 'counts';
  end if;
  if (item ->> 'total_seats')::int <> 4 or (item ->> 'available_seats')::int <> 4 or (item ->> 'sold_seats')::int <> 0 then
    raise exception 'FAIL 1b: fresh trip seats %', item;
  end if;
  if item ->> 'source_name' <> 'T Src' or item ->> 'destination_name' <> 'T Dst' or item ->> 'bus_registration' <> 'AN01F0001' then
    raise exception 'FAIL 1c: names %', item;
  end if;
end $$;

-- 2. a customer holds 2 seats in ONE booking (multi-seat): held = 2, not 1
select pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  h jsonb;
begin
  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 2), 300);
  insert into t_ref values ('HOLD', (h ->> 'hold_id')::uuid);
end $$;
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); item jsonb;
begin
  item := public.list_operator_trips(v_a, 'upcoming') -> 'items' -> 0;
  if (item ->> 'held_seats')::int <> 2 or (item ->> 'available_seats')::int <> 2 then
    raise exception 'FAIL 2a: two held seats expected %', item;
  end if;
end $$;

-- 3. the hold expires without the cron having run: counted as available again
select pg_temp.as_server();
update public.seat_holds set expires_at = now() - interval '1 minute';
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); item jsonb;
begin
  item := public.list_operator_trips(v_a, 'upcoming') -> 'items' -> 0;
  if (item ->> 'held_seats')::int <> 0 or (item ->> 'available_seats')::int <> 4 then
    raise exception 'FAIL 3a: expired hold must not count as held %', item;
  end if;
end $$;

-- 4. booked + boarded + blocked seats
select pg_temp.as_server();
update public.trip_seats set status = 'available', hold_id = null;
update public.trip_seats set status = 'booked'  where id = (select id from public.trip_seats order by seat_id limit 1);
update public.trip_seats set status = 'boarded' where id = (select id from public.trip_seats order by seat_id offset 1 limit 1);
update public.trip_seats set status = 'blocked' where id = (select id from public.trip_seats order by seat_id offset 2 limit 1);
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); item jsonb;
begin
  item := public.list_operator_trips(v_a, 'upcoming') -> 'items' -> 0;
  if (item ->> 'sold_seats')::int <> 2 or (item ->> 'blocked_seats')::int <> 1 or (item ->> 'available_seats')::int <> 1 then
    raise exception 'FAIL 4a: sold/blocked/available %', item;
  end if;
end $$;

-- 5. buckets follow status
select pg_temp.as_server();
update public.bus_trips set status = 'departed' where id = (select id from t_ref where tag = 'TRIP');
select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); r jsonb;
begin
  r := public.list_operator_trips(v_a, 'active');
  if jsonb_array_length(r -> 'items') <> 1 or (r -> 'counts' ->> 'upcoming')::int <> 0 or (r -> 'counts' ->> 'active')::int <> 1 then
    raise exception 'FAIL 5a: departed trip is active %', r;
  end if;
  if jsonb_array_length(public.list_operator_trips(v_a, 'upcoming') -> 'items') <> 0 then
    raise exception 'FAIL 5b: departed trip still upcoming';
  end if;
  begin
    perform public.list_operator_trips(v_a, 'bogus');
    raise exception 'FAIL 5c: unknown bucket accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- 6. cross-operator isolation
select pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); v_b uuid := (select id from t_ops where tag = 'B');
begin
  begin
    perform public.list_operator_trips(v_a, 'active');
    raise exception 'FAIL 6a: operator B listed operator A trips';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  if jsonb_array_length(public.list_operator_trips(v_b, 'active') -> 'items') <> 0 then
    raise exception 'FAIL 6b: operator B sees trips';
  end if;
end $$;

select pg_temp.as_server();
rollback;
