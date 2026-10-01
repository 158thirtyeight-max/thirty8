-- =========================================================================
-- Checks for 20261001000500 / 20261001000600: centralised main locations,
-- master pickup / drop points, route validation against them, and
-- point-aware search. Everything is rolled back.
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

-- ---- 1. seed: ten approved locations, exactly once, in order -------------
do $$
declare
  expected text[] := array['SRI VIJAYA PURAM','BAMBOOFLAT','BARATANG','MIDDLE STRAIT','KADAMTALA','RANGAT','NIMBUDERA','MAYABUNDER','DIGLIPUR','AERIAL BAY- DIGLIPUR'];
  got text[];
  n int;
begin
  select array_agg(name order by display_order) into got from public.main_locations where display_order between 1 and 10;
  if got is distinct from expected then raise exception 'FAIL 1a: seeded locations/order wrong: %', got; end if;
  select count(*) into n from public.main_locations where display_order between 1 and 10 and is_active;
  if n <> 10 then raise exception 'FAIL 1b: expected 10 active seeded locations, got %', n; end if;
  select count(*) - count(distinct slug) into n from public.cities where slug is not null;
  if n <> 0 then raise exception 'FAIL 1c: duplicate slugs'; end if;
  select count(*) into n from public.main_locations where upper(name) = 'DIGLIPUR';
  if n <> 1 then raise exception 'FAIL 1d: DIGLIPUR must exist exactly once, got %', n; end if;
  -- non-approved legacy locations are not main locations
  if exists (select 1 from public.main_locations where name in ('Jirkatang', 'Billiground')) then
    raise exception 'FAIL 1e: legacy locations leaked into main_locations';
  end if;
end $$;

insert into t_ref select 'SRC', id from public.main_locations where slug = 'sri-vijaya-puram';
insert into t_ref select 'MID', id from public.main_locations where slug = 'rangat';
insert into t_ref select 'DST', id from public.main_locations where slug = 'diglipur';
insert into t_ref select 'OTHER', id from public.main_locations where slug = 'baratang';

-- ---- 2. security: only admins write master data --------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;

do $$
begin
  begin
    insert into public.main_locations (name) values ('OPERATOR PLACE');
    raise exception 'FAIL 2a: operator inserted a main location';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    insert into public.pickup_drop_points (main_location_id, name) values ((select id from t_ref where tag = 'SRC'), 'Operator Stand');
    raise exception 'FAIL 2b: operator inserted a master point';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  update public.main_locations set is_active = false where slug = 'rangat';
  if (select is_active from public.main_locations where slug = 'rangat') is not true then
    raise exception 'FAIL 2c: operator deactivated a main location';
  end if;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

-- ---- 3. admin manages locations and points -------------------------------
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;

do $$
declare v_id uuid; v_order int;
begin
  insert into public.main_locations (name) values ('TEST NEW LOCATION') returning id, display_order into v_id, v_order;
  if v_order <> 11 then raise exception 'FAIL 3a: new location should get the next display order, got %', v_order; end if;
  if (select slug from public.main_locations where id = v_id) <> 'test-new-location' then raise exception 'FAIL 3b: slug not generated'; end if;
  update public.main_locations set display_order = 3, name = 'TEST RENAMED' where id = v_id;
  if (select display_order from public.main_locations where id = v_id) <> 3 then raise exception 'FAIL 3c: order not editable'; end if;
  begin
    insert into public.main_locations (name) values ('Test-New Location');
    raise exception 'FAIL 3d: duplicate slug accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  update public.main_locations set is_active = false where id = v_id;
end $$;

with p as (insert into public.pickup_drop_points (main_location_id, name, landmark, display_order)
           values ((select id from t_ref where tag = 'SRC'), 'Test Bus Stand', 'Near the jetty', 1) returning id)
  insert into t_ref select 'P_SRC_BUS', id from p;
with p as (insert into public.pickup_drop_points (main_location_id, name, display_order)
           values ((select id from t_ref where tag = 'SRC'), 'Test Bazaar', 2) returning id)
  insert into t_ref select 'P_SRC_BAZAAR', id from p;
with p as (insert into public.pickup_drop_points (main_location_id, name, is_drop_allowed)
           values ((select id from t_ref where tag = 'SRC'), 'Pickup Only Corner', false) returning id)
  insert into t_ref select 'P_SRC_PICKONLY', id from p;
with p as (insert into public.pickup_drop_points (main_location_id, name, is_pickup_allowed)
           values ((select id from t_ref where tag = 'MID'), 'Test Mid Market', false) returning id)
  insert into t_ref select 'P_MID_DROPONLY', id from p;
with p as (insert into public.pickup_drop_points (main_location_id, name)
           values ((select id from t_ref where tag = 'DST'), 'Test Dest Stand') returning id)
  insert into t_ref select 'P_DST', id from p;
