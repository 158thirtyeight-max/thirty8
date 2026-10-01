-- =========================================================================
-- Phase 8 checks for 20260926000700_route_stops.sql
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;
create temp table t_bus (tag text, id uuid);
grant all on t_bus to authenticated;
create temp table t_city (tag text, id uuid);
grant all on t_city to authenticated;

insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (
  insert into public.locations (country_id, name)
  values ((select id from public.countries where code = 'ZZ'), 'Test Origin') returning id
) insert into t_city select 'SRC', id from c;
with c as (
  insert into public.locations (country_id, name)
  values ((select id from public.countries where code = 'ZZ'), 'Test Destination') returning id
) insert into t_city select 'DST', id from c;

-- Stops must be main locations: first = origin, last = destination, middle stops take seeded main locations.
create or replace function public.t_stops(p_src uuid, p_dst uuid, p jsonb) returns jsonb language sql stable as $f$
  select jsonb_agg(
    s.v || jsonb_build_object('city_id', case
      when s.i = 1 then p_src
      when s.i = jsonb_array_length(p) then p_dst
      else (select id from public.locations where main_route_order = s.i and is_main_route_enabled)
    end) order by s.i)
  from (select e.ordinality::int as i, e.value as v from jsonb_array_elements(p) with ordinality as e) s
$f$;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;

reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_bus select 'A1', (public.create_bus((select id from t_ops where tag = 'A'), 'Bus A1', 'AN01A0001', 'ac_seater', 40)).id;
insert into t_bus select 'A2', (public.create_bus((select id from t_ops where tag = 'A'), 'Bus A2', 'AN01A0002', 'ac_seater', 40)).id;

-- ---- 1. no route yet -> invalid ----------------------------------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1');
begin
  if (public.validate_bus_route(v_bus) ->> 'valid')::boolean then raise exception 'FAIL 1: bus without route valid'; end if;
end $$;

-- ---- 2. save a 5-stop route --------------------------------------------
do $$
declare
  v_bus uuid := (select id from t_bus where tag = 'A1');
  v_src uuid := (select id from t_city where tag = 'SRC');
  v_dst uuid := (select id from t_city where tag = 'DST');
  r jsonb; v_route uuid; n int;
