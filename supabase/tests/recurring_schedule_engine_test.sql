\set ON_ERROR_STOP on
\set QUIET on
create or replace function pg_temp.ok(p_name text, p_cond boolean) returns void language plpgsql as $$
begin if p_cond is not true then raise exception 'FAIL: %', p_name; end if; raise notice 'PASS: %', p_name; end $$;

-- fixtures: operator A (demo), second route/service on other cities
do $$
declare v_op uuid; v_bus uuid; v_lay uuid; v_route uuid; v_a uuid; v_b uuid; v_svc uuid; r int; c int; v_dg uuid; v_pb uuid;
begin
  select id into v_op from operators where name='Andaman Express (Demo)';
  select id into v_pb from cities where name ilike '%Sri Vijaya Puram%';
  select id into v_dg from cities where name ilike '%Diglipur%';
  insert into buses(operator_id,registration_number,bus_type,total_seats) values (v_op,'AN01-TEST-0002','ac_seater',8) returning id into v_bus;
  insert into bus_layouts(bus_id,is_active) values (v_bus,true) returning id into v_lay;
  for r in 1..2 loop for c in 1..4 loop insert into seats(bus_layout_id,seat_code,row_no,col_no) values (v_lay, r||'-'||c, r, c); end loop; end loop;
  insert into bus_routes(operator_id,source_city_id,destination_city_id) values (v_op,v_dg,v_pb) returning id into v_route;
  -- Mon/Wed/Fri/Sat service, created WITHOUT a fare first (form order), then fare
  insert into bus_services(operator_id,route_id,bus_id,service_name,service_source_city_id,service_dest_city_id,default_departure_time,default_arrival_offset_minutes,operating_days)
   values (v_op,v_route,v_bus,'Test B',v_dg,v_pb,'05:00',600,'{1,3,5,6}') returning id into v_svc;
  perform set_config('t8.svc_b', v_svc::text, false);
  perform set_config('t8.route_b', v_route::text, false);
  perform set_config('t8.bus_b', v_bus::text, false);
end $$;

select pg_temp.ok('T0 no departures generated before fare configured', (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid)=0);
insert into fare_rules(service_id,seat_type,base_fare_cents) values (current_setting('t8.svc_b')::uuid,'seater',30000);
select pg_temp.ok('T1 fare insert auto-generates departures (no operator action)', (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid)>0);

-- T6 operating days
select pg_temp.ok('T6 only Mon/Wed/Fri/Sat generated',
  (select bool_and(extract(isodow from travel_date) in (1,3,5,6)) from bus_trips where service_id=current_setting('t8.svc_b')::uuid));

-- T1 window = 30 days default
select pg_temp.ok('T1 horizon = today+30 (IST)', (select max(travel_date) <= private.platform_today()+30 from bus_trips where service_id=current_setting('t8.svc_b')::uuid)
   and (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid) = (select count(*) from generate_series(private.platform_today(), private.platform_today()+30, '1 day') g(d) where extract(isodow from g.d) in (1,3,5,6) and ((g.d::date + time '05:00') at time zone 'Asia/Kolkata') > now()));

-- T10 timezone: 05:00 IST = 23:30 UTC prior day
select pg_temp.ok('T10 departure stored as 05:00 Asia/Kolkata', (select bool_and((departure_at at time zone 'Asia/Kolkata')::time = '05:00') from bus_trips where service_id=current_setting('t8.svc_b')::uuid));
select pg_temp.ok('T10 arrival = +600 min', (select bool_and(arrival_at-departure_at = interval '600 minutes') from bus_trips where service_id=current_setting('t8.svc_b')::uuid));

-- T7 duplicates: run generator 3x, concurrent-safe unique
select private.run_rolling_schedule_generation('test'); select private.run_rolling_schedule_generation('test'); select private.run_rolling_schedule_generation('test');
select pg_temp.ok('T7 no duplicate (service,date)', (select count(*) = count(distinct (service_id,travel_date)) from bus_trips));
select pg_temp.ok('T7 runs recorded without errors', (select bool_and(status='completed') from schedule_generation_runs where trigger_source='test'));

-- T8 seat inventory
select pg_temp.ok('T8 each new trip has 8 seats, isolated', (select bool_and(n=8) from (select t.id, count(ts.id) n from bus_trips t join trip_seats ts on ts.trip_id=t.id where t.service_id=current_setting('t8.svc_b')::uuid group by t.id) x));
select pg_temp.ok('T8 available_seats set', (select bool_and(available_seats=8) from bus_trips where service_id=current_setting('t8.svc_b')::uuid));
select pg_temp.ok('T8 fares populated', (select bool_and(min_fare_cents=30000) from bus_trips where service_id=current_setting('t8.svc_b')::uuid));

