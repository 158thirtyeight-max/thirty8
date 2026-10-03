-- =========================================================================
-- Shared fixture for operator_*.sql tests (inlined by the harness via
-- "-- @include fixtures/trip_fixture.sql"). Must run inside the test's transaction.
--
--   users:   A operator admin (aaaa..0a)   B other operator (bbbb..0b)
--            C1 customer (dddd..0d)        C2 customer (eeee..0e)    ADM platform admin (ffff..0f)
--   t_ops:   'A', 'B' approved operators
--   t_ref:   SRC/MID/DST locations; BUS (4 seats: 1A 1B 2A 2B, fare 500.00); TRIP (current_date+2, 06:00-10:00)
--            B_ORIGIN, B_MID, D_MID, D_DEST points; ROUTE
--   helpers: pg_temp.as_user(uuid) (switch identity + authenticated role), pg_temp.as_server(),
--            pg_temp.t_seats(trip, n, skip, only_available), pg_temp.book(user, tag, seat_no)
-- Leaves the session as the table owner with no JWT claims.
-- =========================================================================
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('dddddddd-0000-0000-0000-00000000000d', 'cust@test.invalid'),
  ('eeeeeeee-0000-0000-0000-00000000000e', 'cust2@test.invalid'),
  ('ffffffff-0000-0000-0000-00000000000f', 'admin@test.invalid');
insert into public.user_roles (user_id, role) values ('ffffffff-0000-0000-0000-00000000000f', 'platform_admin');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;
create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;

create function pg_temp.as_user(p_user uuid) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $f$;
create function pg_temp.as_server() returns void language plpgsql as $f$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $f$;
grant execute on function pg_temp.as_user(uuid), pg_temp.as_server() to authenticated, anon;

-- Seat ids of a trip (definer: customers cannot read trip_seats directly)
create function pg_temp.t_seats(p_trip uuid, p_n int, p_skip int default 0, p_avail boolean default false) returns uuid[]
language sql security definer as $f$
  select array_agg(seat_id) from (
    select seat_id from public.trip_seats
    where trip_id = p_trip and (not p_avail or status = 'available')
    order by seat_id offset p_skip limit p_n) x
$f$;
grant execute on function pg_temp.t_seats(uuid, int, int, boolean) to authenticated, anon;

insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Src') returning id)
  insert into t_ref select 'SRC', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Mid') returning id)
  insert into t_ref select 'MID', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Dst') returning id)
  insert into t_ref select 'DST', id from c;

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;
select pg_temp.as_server();
update public.operators set status = 'approved', application_status = 'approved';

select pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
insert into t_ref select 'BUS', (public.create_bus((select id from t_ops where tag = 'A'), 'Fixture Bus', 'AN01F0001', 'ac_seater', 4)).id;

do $$
declare
  v_bus uuid := (select id from t_ref where tag = 'BUS');
  r jsonb;
begin
  r := public.save_bus_layout(v_bus, '{"rows":2,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"},
    {"seat_code":"2B","deck":1,"row_no":2,"col_no":3,"seat_type":"seater"}
  ]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL fixture layout: %', r -> 'errors'; end if;

  r := public.save_bus_route(v_bus, (select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'),
    100, '06:00', 240, '{1,2,3,4,5,6,7}', jsonb_build_array(
      jsonb_build_object('name','Origin','city_id',(select id from t_ref where tag = 'SRC'),'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Middle','city_id',(select id from t_ref where tag = 'MID'),'is_boarding',true,'is_dropping',true,'arrival_offset_min',120,'departure_offset_min',125),
      jsonb_build_object('name','Dest','city_id',(select id from t_ref where tag = 'DST'),'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL fixture route: %', r -> 'errors'; end if;
  r := public.save_bus_fares(v_bus, jsonb_build_array(jsonb_build_object('seat_type','seater','base_fare_cents',50000)), '[]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL fixture fares: %', r -> 'errors'; end if;
end $$;

select pg_temp.as_server();
insert into t_ref select 'ROUTE', route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS');
insert into t_ref select 'B_ORIGIN', id from public.boarding_points where city_id = (select id from t_ref where tag = 'SRC') and route_id = (select id from t_ref where tag = 'ROUTE');
insert into t_ref select 'B_MID',    id from public.boarding_points where city_id = (select id from t_ref where tag = 'MID') and route_id = (select id from t_ref where tag = 'ROUTE');
insert into t_ref select 'D_MID',    id from public.dropping_points where city_id = (select id from t_ref where tag = 'MID') and route_id = (select id from t_ref where tag = 'ROUTE');
insert into t_ref select 'D_DEST',   id from public.dropping_points where city_id = (select id from t_ref where tag = 'DST') and route_id = (select id from t_ref where tag = 'ROUTE');

update public.buses set lifecycle_status = 'active' where id = (select id from t_ref where tag = 'BUS');
update public.bus_services set status = 'active' where bus_id = (select id from t_ref where tag = 'BUS');
with s as (select id, operator_id, route_id, bus_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS')),
     t as (
       insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at, booking_open_at)
       select id, operator_id, route_id, bus_id, current_date + 2, (current_date + 2) + time '06:00', (current_date + 2) + time '10:00', now() - interval '1 day' from s
       returning id)
insert into t_ref select 'TRIP', id from t;

-- hold + book one seat (by seat position) as p_user; stores the order id under p_tag
-- (the booking stays payment_pending until confirmed through confirm_booking_after_payment)
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
         jsonb_build_array(jsonb_build_object('full_name','Pax ' || p_seat_no,'age',30,'gender','male','phone','9876543210','doc_type','other','doc_number','DOC' || p_seat_no || 'X')),
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  delete from t_ref where tag = p_tag;
  insert into t_ref values (p_tag, (bk ->> 'order_id')::uuid);
end $f$;
grant execute on function pg_temp.book(uuid, text, int) to authenticated;
