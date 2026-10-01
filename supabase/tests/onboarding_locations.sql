-- =========================================================================
-- Checks for 20261002000500_unified_locations.sql: ONE canonical locations
-- table with permanent codes, independent main-route / pickup / drop flags and
-- orders, admin-only writes, location-based routes and point-aware search.
-- Everything is rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin@test.invalid'),
  ('dddddddd-0000-0000-0000-00000000000d', 'cust@test.invalid');
insert into public.user_roles (user_id, role) values ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;
create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;

-- ---- 1. one table, 33 seeded locations with the supplied codes ----------
do $$
declare
  n int;
  expected text[] := array[
    'T8SVP001','T8ADA001','T8AMK001','T8BAD001','T8BAK001','T8BAS001','T8BET001','T8BIL001','T8CEO001','T8KAU001','T8KER001',
    'T8KOR001','T8BAR001','T8JIR001','T8UTT001','T8VSP001','T8RRO001','T8KAD001','T8MID001','T8MOH001','T8RAN001','T8NIM001',
    'T8NBT001','T8PAN001','T8PAR001','T8PYL001','T8SAB001','T8SIT001','T8KAL001','T8KPH001','T8MAY001','T8DIG001','T8AER001'];
  got text[];
begin
  if to_regclass('public.pickup_drop_points') is not null or to_regclass('public.main_locations') is not null or to_regclass('public.cities') is not null then
    raise exception 'FAIL 1a: a redundant location master still exists';
  end if;
  select count(*) into n from public.locations;
  if n <> 33 then raise exception 'FAIL 1b: expected 33 locations, got %', n; end if;
  select array_agg(location_code order by pickup_order) into got from public.locations;
  if got is distinct from expected then raise exception 'FAIL 1c: seeded codes / order wrong: %', got; end if;
  if (select location_code from public.locations where name = 'DIGLIPUR') <> 'T8DIG001' then raise exception 'FAIL 1d: Diglipur must be T8DIG001'; end if;
  if (select location_code from public.locations where name = 'AERIAL BAY') <> 'T8AER001' then raise exception 'FAIL 1e: Aerial Bay code'; end if;
  select count(*) - count(distinct location_code) into n from public.locations;
  if n <> 0 then raise exception 'FAIL 1f: duplicate codes'; end if;
  select count(*) - count(distinct normalized_name) into n from public.locations;
  if n <> 0 then raise exception 'FAIL 1g: duplicate names'; end if;
  select array_agg(location_code order by main_route_order) into got from public.locations where is_main_route_enabled and is_active;
  if got is distinct from array['T8SVP001','T8BAR001','T8KAD001','T8MID001','T8RAN001','T8NIM001','T8MAY001','T8DIG001','T8AER001'] then
    raise exception 'FAIL 1h: main route list wrong: %', got;
  end if;
  select count(*) into n from public.locations where is_pickup_enabled and is_drop_enabled and is_active;
  if n <> 33 then raise exception 'FAIL 1i: pickup/drop flags'; end if;
end $$;

insert into t_ref select 'SRC', id from public.locations where location_code = 'T8SVP001';
insert into t_ref select 'MID', id from public.locations where location_code = 'T8RAN001';
insert into t_ref select 'DST', id from public.locations where location_code = 'T8DIG001';
insert into t_ref select 'PICK', id from public.locations where location_code = 'T8BAK001';   -- bakultala: not a main route location
insert into t_ref select 'OTHER', id from public.locations where location_code = 'T8ADA001';  -- adazig: not on the route

-- ---- 2. only admins write ---------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;

do $$
begin
  begin
    insert into public.locations (name) values ('OPERATOR PLACE');
    raise exception 'FAIL 2a: operator inserted a location';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  update public.locations set is_active = false, is_pickup_enabled = false where location_code = 'T8RAN001';
  if (select is_active and is_pickup_enabled from public.locations where location_code = 'T8RAN001') is not true then
    raise exception 'FAIL 2b: operator changed a location';
  end if;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

-- ---- 3. admin adds / edits; codes are generated and permanent -----------
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;