-- T2 route-specific horizons: demo route A=30(global), route B = 7
insert into route_booking_windows(route_id,advance_days) values (current_setting('t8.route_b')::uuid, 7);
select pg_temp.ok('T2 route B effective 7, source route', (select (public.get_effective_booking_window(current_setting('t8.route_b')::uuid)->>'advance_days')='7' and (public.get_effective_booking_window(current_setting('t8.route_b')::uuid)->>'source')='route'));
select pg_temp.ok('T2 route A effective 30, source global', (select (public.get_effective_booking_window((select route_id from bus_services where service_name<>'Test B' limit 1))->>'advance_days')='30'));
-- generated trips remain (not deleted) but are hidden beyond horizon
select pg_temp.ok('T3 trips beyond new horizon preserved', (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date > private.platform_today()+7) > 0);
do $$
declare v_far date; v_n int;
begin
  select max(travel_date) into v_far from bus_trips where service_id=current_setting('t8.svc_b')::uuid;
  select jsonb_array_length((public.search_trips((select service_source_city_id from bus_services where id=current_setting('t8.svc_b')::uuid),(select service_dest_city_id from bus_services where id=current_setting('t8.svc_b')::uuid), v_far))->'direct') into v_n;
  perform pg_temp.ok('T3 search hides departure beyond 7-day horizon', v_n=0);
  select min(travel_date) into v_far from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date>private.platform_today();
  select jsonb_array_length((public.search_trips((select service_source_city_id from bus_services where id=current_setting('t8.svc_b')::uuid),(select service_dest_city_id from bus_services where id=current_setting('t8.svc_b')::uuid), v_far))->'direct') into v_n;
  perform pg_temp.ok('T3 search shows departure inside horizon', v_n=1);
end $$;

-- T4 increase 7 -> 60: more generated automatically
select count(*) as before_n from bus_trips where service_id=current_setting('t8.svc_b')::uuid \gset
update route_booking_windows set advance_days=60 where route_id=current_setting('t8.route_b')::uuid;
select pg_temp.ok('T4 increasing window generates additional departures', (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid) > :before_n);
select pg_temp.ok('T4 horizon through today+60', (select max(travel_date) > private.platform_today()+50 from bus_trips where service_id=current_setting('t8.svc_b')::uuid));
update route_booking_windows set advance_days=30 where route_id=current_setting('t8.route_b')::uuid;

-- audit
select pg_temp.ok('Audit rows for window changes', (select count(*)>=3 from audit_logs where entity_type='route_booking_window'));

-- T9 existing bookings: create a user+booking item on a B trip, then change schedule
insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000c1','c1@x.io') on conflict do nothing;
do $$ begin
  if not exists (select 1 from profiles where id='00000000-0000-0000-0000-0000000000c1') then
    insert into profiles(id,email) values ('00000000-0000-0000-0000-0000000000c1','c1@x.io'); end if;
exception when others then raise notice 'profile insert: %', sqlerrm; end $$;
select id as btrip from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date>private.platform_today() order by travel_date limit 1 \gset
select pg_temp.ok('hold insert allowed on bookable trip', (select true from (select 1) x where (select count(*) from bus_trips where id=:'btrip' and private.is_trip_bookable(bus_trips))=1));
insert into seat_holds(trip_id,user_id,expires_at) values (:'btrip','00000000-0000-0000-0000-0000000000c1', now()+interval '5 min') returning id as hold \gset
insert into bookings(booking_reference,customer_id,status,total_fare_cents) values ('T8TEST1','00000000-0000-0000-0000-0000000000c1','confirmed',30000) returning id as bkg \gset
insert into booking_items(booking_id,trip_id,trip_seat_id,boarding_point_id,dropping_point_id,fare_cents,status)
 select :'bkg', :'btrip', ts.id, (select id from boarding_points limit 1),(select id from dropping_points limit 1), 30000,'confirmed' from trip_seats ts where ts.trip_id=:'btrip' limit 1;