begin
  r := public.save_bus_route(v_bus, v_src, v_dst, 200, '06:00', 480, '{1,2,3,4,5}', public.t_stops(v_src, v_dst, '[
    {"name":"Vijayapuram Bus Stand","is_boarding":true,"is_dropping":false,"arrival_offset_min":0,"departure_offset_min":0},
    {"name":"Bambooflat","is_boarding":true,"is_dropping":true,"arrival_offset_min":60,"departure_offset_min":65},
    {"name":"Rangat","is_boarding":true,"is_dropping":true,"arrival_offset_min":180,"departure_offset_min":190},
    {"name":"Mayabunder","is_boarding":true,"is_dropping":true,"arrival_offset_min":300,"departure_offset_min":305},
    {"name":"Diglipur","is_boarding":false,"is_dropping":true,"arrival_offset_min":480,"departure_offset_min":480}
  ]'::jsonb));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 2a: valid route rejected: %', r -> 'errors'; end if;
  v_route := (r -> 'stats' ->> 'route_id')::uuid;
  select count(*) into n from public.boarding_points where route_id = v_route and is_active;
  if n <> 4 then raise exception 'FAIL 2b: expected 4 boarding points, got %', n; end if;
  select count(*) into n from public.dropping_points where route_id = v_route and is_active;
  if n <> 4 then raise exception 'FAIL 2c: expected 4 dropping points, got %', n; end if;
  if (select status::text from public.bus_services where bus_id = v_bus) <> 'paused' then
    raise exception 'FAIL 2d: new service should start paused';
  end if;
  if (select bus_id from public.bus_routes where id = v_route) <> v_bus then
    raise exception 'FAIL 2e: route not owned by the bus';
  end if;
end $$;

-- ---- 3. re-save keeps point ids, deactivates removed stops -------------
do $$
declare
  v_bus uuid := (select id from t_bus where tag = 'A1');
  v_src uuid := (select id from t_city where tag = 'SRC');
  v_dst uuid := (select id from t_city where tag = 'DST');
  v_route uuid := (select route_id from public.bus_services where bus_id = (select id from t_bus where tag = 'A1'));
  v_rangat uuid; v_origin uuid; v_dest uuid; r jsonb; n int;
begin
  select id into v_rangat from public.boarding_points where route_id = v_route and city_id = (select id from public.locations where main_route_order = 3 and is_main_route_enabled);
  select id into v_origin from public.boarding_points where route_id = v_route and city_id = v_src;
  select id into v_dest from public.dropping_points where route_id = v_route and city_id = v_dst;
  -- drop Bambooflat and Mayabunder, keep Rangat by id
  r := public.save_bus_route(v_bus, v_src, v_dst, 200, '06:30', 480, '{1,2,3,4,5,6,7}', public.t_stops(v_src, v_dst, jsonb_build_array(
    jsonb_build_object('name','Vijayapuram Bus Stand','is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0,'boarding_point_id',v_origin),
    jsonb_build_object('name','Rangat','is_boarding',true,'is_dropping',true,'arrival_offset_min',180,'departure_offset_min',190,'boarding_point_id',v_rangat),
    jsonb_build_object('name','Diglipur','is_boarding',false,'is_dropping',true,'arrival_offset_min',480,'departure_offset_min',480,'dropping_point_id',v_dest)
  )));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 3a: %', r -> 'errors'; end if;
  if not exists (select 1 from public.boarding_points where id = v_rangat and is_active and sequence_no = 2) then
    raise exception 'FAIL 3b: Rangat point id not preserved / resequenced';
  end if;
  select count(*) into n from public.boarding_points where route_id = v_route and not is_active;
  if n <> 2 then raise exception 'FAIL 3c: removed stops should be deactivated, not deleted (got % inactive)', n; end if;
  -- a second identical save must not collide on sequence numbers
  perform public.save_bus_route(v_bus, v_src, v_dst, 200, '06:30', 480, '{1,2,3,4,5,6,7}', public.t_stops(v_src, v_dst, jsonb_build_array(
    jsonb_build_object('name','Vijayapuram Bus Stand','is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
    jsonb_build_object('name','Diglipur','is_boarding',false,'is_dropping',true,'arrival_offset_min',480,'departure_offset_min',480)
  )));
end $$;

-- ---- 4. validation errors ------------------------------------------------
do $$
declare
  v_bus uuid := (select id from t_bus where tag = 'A2');
  v_src uuid := (select id from t_city where tag = 'SRC');
  v_dst uuid := (select id from t_city where tag = 'DST');
  r jsonb;
begin
  -- overlapping times and running past the duration
  r := public.save_bus_route(v_bus, v_src, v_dst, 100, '06:00', 200, '{1}', public.t_stops(v_src, v_dst, '[
    {"name":"A","is_boarding":true,"is_dropping":false,"arrival_offset_min":0,"departure_offset_min":0},
    {"name":"B","is_boarding":true,"is_dropping":true,"arrival_offset_min":100,"departure_offset_min":120},
    {"name":"C","is_boarding":false,"is_dropping":true,"arrival_offset_min":110,"departure_offset_min":300}
  ]'::jsonb));
  if (r ->> 'valid')::boolean then raise exception 'FAIL 4a: overlapping times accepted'; end if;
  if not (r ->> 'errors') like '%before the previous stop is left%' then raise exception 'FAIL 4b: %', r -> 'errors'; end if;
  if not (r ->> 'errors') like '%past the estimated journey duration%' then raise exception 'FAIL 4c: %', r -> 'errors'; end if;

  -- structural errors raise
  begin
    perform public.save_bus_route(v_bus, v_src, v_src, 1, '06:00', 60, '{1}', '[{"name":"x","is_boarding":true},{"name":"y","is_dropping":true}]'::jsonb);
    raise exception 'FAIL 4d: same origin/destination accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 1, '06:00', 60, '{}', public.t_stops(v_src, v_dst, '[{"name":"x","is_boarding":true},{"name":"y","is_dropping":true}]'::jsonb));
    raise exception 'FAIL 4e: no operating days accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 1, '06:00', 60, '{1}', public.t_stops(v_src, v_dst, '[{"name":"x","is_boarding":false},{"name":"y","is_dropping":true}]'::jsonb));
    raise exception 'FAIL 4f: origin that is not a boarding point accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_route(v_bus, v_src, v_dst, 1, '06:00', 60, '{9}', public.t_stops(v_src, v_dst, '[{"name":"x","is_boarding":true},{"name":"y","is_dropping":true}]'::jsonb));
    raise exception 'FAIL 4g: invalid weekday accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- ---- 5. other operator cannot touch A's route --------------------------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1');
begin
  begin
    perform public.save_bus_route(v_bus, (select id from t_city where tag = 'SRC'), (select id from t_city where tag = 'DST'),
      1, '06:00', 60, '{1}', '[{"name":"x","is_boarding":true},{"name":"y","is_dropping":true}]'::jsonb);
    raise exception 'FAIL 5a: operator B saved A route';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.validate_bus_route(v_bus);
    raise exception 'FAIL 5b: operator B validated A route';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- ---- 6. two buses on the same corridor keep separate routes -----------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_a2 uuid := (select id from t_bus where tag = 'A2');
  v_src uuid := (select id from t_city where tag = 'SRC');
  v_dst uuid := (select id from t_city where tag = 'DST');
  n int;
begin
  perform public.save_bus_route(v_a2, v_src, v_dst, 200, '09:00', 400, '{1,2}', public.t_stops(v_src, v_dst, '[
    {"name":"Other Origin","is_boarding":true,"arrival_offset_min":0,"departure_offset_min":0},
    {"name":"Other Dest","is_dropping":true,"arrival_offset_min":400,"departure_offset_min":400}
  ]'::jsonb));
  select count(*) into n from public.bus_routes where source_city_id = v_src and destination_city_id = v_dst and bus_id is not null;
  if n <> 2 then raise exception 'FAIL 6: expected 2 bus-owned routes on the same corridor, got %', n; end if;
end $$;

rollback;
select 'onboarding_phase8: all assertions passed' as result;
