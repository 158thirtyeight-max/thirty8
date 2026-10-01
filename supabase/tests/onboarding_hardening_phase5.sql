-- =========================================================================
-- Hardening phase 5 checks for 20261002000600_public_read_lockdown.sql
-- Anonymous / customer / operator / admin read access to the booking inventory tables;
-- get_trip_points. Setup shared with onboarding_phase9.sql. Rolled back.
-- =========================================================================
-- Phase 9 checks for 20260926000800_fare_engine.sql
-- The fare engine must give the SAME price in search, seat map, hold quote and
-- booking. Run after pushing migrations (see onboarding_phase2.sql header).
-- Everything is rolled back.
-- =========================================================================
begin;

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
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('eeeeeeee-0000-0000-0000-00000000000e', 'cust2@test.invalid'),
  ('ffffffff-0000-0000-0000-00000000000f', 'admin@test.invalid');
insert into public.user_roles (user_id, role) values ('ffffffff-0000-0000-0000-00000000000f', 'platform_admin');

select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;
reset role;
select set_config('request.jwt.claims', '', true);

-- counts rows of the guarded tables as the current role (never errors for a missing privilege on a helper)
create function pg_temp.cnt(p_table text) returns bigint language plpgsql as $f$
declare n bigint;
begin
  execute format('select count(*) from public.%I', p_table) into n;
  return n;
end $f$;
grant execute on function pg_temp.cnt(text) to anon, authenticated;
grant select on t_ref to anon;

-- ---- 1. anonymous users see none of it, and nothing errors ----------------
set local role anon;
do $$
declare t text;
begin
  foreach t in array array['operators','buses','bus_layouts','seats','bus_routes','bus_services','bus_trips',
                           'boarding_points','dropping_points','fare_rules','fare_charges','trip_seats','cargo_vehicles'] loop
    if pg_temp.cnt(t) <> 0 then raise exception 'FAIL 1a: anon can read % (% rows)', t, pg_temp.cnt(t); end if;
  end loop;
end $$;
reset role;