update trip_seats set status='booked' where id=(select trip_seat_id from booking_items where booking_id=:'bkg');
update seat_holds set status='confirmed' where id=:'hold';
-- change departure time & days; the booked trip must survive untouched
update bus_services set default_departure_time='07:30', operating_days='{1,2,3,4,5,6,7}' where id=current_setting('t8.svc_b')::uuid;
select pg_temp.ok('T9 booked departure preserved with original time', (select (departure_at at time zone 'Asia/Kolkata')::time='05:00' from bus_trips where id=:'btrip'));
select pg_temp.ok('T9 booking item + seat intact', (select count(*)=1 from booking_items where booking_id=:'bkg') and (select count(*)=1 from trip_seats where trip_id=:'btrip' and status='booked'));
select pg_temp.ok('T9 unbooked future trips rebuilt at 07:30 every day', (select bool_and((departure_at at time zone 'Asia/Kolkata')::time='07:30') from bus_trips where service_id=current_setting('t8.svc_b')::uuid and id<>:'btrip' and generated_by='scheduler'));
select pg_temp.ok('T9 still one trip per date', (select count(*)=count(distinct (service_id,travel_date)) from bus_trips));
update bus_services set default_departure_time='05:00', operating_days='{1,3,5,6}' where id=current_setting('t8.svc_b')::uuid;

-- T5 pause / resume
-- ---- act as operator staff (authenticated) for RPCs
grant usage on schema private to authenticated; grant usage on schema auth to authenticated; grant usage on schema public to anon, authenticated; grant all on all tables in schema public to anon, authenticated;
select user_id as opuser from user_roles where role='operator_admin' limit 1 \gset
select set_config('request.jwt.claim.sub', :'opuser', false);
set role authenticated;

select count(*) as n_before from bus_trips where service_id=current_setting('t8.svc_b')::uuid \gset
select public.set_service_schedule_status(current_setting('t8.svc_b')::uuid,'paused') \gset
select pg_temp.ok('T5 paused status', (select status='paused' from bus_services where id=current_setting('t8.svc_b')::uuid));
reset role;
-- admin raises window while paused -> nothing generated
update scheduling_settings set max_advance_days=365;
update route_booking_windows set advance_days=90 where route_id=current_setting('t8.route_b')::uuid;
select pg_temp.ok('T5 paused: no new departures generated', (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid)=:n_before);
select private.run_rolling_schedule_generation('test');
select pg_temp.ok('T5 paused: cron generates nothing', (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid)=:n_before);
select pg_temp.ok('T5 paused: bookings preserved', (select count(*)=1 from booking_items where booking_id=:'bkg'));
select set_config('request.jwt.claim.sub', :'opuser', false); set role authenticated;
select public.set_service_schedule_status(current_setting('t8.svc_b')::uuid,'active') \gset
reset role;
select pg_temp.ok('T5 resume regenerates missing', (select count(*) from bus_trips where service_id=current_setting('t8.svc_b')::uuid)>:n_before);
select pg_temp.ok('T5 resume: no duplicates', (select count(*)=count(distinct (service_id,travel_date)) from bus_trips));
update route_booking_windows set advance_days=30 where route_id=current_setting('t8.route_b')::uuid;

-- suspension: range inside window
select (private.platform_today()+10) as s_start, (private.platform_today()+16) as s_end \gset
select set_config('request.jwt.claim.sub', :'opuser', false); set role authenticated;
select public.suspend_service_dates(current_setting('t8.svc_b')::uuid, :'s_start', :'s_end', 'drydock') as susp \gset
select (:'susp'::jsonb->>'exception_id')::uuid as exc_id \gset
reset role;
select pg_temp.ok('Suspension: no departures in range', (select count(*)=0 from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date between :'s_start' and :'s_end'));
select private.run_rolling_schedule_generation('test');
select pg_temp.ok('Suspension: generator still skips range', (select count(*)=0 from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date between :'s_start' and :'s_end'));
select pg_temp.ok('Suspension: dates after range remain', (select count(*)>0 from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date > :'s_end'));
select set_config('request.jwt.claim.sub', :'opuser', false); set role authenticated;
select public.remove_service_suspension(:'exc_id');
reset role;
select pg_temp.ok('Suspension removed: range regenerated', (select count(*)>0 from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date between :'s_start' and :'s_end'));

select set_config('t8.btrip', :'btrip', false);
select set_config('request.jwt.claim.sub', :'opuser', false); set role authenticated;
do $$ begin
  begin update bus_trips set status='cancelled' where id=current_setting('t8.btrip', true)::uuid;
        raise exception 'FAIL: operator cancelled directly';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS: direct operator cancel blocked (%)', left(sqlerrm,50); end;