do $$
declare v_id uuid; v_code text; v_main int; v_pick int; v_drop_before int; v_main_before int;
begin
  insert into public.locations (name, is_main_route_enabled) values ('Diglipur North', false) returning id, location_code into v_id, v_code;
  if v_code <> 'T8DIG002' then raise exception 'FAIL 3a: expected T8DIG002, got %', v_code; end if;
  insert into public.locations (name) values ('Zebra Point') returning location_code into v_code;
  if v_code <> 'T8ZEB001' then raise exception 'FAIL 3b: expected T8ZEB001, got %', v_code; end if;
  select main_route_order, pickup_order into v_main, v_pick from public.locations where name = 'Zebra Point';
  if v_main <= 130 or v_pick <> 35 then raise exception 'FAIL 3c: default orders % / %', v_main, v_pick; end if;

  begin insert into public.locations (name) values ('diglipur'); raise exception 'FAIL 3d: duplicate accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin insert into public.locations (name) values ('R-R O'); raise exception 'FAIL 3e: normalised duplicate accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin insert into public.locations (name) values ('   '); raise exception 'FAIL 3f: blank name accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  update public.locations set name = 'Diglipur North Terminal', port_name = 'Test Jetty' where id = v_id;
  if (select location_code from public.locations where id = v_id) <> 'T8DIG002' then raise exception 'FAIL 3g: code changed on rename'; end if;
  begin update public.locations set location_code = 'T8DIG099' where id = v_id; raise exception 'FAIL 3h: code edited';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin delete from public.locations where id = v_id; raise exception 'FAIL 3i: location deleted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin update public.locations set latitude = 11.5 where id = v_id; raise exception 'FAIL 3j: half coordinates accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  update public.locations set latitude = 13.26, longitude = 93.0 where id = v_id;

  -- the three uses are independent: flags and orders
  select drop_order, main_route_order into v_drop_before, v_main_before from public.locations where id = v_id;
  update public.locations set is_pickup_enabled = false, pickup_order = 99 where id = v_id;
  if not (select pickup_order = 99 and not is_pickup_enabled and is_drop_enabled and drop_order = v_drop_before and main_route_order = v_main_before
          from public.locations where id = v_id) then
    raise exception 'FAIL 3k: pickup change leaked into drop / main route';
  end if;
  update public.locations set is_active = false where id = v_id;
  if (select is_active from public.locations where id = v_id) then raise exception 'FAIL 3m: disable did not persist'; end if;
end $$;

-- ---- 4. public read ----------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
do $$
declare n int;
begin
  select count(*) into n from public.locations where is_active and is_main_route_enabled;
  if n <> 10 then raise exception 'FAIL 4a: anon main route locations = %', n; end if;
  begin insert into public.locations (name) values ('ANON'); raise exception 'FAIL 4b: anon wrote';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
reset role;

-- ---- 5. a route built from locations ----------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'BUS', (public.create_bus((select id from t_ops where tag = 'A'), 'Loc Bus', 'AN01L0001', 'ac_seater', 3)).id;

do $$
declare
  v_bus uuid := (select id from t_ref where tag = 'BUS');
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_mid uuid := (select id from t_ref where tag = 'MID');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  v_pick uuid := (select id from t_ref where tag = 'PICK');
  r jsonb;