-- ---- 2. a signed-in customer without bookings sees none of it -------------
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}', true);
set local role authenticated;
do $$
declare t text;
begin
  foreach t in array array['operators','buses','bus_layouts','seats','bus_routes','bus_services','bus_trips',
                           'boarding_points','dropping_points','fare_rules','fare_charges','trip_seats'] loop
    if pg_temp.cnt(t) <> 0 then raise exception 'FAIL 2a: customer without bookings can read % (% rows)', t, pg_temp.cnt(t); end if;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---- 3. the supported customer paths still work (RPCs) --------------------
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  res jsonb; pts jsonb; h jsonb; bk jsonb;
begin
  res := public.search_trips(v_src, v_dst, current_date + 2);
  if not exists (select 1 from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip) then
    raise exception 'FAIL 3a: search stopped working for customers';
  end if;
  if jsonb_array_length(public.get_trip_seat_map(v_trip) -> 'seats') <> 3 then raise exception 'FAIL 3b: seat map stopped working'; end if;

  pts := public.get_trip_points(v_trip);
  if pts is null or jsonb_array_length(pts -> 'boarding') <> 2 or jsonb_array_length(pts -> 'dropping') <> 2 then
    raise exception 'FAIL 3c: get_trip_points returned %', pts;
  end if;
  if not exists (select 1 from jsonb_array_elements(pts -> 'boarding') p where (p ->> 'id')::uuid = (select id from t_ref where tag = 'B_ORIGIN')) then
    raise exception 'FAIL 3d: boarding points missing the origin stop: %', pts -> 'boarding';
  end if;
  if (pts -> 'boarding' -> 0 ->> 'sequence_no')::int > (pts -> 'boarding' -> 1 ->> 'sequence_no')::int then
    raise exception 'FAIL 3e: boarding points not ordered';
  end if;

  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, 1), 300,
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  bk := public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
         '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"}]'::jsonb,
         (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  if bk ->> 'booking_id' is null then raise exception 'FAIL 3f: booking stopped working'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- anonymous callers can use the public RPCs too
set local role anon;
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); pts jsonb;
begin
  if public.get_trip_points(v_trip) is null then raise exception 'FAIL 3g: anon cannot get trip points'; end if;
  if jsonb_array_length(public.search_trips((select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'), current_date + 2) -> 'direct') <> 1 then
    raise exception 'FAIL 3h: anon search broken';
  end if;
end $$;
reset role;

-- ---- 4. the customer keeps read access to their OWN booking's trip and stops
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  n int; r record;
begin
  select bi.id, bp.id as bid, dp.id as did, t.status, t.departure_at into r
  from public.booking_items bi
  join public.boarding_points bp on bp.id = bi.boarding_point_id
  join public.dropping_points dp on dp.id = bi.dropping_point_id
  join public.bus_trips t on t.id = bi.trip_id
  limit 1;
  if r.id is null then raise exception 'FAIL 4a: customer cannot read the trip and stops of their own booking'; end if;
  if r.bid <> (select id from t_ref where tag = 'B_ORIGIN') or r.did <> (select id from t_ref where tag = 'D_MID') then raise exception 'FAIL 4b: wrong stops'; end if;
  -- only their own trip and the stops they booked, nothing else
  if pg_temp.cnt('bus_trips') <> 1 then raise exception 'FAIL 4c: customer sees % trips', pg_temp.cnt('bus_trips'); end if;
  if pg_temp.cnt('boarding_points') <> 1 or pg_temp.cnt('dropping_points') <> 1 then raise exception 'FAIL 4d: customer sees more stops than they booked'; end if;
  if pg_temp.cnt('bus_services') <> 0 or pg_temp.cnt('fare_rules') <> 0 or pg_temp.cnt('trip_seats') <> 0 or pg_temp.cnt('operators') <> 0 or pg_temp.cnt('buses') <> 0 then
    raise exception 'FAIL 4e: customer sees internal tables';
  end if;
end $$;
reset role;
-- ... even after the trip has left
update public.bus_trips set status = 'arrived', departure_at = now() - interval '2 days';
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if pg_temp.cnt('bus_trips') <> 1 then raise exception 'FAIL 4f: customer lost sight of a past trip'; end if;
end $$;
reset role;
update public.bus_trips set status = 'scheduled', departure_at = (current_date + 2) + time '06:00';
-- another customer still sees nothing
select set_config('request.jwt.claims', '{"sub":"eeeeeeee-0000-0000-0000-00000000000e","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if pg_temp.cnt('bus_trips') <> 0 or pg_temp.cnt('boarding_points') <> 0 then raise exception 'FAIL 4g: another customer sees someone else''s trip'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---- 5. operators see their own data only ---------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare t text;
begin
  foreach t in array array['operators','buses','bus_layouts','seats','bus_routes','bus_services','bus_trips',
                           'boarding_points','dropping_points','fare_rules','fare_charges','trip_seats'] loop
    if t <> 'fare_charges' and pg_temp.cnt(t) < 1 then raise exception 'FAIL 5a: operator A cannot read its own %', t; end if;
  end loop;
  if pg_temp.cnt('operators') <> 1 then raise exception 'FAIL 5b: operator A sees % operator rows', pg_temp.cnt('operators'); end if;
end $$;
reset role;

select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare t text;
begin
  foreach t in array array['buses','bus_layouts','seats','bus_routes','bus_services','bus_trips',
                           'boarding_points','dropping_points','fare_rules','fare_charges','trip_seats'] loop
    if pg_temp.cnt(t) <> 0 then raise exception 'FAIL 5c: operator B can read operator A''s %', t; end if;
  end loop;
  if pg_temp.cnt('operators') <> 1 then raise exception 'FAIL 5d: operator B sees % operator rows', pg_temp.cnt('operators'); end if;
end $$;
reset role;

-- ---- 6. admin still sees everything ---------------------------------------
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-00000000000f","role":"authenticated"}', true);
set local role authenticated;
do $$
declare t text;
begin
  foreach t in array array['operators','buses','bus_layouts','seats','bus_routes','bus_services','bus_trips',
                           'boarding_points','dropping_points','fare_rules','trip_seats'] loop
    if pg_temp.cnt(t) < 1 then raise exception 'FAIL 6a: admin cannot read %', t; end if;
  end loop;
  if pg_temp.cnt('operators') < 2 then raise exception 'FAIL 6b: admin does not see both operators'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---- 7. get_trip_points only serves open, bookable trips ------------------
update public.bus_trips set status = 'cancelled';
set local role anon;
do $$ begin
  if public.get_trip_points((select id from t_ref where tag = 'TRIP')) is not null then raise exception 'FAIL 7a: points served for a cancelled trip'; end if;
end $$;
reset role;
update public.bus_trips set status = 'scheduled';
update public.buses set lifecycle_status = 'suspended' where id = (select id from t_ref where tag = 'BUS');
set local role anon;
do $$ begin
  if public.get_trip_points((select id from t_ref where tag = 'TRIP')) is not null then raise exception 'FAIL 7b: points served for a suspended bus'; end if;
end $$;
reset role;

rollback;