with p as (insert into public.pickup_drop_points (main_location_id, name)
           values ((select id from t_ref where tag = 'DST'), 'Unserved Dest Point') returning id)
  insert into t_ref select 'P_DST_UNSERVED', id from p;

do $$
begin
  begin
    insert into public.pickup_drop_points (main_location_id, name) values ((select id from t_ref where tag = 'SRC'), 'TEST bus stand');
    raise exception 'FAIL 3e: duplicate point name in one location accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    insert into public.pickup_drop_points (main_location_id, name, latitude) values ((select id from t_ref where tag = 'SRC'), 'Half Coords', 11.5);
    raise exception 'FAIL 3f: latitude without longitude accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  -- coordinates are optional and can be added later without a schema change
  update public.pickup_drop_points set latitude = 11.6234, longitude = 92.7265 where id = (select id from t_ref where tag = 'P_SRC_BUS');
end $$;

-- ---- 4. visibility: active only for the public --------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.pickup_drop_points set is_active = false where id = (select id from t_ref where tag = 'P_DST_UNSERVED');
set local role anon;
do $$
declare n int;
begin
  select count(*) into n from public.pickup_drop_points where name = 'Unserved Dest Point';
  if n <> 0 then raise exception 'FAIL 4a: anon sees an inactive point'; end if;
  select count(*) into n from public.pickup_drop_points where name = 'Test Bus Stand';
  if n <> 1 then raise exception 'FAIL 4b: anon cannot see an active point'; end if;
  select count(*) into n from public.main_locations where display_order <= 10 and is_active;
  if n <> 10 then raise exception 'FAIL 4c: anon cannot read main locations'; end if;
end $$;
reset role;
update public.pickup_drop_points set is_active = true where id = (select id from t_ref where tag = 'P_DST_UNSERVED');

-- ---- 5. route with ordered main locations and master points -------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'BUS', (public.create_bus((select id from t_ops where tag = 'A'), 'Loc Bus', 'AN01L0001', 'ac_seater', 3)).id;

do $$
declare
  v_bus uuid := (select id from t_ref where tag = 'BUS');
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_mid uuid := (select id from t_ref where tag = 'MID');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  v_other uuid := (select id from t_ref where tag = 'OTHER');
  r jsonb;