begin
  r := public.save_bus_layout(v_bus, '{"rows":2,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"}]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup layout: %', r -> 'errors'; end if;

  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('name','Origin','is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5a: stop without a location accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  begin
    perform public.save_bus_route(v_bus, v_pick, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('city_id',v_pick,'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5b: non-main origin accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('city_id',v_mid,'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5c: wrong first stop accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('city_id',v_src,'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('city_id',v_mid,'is_boarding',true,'is_dropping',true,'arrival_offset_min',100,'departure_offset_min',105),
      jsonb_build_object('city_id',v_mid,'is_boarding',true,'is_dropping',true,'arrival_offset_min',110,'departure_offset_min',115),
      jsonb_build_object('city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5d: repeated location accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('city_id',v_src,'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('city_id',v_pick,'is_boarding',false,'is_dropping',false,'arrival_offset_min',100,'departure_offset_min',105),
      jsonb_build_object('city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5e: stop with no pickup/drop use accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- valid: SVP -> BAKULTALA (pickup + drop, not a main location) -> RANGAT -> DIGLIPUR
  r := public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1,2,3,4,5,6,7}', jsonb_build_array(
    jsonb_build_object('name','typed names are ignored','city_id',v_src,'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
    jsonb_build_object('city_id',v_pick,'is_boarding',true,'is_dropping',true,'arrival_offset_min',60,'departure_offset_min',65),
    jsonb_build_object('city_id',v_mid,'is_boarding',false,'is_dropping',true,'arrival_offset_min',120,'departure_offset_min',120),
    jsonb_build_object('city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 5g: valid route rejected: %', r -> 'errors'; end if;
end $$;

-- stop names always come from the location
do $$
declare v_route uuid := (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
begin
  if exists (select 1 from public.boarding_points b join public.locations l on l.id = b.city_id where b.route_id = v_route and b.name <> l.name) then
    raise exception 'FAIL 5h: a stop name differs from its location';
  end if;
end $$;

-- route_stops: ordered locations; service_stops: what the service serves
do $$
declare
  v_route uuid := (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
  v_svc uuid := (select id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
  got uuid[];
begin
  select array_agg(location_id order by stop_order) into got from public.route_stops where route_id = v_route;
  if got is distinct from array[(select id from t_ref where tag='SRC'), (select id from t_ref where tag='PICK'), (select id from t_ref where tag='MID'), (select id from t_ref where tag='DST')] then
    raise exception 'FAIL 5i: route_stops order wrong: %', got;
  end if;
  if not exists (select 1 from public.service_stops where service_id = v_svc and location_id = (select id from t_ref where tag='PICK') and pickup_enabled and drop_enabled and pickup_time = time '07:05') then
    raise exception 'FAIL 5j: service_stops for the intermediate stop';
  end if;
  if exists (select 1 from public.service_stops where service_id = v_svc and location_id = (select id from t_ref where tag='OTHER')) then
    raise exception 'FAIL 5k: unserved location in service_stops';
  end if;
end $$;

-- ---- 6. activate and create a trip -----------------------------------------
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS');
begin
  perform public.save_bus_fares(v_bus, '[{"seat_type":"seater","base_fare_cents":30000}]'::jsonb, '[]'::jsonb);
end $$;
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

-- ---- 7. search by location ids ---------------------------------------------
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  v_mid uuid := (select id from t_ref where tag = 'MID');
  v_pick uuid := (select id from t_ref where tag = 'PICK');
  v_other uuid := (select id from t_ref where tag = 'OTHER');
  d date := current_date + 2;
  res jsonb; pts jsonb;
  hits int;
begin
  res := public.search_trips(v_src, v_dst, d);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 1 then raise exception 'FAIL 7a: plain search should find the trip'; end if;

  res := public.search_trips(v_src, v_mid, d);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 1 then raise exception 'FAIL 7b: search to an intermediate main location'; end if;

  res := public.search_trips(v_src, v_dst, d, v_pick, null);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 1 then raise exception 'FAIL 7c: pickup at a served stop should match'; end if;
  res := public.search_trips(v_src, v_dst, d, v_pick, v_mid);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 1 then raise exception 'FAIL 7d: pickup + drop at served stops should match'; end if;

  res := public.search_trips(v_src, v_dst, d, v_other, null);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 0 then raise exception 'FAIL 7e: unserved pickup matched'; end if;
  res := public.search_trips(v_src, v_dst, d, null, v_other);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 0 then raise exception 'FAIL 7f: unserved drop matched'; end if;
  res := public.search_trips(v_src, v_mid, d, v_dst, null);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 0 then raise exception 'FAIL 7g: pickup beyond the destination matched'; end if;

  pts := public.get_journey_points(v_src, v_dst, d);
  if not exists (select 1 from jsonb_array_elements(pts -> 'pickup') p where p ->> 'location_code' = 'T8BAK001' and p ->> 'name' = 'BAKULTALA' and p ->> 'id' = v_pick::text) then
    raise exception 'FAIL 7h: pickup options: %', pts;
  end if;
  if jsonb_array_length(pts -> 'pickup') <> 2 then raise exception 'FAIL 7i: expected the origin and bakultala as pickups, got %', pts -> 'pickup'; end if;
  if jsonb_array_length(pts -> 'drop') <> 3 then raise exception 'FAIL 7j: expected 3 drop options, got %', pts -> 'drop'; end if;
end $$;

-- ---- 8. disabling a pickup flag hides it from customers; drop stays --------
reset role;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
update public.locations set is_pickup_enabled = false where id = (select id from t_ref where tag = 'PICK');
reset role;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare pts jsonb;
begin
  pts := public.get_journey_points((select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'), current_date + 2);
  if exists (select 1 from jsonb_array_elements(pts -> 'pickup') p where p ->> 'location_code' = 'T8BAK001') then
    raise exception 'FAIL 8a: pickup-disabled location still offered';
  end if;
  if not exists (select 1 from jsonb_array_elements(pts -> 'drop') p where p ->> 'location_code' = 'T8BAK001') then
    raise exception 'FAIL 8b: drop flag should be independent';
  end if;
end $$;

-- ---- 9. rename propagates; deactivation blocks new searches only -----------
reset role;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
update public.locations set name = 'RANGAT TOWN' where id = (select id from t_ref where tag = 'MID');
do $$
declare v_route uuid := (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
begin
  if not exists (select 1 from public.dropping_points where route_id = v_route and name = 'RANGAT TOWN') then raise exception 'FAIL 9a: rename did not reach the route stop'; end if;
  if (select location_code from public.locations where id = (select id from t_ref where tag = 'MID')) <> 'T8RAN001' then raise exception 'FAIL 9b: code changed'; end if;
end $$;
update public.locations set is_active = false where id = (select id from t_ref where tag = 'MID');
reset role;
create function pg_temp.stop_count(p_loc uuid) returns bigint language sql security definer as $f$
  select count(*) from public.route_stops where location_id = p_loc
$f$;
grant execute on function pg_temp.stop_count(uuid) to authenticated;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare res jsonb; hits int;
begin
  res := public.search_trips((select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'MID'), current_date + 2);
  if jsonb_array_length(res -> 'direct') <> 0 then raise exception 'FAIL 9c: disabled location still searchable'; end if;
  res := public.search_trips((select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'), current_date + 2);
  select count(*) into hits from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A';
  if hits <> 1 then raise exception 'FAIL 9d: the existing route must keep working'; end if;
  -- read with definer rights: since 20261002000600 a customer cannot read route stops directly
  if pg_temp.stop_count((select id from t_ref where tag = 'MID')) <> 1 then raise exception 'FAIL 9e: stop lost'; end if;
  if exists (select 1 from public.search_cities('', 50) where id = (select id from t_ref where tag = 'MID')) then raise exception 'FAIL 9f: disabled location in city list'; end if;
end $$;

reset role;
rollback;
