\set ON_ERROR_STOP on
\set QUIET on
-- Run after all migrations, e.g.: psql -d <db> -f supabase/tests/service_stops_test.sql
create or replace function pg_temp.ok(p_name text, p_cond boolean) returns void language plpgsql as $$
begin if p_cond is not true then raise exception 'FAIL: %', p_name; end if; raise notice 'PASS: %', p_name; end $$;
-- true when running p_sql raises an error containing p_msg
create or replace function pg_temp.fails(p_name text, p_sql text, p_msg text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm like '%' || p_msg || '%' then raise notice 'PASS: %', p_name; return; end if;
    raise exception 'FAIL: % (wrong error: %)', p_name, sqlerrm;
  end;
  raise exception 'FAIL: % (no error)', p_name;
end $$;

-- fixture: overnight service 20:00 -> 06:00 (+1 day), 600 min
do $$
declare v_op uuid; v_bus uuid; v_route uuid; v_src uuid; v_dst uuid; v_svc uuid; v_trip uuid; v_c record; i int := 0;
begin
  select id into v_op from operators where name = 'Andaman Express (Demo)';
  select id into v_src from cities where name ilike '%Sri Vijaya Puram%';
  select id into v_dst from cities where name ilike '%Diglipur%';
  insert into buses(operator_id,registration_number,bus_type,total_seats) values (v_op,'AN01-STOP-0001','ac_seater',4) returning id into v_bus;
  insert into bus_routes(operator_id,source_city_id,destination_city_id) values (v_op,v_dst,v_src) returning id into v_route;
  insert into bus_services(operator_id,route_id,bus_id,service_name,service_source_city_id,service_dest_city_id,default_departure_time,default_arrival_offset_minutes,operating_days,auto_generate)
    values (v_op,v_route,v_bus,'Stops test',v_dst,v_src,'20:00',600,'{1,2,3,4,5,6,7}',false) returning id into v_svc;
  insert into bus_trips(service_id,operator_id,route_id,bus_id,travel_date,departure_at,arrival_at)
    values (v_svc,v_op,v_route,v_bus,date '2030-01-10', timestamptz '2030-01-10 20:00+05:30', timestamptz '2030-01-11 06:00+05:30') returning id into v_trip;
  perform set_config('t8.svc', v_svc::text, false);
  perform set_config('t8.trip', v_trip::text, false);
  for v_c in select id from cities where id not in (v_src, v_dst) and is_active order by name limit 3 loop
    i := i + 1; perform set_config('t8.c' || i, v_c.id::text, false);
  end loop;
end $$;

grant usage on schema private to authenticated; grant usage on schema auth to authenticated;
grant usage on schema public to anon, authenticated; grant all on all tables in schema public to anon, authenticated;
select user_id as opuser from user_roles where role='operator_admin' limit 1 \gset

-- unauthenticated / unrelated users cannot save stops
set role authenticated;
select set_config('request.jwt.claim.sub', gen_random_uuid()::text, false);
select pg_temp.fails('other user cannot save stops', format($q$select public.save_service_stops(%L, '[]')$q$, current_setting('t8.svc')), 'Not authorized');
reset role;

select set_config('request.jwt.claim.sub', :'opuser', false);
set role authenticated;

-- 1. regular pickup/drop stop, no purpose; default duration 2 min
select public.save_service_stops(current_setting('t8.svc')::uuid, jsonb_build_array(jsonb_build_object(
  'location_city_id', current_setting('t8.c1'), 'arrival_offset_minutes', 120))) as n \gset
select pg_temp.ok('T1 regular stop saved, defaults pickup+drop', (select count(*)=1 and bool_and(allows_pickup and allows_drop and stop_purposes='{}' and facilities='{}') from bus_service_stops where service_id=current_setting('t8.svc')::uuid));
select pg_temp.ok('T1 departure = arrival + duration (2 min)', (select departure_offset_minutes = arrival_offset_minutes + 2 from bus_service_stops where service_id=current_setting('t8.svc')::uuid));

-- 2. lunch stop, 30 min, + 3. tea & toilet with several selections, + 4. ferry transfer
select public.save_service_stops(current_setting('t8.svc')::uuid, jsonb_build_array(
  jsonb_build_object('location_city_id', current_setting('t8.c1'), 'arrival_offset_minutes', 120, 'stop_duration_minutes', 30,
    'stop_purposes', jsonb_build_array('meal_break'), 'meal_types', jsonb_build_array('dinner'), 'facilities', jsonb_build_array('restaurant_food','toilet')),
  jsonb_build_object('location_city_id', current_setting('t8.c2'), 'arrival_offset_minutes', 300, 'stop_duration_minutes', 10,
    'stop_purposes', jsonb_build_array('tea_refreshment','toilet_break'), 'refreshment_types', jsonb_build_array('tea','snacks'), 'facilities', jsonb_build_array('toilet','drinking_water')),
  jsonb_build_object('location_city_id', current_setting('t8.c3'), 'arrival_offset_minutes', 420, 'stop_duration_minutes', 15,
    'allows_pickup', false, 'stop_purposes', jsonb_build_array('ferry_transfer')))) as n \gset
select pg_temp.ok('T2 lunch stop 30 min: departs 150', (select departure_offset_minutes=150 and stop_duration_minutes=30 and meal_types='{dinner}' from bus_service_stops where service_id=current_setting('t8.svc')::uuid and sequence_no=1));
select pg_temp.ok('T3 tea+toilet multi-select stored', (select stop_purposes='{tea_refreshment,toilet_break}' and refreshment_types='{tea,snacks}' and facilities='{toilet,drinking_water}' from bus_service_stops where service_id=current_setting('t8.svc')::uuid and sequence_no=2));
select pg_temp.ok('T4 ferry transfer, drop only', (select stop_purposes='{ferry_transfer}' and not allows_pickup and allows_drop from bus_service_stops where service_id=current_setting('t8.svc')::uuid and sequence_no=3));

-- 6. removing a purpose (+ its sub-options) while editing stop 2; 5/7 edit then reopen
select public.save_service_stops(current_setting('t8.svc')::uuid, jsonb_build_array(
  jsonb_build_object('location_city_id', current_setting('t8.c1'), 'arrival_offset_minutes', 120, 'stop_duration_minutes', 30,
    'stop_purposes', jsonb_build_array('meal_break'), 'meal_types', jsonb_build_array('dinner'), 'facilities', jsonb_build_array('restaurant_food','toilet')),
  jsonb_build_object('location_city_id', current_setting('t8.c2'), 'arrival_offset_minutes', 300, 'stop_duration_minutes', 10,
    'stop_purposes', jsonb_build_array('toilet_break'), 'facilities', jsonb_build_array('toilet')))) as n \gset
select pg_temp.ok('T6 removed purpose and sub-options gone; stop 3 removed', (select count(*)=2 and bool_or(stop_purposes='{toilet_break}' and refreshment_types='{}') from bus_service_stops where service_id=current_setting('t8.svc')::uuid));
select pg_temp.ok('T7 reopen returns what was saved (order + values)', (select array_agg(sequence_no order by sequence_no)='{1,2}' and bool_or(sequence_no=1 and meal_types='{dinner}') from bus_service_stops where service_id=current_setting('t8.svc')::uuid));

-- 8. subsequent stops recalc: moving stop 1's duration to 45 pushes its departure; stop 2 must still arrive after it
select pg_temp.fails('T8 next stop cannot arrive before previous departs', format($q$select public.save_service_stops(%L, %L::jsonb)$q$, current_setting('t8.svc'),
  jsonb_build_array(jsonb_build_object('location_city_id', current_setting('t8.c1'), 'arrival_offset_minutes', 120, 'stop_duration_minutes', 45),
                    jsonb_build_object('location_city_id', current_setting('t8.c2'), 'arrival_offset_minutes', 150))::text), 'must arrive after the previous stop');
select pg_temp.fails('T8 last stop must depart before destination', format($q$select public.save_service_stops(%L, %L::jsonb)$q$, current_setting('t8.svc'),
  jsonb_build_array(jsonb_build_object('location_city_id', current_setting('t8.c1'), 'arrival_offset_minutes', 590, 'stop_duration_minutes', 15))::text), 'before the bus reaches the destination');
select pg_temp.ok('T8 failed save left the previous stops untouched (atomic)', (select count(*)=2 from bus_service_stops where service_id=current_setting('t8.svc')::uuid));
select pg_temp.fails('origin/destination cannot be a stop', format($q$select public.save_service_stops(%L, %L::jsonb)$q$, current_setting('t8.svc'),
  jsonb_build_array(jsonb_build_object('location_city_id', (select service_dest_city_id from bus_services where id=current_setting('t8.svc')::uuid), 'arrival_offset_minutes', 100))::text), 'origin or destination');
select pg_temp.fails('journey cannot be shortened below last stop', format($q$update bus_services set default_arrival_offset_minutes = 310 where id = %L$q$, current_setting('t8.svc')), 'shorter than the last stop');
reset role;

-- data-model guards (as table owner, bypassing the RPC)
select pg_temp.fails('meal type requires Meal Break purpose', format($q$insert into bus_service_stops(service_id,sequence_no,location_city_id,arrival_offset_minutes,meal_types) values (%L,9,%L,50,'{lunch}')$q$, current_setting('t8.svc'), current_setting('t8.c1')), 'violates check constraint');
select pg_temp.fails('unknown purpose rejected', format($q$insert into bus_service_stops(service_id,sequence_no,location_city_id,arrival_offset_minutes,stop_purposes) values (%L,9,%L,50,'{shopping}')$q$, current_setting('t8.svc'), current_setting('t8.c1')), 'violates check constraint');
select pg_temp.fails('stop must allow pickup or drop', format($q$insert into bus_service_stops(service_id,sequence_no,location_city_id,arrival_offset_minutes,allows_pickup,allows_drop) values (%L,9,%L,50,false,false)$q$, current_setting('t8.svc'), current_setting('t8.c1')), 'violates check constraint');
select pg_temp.fails('departure_offset is generated, not writable', format($q$insert into bus_service_stops(service_id,sequence_no,location_city_id,arrival_offset_minutes,departure_offset_minutes) values (%L,9,%L,50,60)$q$, current_setting('t8.svc'), current_setting('t8.c1')), 'non-DEFAULT value');

-- 9/10. overnight + customer-facing timeline (anon): 20:00 + 300 min = 01:00 next day
select public.save_service_stops(current_setting('t8.svc')::uuid, jsonb_build_array(
  jsonb_build_object('location_city_id', current_setting('t8.c1'), 'arrival_offset_minutes', 120, 'stop_duration_minutes', 30, 'stop_purposes', jsonb_build_array('meal_break'), 'meal_types', jsonb_build_array('dinner')),
  jsonb_build_object('location_city_id', current_setting('t8.c2'), 'arrival_offset_minutes', 300, 'stop_duration_minutes', 10, 'stop_purposes', jsonb_build_array('toilet_break')))) as n \gset
select set_config('request.jwt.claim.sub', '', false);
set role anon;
select pg_temp.ok('T9 stop 2 arrives 01:00 IST on the next day',
  (select (arrival_at at time zone 'Asia/Kolkata') = timestamp '2030-01-11 01:00' and (departure_at at time zone 'Asia/Kolkata') = timestamp '2030-01-11 01:10' from get_trip_stop_timeline(current_setting('t8.trip')::uuid) where sequence_no = 2));
select pg_temp.ok('T9 stop 1 same day 22:00-22:30', (select (arrival_at at time zone 'Asia/Kolkata') = timestamp '2030-01-10 22:00' and (departure_at at time zone 'Asia/Kolkata') = timestamp '2030-01-10 22:30' from get_trip_stop_timeline(current_setting('t8.trip')::uuid) where sequence_no = 1));
select pg_temp.ok('T10 customers get purposes via timeline', (select stop_purposes from get_trip_stop_timeline(current_setting('t8.trip')::uuid) where sequence_no=1) = '{meal_break}');
select pg_temp.ok('T10 timeline exposes no internal ids', (select pg_get_function_result(p.oid) !~* 'operator_id|service_id|uuid' from pg_proc p where p.proname='get_trip_stop_timeline'));
select pg_temp.fails('anon cannot save stops', format($q$select public.save_service_stops(%L, '[]')$q$, current_setting('t8.svc')), 'permission denied');
reset role;
\echo ALL STOP TESTS PASSED