begin
  r := public.save_bus_layout(v_bus, '{"rows":2,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"}]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup layout: %', r -> 'errors'; end if;

  -- 5a. a stop without a main location is rejected
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1,2,3,4,5,6,7}', jsonb_build_array(
      jsonb_build_object('name','Origin','is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Dest','city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5a: stop without a main location accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- 5b. first stop must be the origin
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('name','Origin','city_id',v_other,'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Dest','city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5b: wrong origin stop accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- 5c. a location cannot reappear after another one
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('name','Origin','city_id',v_src,'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Mid','city_id',v_mid,'is_boarding',true,'is_dropping',true,'arrival_offset_min',100,'departure_offset_min',105),
      jsonb_build_object('name','Again','city_id',v_src,'is_boarding',true,'is_dropping',true,'arrival_offset_min',150,'departure_offset_min',155),
      jsonb_build_object('name','Dest','city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5c: repeated location accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- 5d. a master point of another location is rejected
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('name','Test Dest Stand','city_id',v_src,'master_point_id',(select id from t_ref where tag='P_DST'),'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Dest','city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5d: point from another location accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- 5e/5f. pickup / drop permissions are enforced independently
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('name','Pickup Only Corner','city_id',v_src,'master_point_id',(select id from t_ref where tag='P_SRC_PICKONLY'),'is_boarding',true,'is_dropping',true,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Dest','city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5e: drop at a pickup-only point accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1}', jsonb_build_array(
      jsonb_build_object('name','Test Bus Stand','city_id',v_src,'master_point_id',(select id from t_ref where tag='P_SRC_BUS'),'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Test Mid Market','city_id',v_mid,'master_point_id',(select id from t_ref where tag='P_MID_DROPONLY'),'is_boarding',true,'is_dropping',true,'arrival_offset_min',100,'departure_offset_min',105),
      jsonb_build_object('name','Dest','city_id',v_dst,'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
    raise exception 'FAIL 5f: pickup at a drop-only point accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- 5g. a valid route: SRC (bus stand) -> MID (drop-only market) -> DST (dest stand)
  r := public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 240, '{1,2,3,4,5,6,7}', jsonb_build_array(
    jsonb_build_object('name','Test Bus Stand','city_id',v_src,'master_point_id',(select id from t_ref where tag='P_SRC_BUS'),'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
    jsonb_build_object('name','Test Mid Market','city_id',v_mid,'master_point_id',(select id from t_ref where tag='P_MID_DROPONLY'),'is_boarding',false,'is_dropping',true,'arrival_offset_min',120,'departure_offset_min',120),
    jsonb_build_object('name','Test Dest Stand','city_id',v_dst,'master_point_id',(select id from t_ref where tag='P_DST'),'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 5g: valid route rejected: %', r -> 'errors'; end if;
end $$;

-- route_stops keeps the main-location order; service_stops exposes only the served master points
do $$
declare
  v_route uuid := (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
  v_svc uuid := (select id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
  got uuid[];
  n int;
begin
  select array_agg(main_location_id order by stop_order) into got from public.route_stops where route_id = v_route;
  if got is distinct from array[(select id from t_ref where tag='SRC'), (select id from t_ref where tag='MID'), (select id from t_ref where tag='DST')] then
    raise exception 'FAIL 5h: route_stops order wrong: %', got;
  end if;
  select count(*) into n from public.service_stops where service_id = v_svc;
  if n <> 3 then raise exception 'FAIL 5i: service_stops should list 3 master points, got %', n; end if;
  if not exists (select 1 from public.service_stops where service_id = v_svc and point_id = (select id from t_ref where tag='P_SRC_BUS') and pickup_enabled and not drop_enabled) then
    raise exception 'FAIL 5j: bus stand should be pickup only';
  end if;
  if not exists (select 1 from public.service_stops where service_id = v_svc and point_id = (select id from t_ref where tag='P_MID_DROPONLY') and drop_enabled and not pickup_enabled and drop_time = time '08:00') then
    raise exception 'FAIL 5k: mid market should be drop only at 08:00';
  end if;
  if exists (select 1 from public.service_stops where service_id = v_svc and point_id = (select id from t_ref where tag='P_SRC_BAZAAR')) then
    raise exception 'FAIL 5l: an unserved point appears in service_stops';
  end if;
end $$;

-- ---- 6. activate the bus and create a trip ------------------------------
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

-- ---- 7. point-aware search ----------------------------------------------
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  v_mid uuid := (select id from t_ref where tag = 'MID');
  d date := current_date + 2;
  res jsonb; pts jsonb;
begin
  res := public.search_trips(v_src, v_dst, d);
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 1 then raise exception 'FAIL 7a: plain search should find the trip: %', res; end if;
  res := public.search_trips(v_src, v_mid, d);
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 1 then raise exception 'FAIL 7b: intermediate-location search should find the trip'; end if;
  res := public.search_trips(v_src, v_dst, d, (select id from t_ref where tag='P_SRC_BUS'), (select id from t_ref where tag='P_DST'));
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 1 then raise exception 'FAIL 7c: exact pickup+drop should match'; end if;
  res := public.search_trips(v_src, v_dst, d, (select id from t_ref where tag='P_SRC_BUS'), null);
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 1 then raise exception 'FAIL 7d: pickup-only filter should match'; end if;
  res := public.search_trips(v_src, v_dst, d, (select id from t_ref where tag='P_SRC_BAZAAR'), null);
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 0 then raise exception 'FAIL 7e: unserved pickup point matched'; end if;
  res := public.search_trips(v_src, v_dst, d, null, (select id from t_ref where tag='P_DST_UNSERVED'));
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 0 then raise exception 'FAIL 7f: unserved drop point matched'; end if;
  res := public.search_trips(v_mid, v_dst, d, (select id from t_ref where tag='P_MID_DROPONLY'), null);
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 0 then raise exception 'FAIL 7g: pickup at a drop-only point matched'; end if;

  pts := public.get_journey_points(v_src, v_dst, d);
  if jsonb_array_length(pts -> 'pickup') <> 1 or (pts -> 'pickup' -> 0 ->> 'name') <> 'Test Bus Stand' then raise exception 'FAIL 7h: pickup options wrong: %', pts; end if;
  if jsonb_array_length(pts -> 'drop') <> 1 or (pts -> 'drop' -> 0 ->> 'name') <> 'Test Dest Stand' then raise exception 'FAIL 7i: drop options wrong: %', pts; end if;
end $$;

-- ---- 8. deactivation: hidden from new searches, existing data stays valid
reset role;
select set_config('request.jwt.claims', '', true);
update public.cities set is_active = false where id = (select id from t_ref where tag = 'MID');
set local role authenticated;
do $$
declare
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_mid uuid := (select id from t_ref where tag = 'MID');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  res jsonb;
begin
  res := public.search_trips(v_src, v_mid, current_date + 2);
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 0 then raise exception 'FAIL 8a: inactive location is still searchable'; end if;
  res := public.search_trips(v_src, v_dst, current_date + 2);
  if (select count(*) from jsonb_array_elements(res -> 'direct') e where e ->> 'operator_name' = 'Op A') <> 1 then raise exception 'FAIL 8b: other searches must keep working'; end if;
  if (select count(*) from public.route_stops where main_location_id = v_mid) <> 1 then raise exception 'FAIL 8c: existing route lost its stop'; end if;
  if exists (select 1 from public.search_cities('', 20) where id = v_mid) then raise exception 'FAIL 8d: inactive location in city list'; end if;
end $$;

reset role;
rollback;
