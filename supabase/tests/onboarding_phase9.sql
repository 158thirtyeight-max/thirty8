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

-- ---- 1. engine: most specific rule + charges --------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_seat uuid := (select s.id from public.seats s join public.bus_layouts bl on bl.id = s.bus_layout_id
                  where bl.bus_id = (select id from t_ref where tag = 'BUS') and s.seat_code = '1A');
  f integer;
begin
  f := private.calc_seat_fare(v_trip, v_seat, null, null);
  if f <> 53500 then raise exception 'FAIL 1a: base fare should be 53500 (500 + 10 + 5%%), got %', f; end if;
  f := private.calc_seat_fare(v_trip, v_seat, (select id from t_ref where tag='B_ORIGIN'), (select id from t_ref where tag='D_MID'));
  if f <> 22000 then raise exception 'FAIL 1b: Origin->Middle should be 22000, got %', f; end if;
  f := private.calc_seat_fare(v_trip, v_seat, (select id from t_ref where tag='B_MID'), (select id from t_ref where tag='D_DEST'));
  if f <> 32500 then raise exception 'FAIL 1c: Middle->Dest should be 32500, got %', f; end if;
  f := private.calc_seat_fare(v_trip, v_seat, (select id from t_ref where tag='B_ORIGIN'), (select id from t_ref where tag='D_DEST'));
  if f <> 48250 then raise exception 'FAIL 1d: destination-only fare should apply Origin->Dest: 48250, got %', f; end if;
end $$;

-- ---- 2. search == seat map == hold quote == booking --------------------
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;

do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_src uuid := (select id from t_ref where tag = 'SRC');
  v_mid uuid := (select id from t_ref where tag = 'MID');
  v_dst uuid := (select id from t_ref where tag = 'DST');
  bo uuid := (select id from t_ref where tag = 'B_ORIGIN');
  dm uuid := (select id from t_ref where tag = 'D_MID');
  res jsonb; hit jsonb; map jsonb; hold jsonb; bk jsonb; seat_ids uuid[];
  n int;