end $$;
do $$ begin
  begin delete from bus_trips where service_id=current_setting('t8.svc_b')::uuid; 
  if found then raise exception 'FAIL: operator deleted trips'; end if;
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  raise notice 'PASS: operator cannot delete trips (rls)';
end $$;
select public.request_trip_cancellation(:'btrip','bus breakdown');
reset role;
select pg_temp.ok('Cancel request recorded, trip not cancelled yet', (select status='scheduled' and cancellation_request_status='requested' from bus_trips where id=:'btrip'));
select pg_temp.ok('Requested trip hidden from search', (select jsonb_array_length((public.search_trips((select service_source_city_id from bus_services where id=current_setting('t8.svc_b')::uuid),(select service_dest_city_id from bus_services where id=current_setting('t8.svc_b')::uuid),(select travel_date from bus_trips where id=:'btrip')))->'direct')=0));
select pg_temp.ok('Requested trip rejects new holds', (select not private.is_trip_bookable(t) from bus_trips t where id=:'btrip'));
-- non-admin can't approve
select set_config('request.jwt.claim.sub', :'opuser', false); set role authenticated;
do $$ begin begin perform public.admin_decide_trip_cancellation(current_setting('t8.btrip',true)::uuid, true); raise exception 'FAIL: operator approved';
 exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS: operator cannot approve cancellation'; end; end $$;
reset role;
-- admin
insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000a1','adm@x.io') on conflict do nothing;
insert into user_roles(user_id,role) values ('00000000-0000-0000-0000-0000000000a1','platform_admin') on conflict do nothing;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1', false); set role authenticated;
select public.admin_decide_trip_cancellation(:'btrip', true, 'ok') as dec \gset
reset role;
select pg_temp.ok('Admin approval cancels trip + booking', (select status='cancelled' from bus_trips where id=:'btrip') and (select status='cancelled' from bookings where id=:'bkg'));
select pg_temp.ok('Refund opened only if payment existed (no payment => none)', (select count(*)=0 from refunds));
select pg_temp.ok('Generator does not resurrect cancelled departure', (select (select count(*) from bus_trips where id=:'btrip')=1) and (select status='cancelled' from bus_trips where id=:'btrip'));
select private.run_rolling_schedule_generation('test');
select pg_temp.ok('Cancelled date still single row after run', (select count(*)=1 from bus_trips where service_id=current_setting('t8.svc_b')::uuid and travel_date=(select travel_date from bus_trips where id=:'btrip')));

-- anon cannot read admin config RPC / tables
set role anon;
do $$ begin begin perform public.admin_route_booking_windows(); raise exception 'FAIL: anon admin rpc';
 exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS: anon blocked from admin RPC'; end; end $$;
do $$ declare n int; begin begin select count(*) into n from scheduling_settings; if n>0 then raise exception 'FAIL: anon read settings'; end if; raise exception 'rls-empty';
 exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS: anon blocked from settings'; end; end $$;
reset role;
-- operator cannot write config
select set_config('request.jwt.claim.sub', :'opuser', false); set role authenticated;
do $$ declare n int; begin update scheduling_settings set default_advance_days=99; get diagnostics n=row_count; if n>0 then raise exception 'FAIL: operator changed global window'; end if; raise notice 'PASS: operator cannot change global window (0 rows)'; end $$;
do $$ declare n int; begin begin insert into route_booking_windows(route_id,advance_days) values (current_setting('t8.route_b')::uuid, 3); raise exception 'FAIL: operator wrote route window';
 exception when others then if sqlerrm like 'FAIL%' then raise; end if; raise notice 'PASS: operator cannot write route window'; end; end $$;
reset role;

-- layout change: new seat added later -> future trips get it, existing untouched
select (select id from bus_layouts where bus_id=current_setting('t8.bus_b')::uuid) as lay \gset
select count(*) as booked_before from trip_seats where status='booked' \gset
insert into seats(bus_layout_id,seat_code,row_no,col_no) values (:'lay','X-9',9,9);
select pg_temp.ok('Layout: new seat added to future unsold trips (9 seats)', (select bool_and(n=9) from (select t.id, count(*) n from bus_trips t join trip_seats ts on ts.trip_id=t.id where t.service_id=current_setting('t8.svc_b')::uuid and t.status='scheduled' group by t.id) x));
select pg_temp.ok('Layout: booked seats untouched', (select count(*) from trip_seats where status='booked')=:booked_before);

-- Hold guard past horizon
select pg_temp.ok('Guard: trip beyond horizon not bookable', (select not private.is_trip_bookable(t) from bus_trips t where service_id=current_setting('t8.svc_b')::uuid and travel_date>private.platform_today()+30 limit 1) is not false);
select * from (select count(*) trips, count(distinct service_id) services from bus_trips) x;