begin
  -- search Src -> Mid finds the trip through the intermediate stop, at the pair fare
  res := public.search_trips(v_src, v_mid, current_date + 2);
  select e into hit from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip;
  if hit is null then raise exception 'FAIL 2a: Src->Mid search did not find the trip'; end if;
  if (hit ->> 'min_fare_cents')::int <> 22000 or (hit ->> 'max_fare_cents')::int <> 22000 then
    raise exception 'FAIL 2b: search fare should be 22000, got %', hit;
  end if;

  -- whole-route search uses the Origin->Dest fare
  res := public.search_trips(v_src, v_dst, current_date + 2);
  select e into hit from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip;
  if (hit ->> 'min_fare_cents')::int <> 48250 then raise exception 'FAIL 2c: Src->Dst search fare, got %', hit; end if;

  -- mid -> dst
  res := public.search_trips(v_mid, v_dst, current_date + 2);
  select e into hit from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip;
  if (hit ->> 'min_fare_cents')::int <> 32500 then raise exception 'FAIL 2d: Mid->Dst search fare, got %', hit; end if;

  -- seat map for Origin -> Middle
  map := public.get_trip_seat_map(v_trip, bo, dm);
  if exists (select 1 from jsonb_array_elements(map -> 'seats') s where (s ->> 'fare_cents')::int <> 22000) then
    raise exception 'FAIL 2e: seat-map fares differ from the search fare: %', map -> 'seats';
  end if;
  -- seat map with no points -> base fare
  map := public.get_trip_seat_map(v_trip);
  if exists (select 1 from jsonb_array_elements(map -> 'seats') s where (s ->> 'fare_cents')::int <> 53500) then
    raise exception 'FAIL 2f: base-fare seat map wrong: %', map -> 'seats';
  end if;

  -- invalid point combinations are refused
  begin
    perform public.get_trip_seat_map(v_trip, bo, null);
    raise exception 'FAIL 2g: one point only accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.get_trip_seat_map(v_trip, (select id from t_ref where tag = 'D_DEST'), dm);
    raise exception 'FAIL 2h: a dropping point used as boarding accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.get_trip_seat_map(v_trip, (select id from t_ref where tag = 'B_MID'), dm);
    raise exception 'FAIL 2i: boarding == dropping stop accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- hold with points: quote equals the seat-map fare
  select array_agg((s ->> 'seat_id')::uuid) into seat_ids
  from (select s from jsonb_array_elements(public.get_trip_seat_map(v_trip, bo, dm) -> 'seats') s limit 2) x;
  hold := public.create_seat_hold(v_trip, seat_ids, 300, bo, dm);
  if (hold ->> 'total_fare_cents')::int <> 44000 then raise exception 'FAIL 2j: hold total should be 44000, got %', hold; end if;

  -- booking for different points than the hold is refused
  begin
    perform public.create_booking((hold ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
      '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"},{"full_name":"B","age":30,"gender":"female","phone":"9876543211"}]'::jsonb,
      (select id from t_ref where tag = 'B_MID'), (select id from t_ref where tag = 'D_DEST'));
    raise exception 'FAIL 2k: booking with different points accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- correct booking: item fares, total and order amount all equal the quote
  bk := public.create_booking((hold ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"},{"full_name":"B","age":30,"gender":"female","phone":"9876543211"}]'::jsonb,
    bo, dm);
  if (bk ->> 'amount_cents')::int <> 44000 then raise exception 'FAIL 2l: booking amount %', bk; end if;
  select count(*) into n from public.booking_items
  where booking_id = (bk ->> 'booking_id')::uuid and fare_cents = 22000;
  if n <> 2 then raise exception 'FAIL 2m: booking item fares are not the quoted 22000 (% match)', n; end if;
  if (select amount_cents from public.orders where id = (bk ->> 'order_id')::uuid) <> 44000 then
    raise exception 'FAIL 2n: order amount differs from booking total';
  end if;
end $$;

-- ---- 3. fare change between hold and booking -> fare_changed -----------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  bo uuid := (select id from t_ref where tag = 'B_ORIGIN');
  dm uuid := (select id from t_ref where tag = 'D_MID');
  hold jsonb; seat_ids uuid[];
begin
  select array_agg((s ->> 'seat_id')::uuid) into seat_ids
  from (select s from jsonb_array_elements(public.get_trip_seat_map(v_trip, bo, dm) -> 'seats') s where s ->> 'status' = 'available' limit 1) x;
  hold := public.create_seat_hold(v_trip, seat_ids, 300, bo, dm);
  perform set_config('t.hold', hold ->> 'hold_token', true);
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
update public.fare_rules set base_fare_cents = 25000
where service_id = (select id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'))
  and from_boarding_point_id = (select id from t_ref where tag = 'B_ORIGIN');

select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.create_booking(current_setting('t.hold')::uuid, 'c@test.invalid', '9876543210',
      '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"}]'::jsonb,
      (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
    raise exception 'FAIL 3: booking went through at a different fare than quoted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'fare_changed%' then raise exception 'FAIL 3: unexpected error %', sqlerrm; end if;
  end;
end $$;

-- ---- 4. gating: a suspended bus is neither searchable nor holdable ------
reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'suspended' where id = (select id from t_ref where tag = 'BUS');

select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  res jsonb;
begin
  res := public.search_trips((select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'), current_date + 2);
  if jsonb_array_length(res -> 'direct') <> 0 then raise exception 'FAIL 4a: suspended bus still in search'; end if;
  if public.get_trip_seat_map(v_trip) is not null then raise exception 'FAIL 4b: suspended bus still has a seat map'; end if;
  begin
    perform public.create_seat_hold(v_trip, (select array_agg(seat_id) from (select seat_id from public.trip_seats where trip_id = v_trip limit 1) z), 300);
    raise exception 'FAIL 4c: seat hold allowed on a suspended bus';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

rollback;
select 'onboarding_phase9: all assertions passed' as result;
