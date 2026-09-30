-- =========================================================================
-- Phase 13: end-to-end + regression checks
--
-- A. Existing data keeps working (needs the demo seed migration):
--    the demo operator stays approved, its bus becomes a LEGACY bus that is
--    still searchable/bookable at exactly its old fare, and is honestly
--    reported as unverified/incomplete under the new workflow.
-- B. A brand-new operator goes the whole way: onboarding -> approval ->
--    bus setup -> bus approval -> activation -> customer search/hold/booking
--    at the configured point-to-point fare.
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin@test.invalid'),
  ('dddddddd-0000-0000-0000-00000000000d', 'cust@test.invalid');
insert into public.user_roles (user_id, role) values ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin');

create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;

-- =====================  A. legacy / existing data  =====================
do $$
declare
  v_op public.operators;
  v_bus public.buses;
begin
  select * into v_op from public.operators where name = 'Andaman Express (Demo)';
  if v_op.id is null then
    raise notice 'A: demo seed not present, skipping the legacy regression block';
    return;
  end if;
  if v_op.application_status <> 'approved' or v_op.status <> 'approved' then
    raise exception 'FAIL A1: demo operator not preserved as approved (% / %)', v_op.status, v_op.application_status;
  end if;

  select * into v_bus from public.buses where operator_id = v_op.id order by created_at limit 1;
  if not v_bus.is_legacy or v_bus.lifecycle_status <> 'active' then
    raise exception 'FAIL A2: demo bus should be legacy + active, got legacy=% lifecycle=%', v_bus.is_legacy, v_bus.lifecycle_status;
  end if;
  if v_bus.approved_by is not null or v_bus.reviewed_by is not null then
    raise exception 'FAIL A3: legacy bus was stamped as reviewed';
  end if;
  if not private.is_bus_bookable(v_bus.id) then raise exception 'FAIL A4: demo bus is no longer bookable'; end if;
  insert into t_ref values ('DEMO_BUS', v_bus.id);
  insert into t_ref select 'DEMO_TRIP', id from public.bus_trips where bus_id = v_bus.id order by travel_date limit 1;
  insert into t_ref select 'DEMO_SRC', service_source_city_id from public.bus_services where bus_id = v_bus.id limit 1;
  insert into t_ref select 'DEMO_DST', service_dest_city_id from public.bus_services where bus_id = v_bus.id limit 1;
end $$;

select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'DEMO_TRIP');
  res jsonb; hit jsonb; hold jsonb; bk jsonb; seat_ids uuid[]; n int;
  v_bp uuid; v_dp uuid;
begin
  if v_trip is null then return; end if;

  -- old fare, unchanged: 450.00, no charges configured
  res := public.search_trips((select id from t_ref where tag = 'DEMO_SRC'), (select id from t_ref where tag = 'DEMO_DST'),
                             (select travel_date from public.bus_trips where id = v_trip));
  select e into hit from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip;
  if hit is null then raise exception 'FAIL A5: demo trip not found by search'; end if;
  if (hit ->> 'min_fare_cents')::int <> 45000 or (hit ->> 'max_fare_cents')::int <> 45000 then
    raise exception 'FAIL A6: legacy fare changed: %', hit;
  end if;
  if exists (select 1 from jsonb_array_elements(public.get_trip_seat_map(v_trip) -> 'seats') s where (s ->> 'fare_cents')::int <> 45000) then
    raise exception 'FAIL A7: legacy seat-map fare changed';
  end if;

  -- old client flow: hold WITHOUT points, book WITH points (the previous app behaviour)
  select array_agg((s ->> 'seat_id')::uuid) into seat_ids
  from (select s from jsonb_array_elements(public.get_trip_seat_map(v_trip) -> 'seats') s limit 2) x;
  hold := public.create_seat_hold(v_trip, seat_ids, 300);
  select id into v_bp from public.boarding_points where route_id = (select route_id from public.bus_trips where id = v_trip) limit 1;
  select id into v_dp from public.dropping_points where route_id = (select route_id from public.bus_trips where id = v_trip) limit 1;
  bk := public.create_booking((hold ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"},{"full_name":"B","age":31,"gender":"female","phone":"9876543211"}]'::jsonb, v_bp, v_dp);
  if (bk ->> 'amount_cents')::int <> 90000 then raise exception 'FAIL A8: legacy booking amount %', bk; end if;

  -- new client flow: hold WITH points
  select array_agg((s ->> 'seat_id')::uuid) into seat_ids
  from (select s from jsonb_array_elements(public.get_trip_seat_map(v_trip, v_bp, v_dp) -> 'seats') s where s ->> 'status' = 'available' limit 1) x;
  hold := public.create_seat_hold(v_trip, seat_ids, 300, v_bp, v_dp);
  if (hold ->> 'total_fare_cents')::int <> 45000 then raise exception 'FAIL A9: hold with legacy points priced %', hold; end if;
  bk := public.create_booking((hold ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"C","age":30,"gender":"male","phone":"9876543210"}]'::jsonb, v_bp, v_dp);
  if (bk ->> 'amount_cents')::int <> 45000 then raise exception 'FAIL A10: booking %', bk; end if;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);

-- honest status: incomplete under the new workflow, but not blocked from running
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'DEMO_BUS'); r jsonb;
begin
  if v_bus is null then return; end if;
  if public.bus_verification_state(v_bus) <> 'legacy' then raise exception 'FAIL A11: demo bus not reported as legacy'; end if;
  r := public.bus_completeness(v_bus);
  if (r ->> 'complete')::boolean then raise exception 'FAIL A12: legacy bus reported complete without documents/photos'; end if;
  begin
    perform public.admin_review_bus(v_bus, 'approve');
    raise exception 'FAIL A13: legacy bus approved without being submitted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- =====================  B. new operator, whole journey  =====================
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (insert into public.cities (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'E Src') returning id) insert into t_ref select 'SRC', id from c;
with c as (insert into public.cities (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'E Mid') returning id) insert into t_ref select 'MID', id from c;
with c as (insert into public.cities (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'E Dst') returning id) insert into t_ref select 'DST', id from c;

-- B1. operator registers and completes phase 1 of onboarding
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'OP', (public.register_operator('Journey Travels', 'Journey Travels Pvt Ltd', 'bus', 'j@test.invalid', '9876543210')).id;

do $$
declare v_id uuid := (select id from t_ref where tag = 'OP');
begin
  -- a not-yet-approved operator cannot create buses
  begin
    perform public.create_bus(v_id, 'Early', 'AN01E0001', 'ac_seater', 2);
    raise exception 'FAIL B1: unapproved operator created a bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  insert into public.operator_profiles (operator_id, owner_name, address, city, district, state, pin_code)
  values (v_id, 'Owner', '1 Main St', 'Port Blair', 'South Andaman', 'Andaman and Nicobar Islands', '744101');
  insert into public.operator_kyc (operator_id, pan_number, gst_registered) values (v_id, 'ABCDE1234F', false);
  insert into public.operator_bank_details (operator_id, account_holder_name, bank_name, branch_name, account_number, ifsc, account_type)
  values (v_id, 'Journey Travels Pvt Ltd', 'SBI', 'Port Blair', '123456789012', 'SBIN0001234', 'current');
  insert into public.operator_documents (operator_id, doc_type, file_path) values
    (v_id, 'pan_card', v_id || '/pan.pdf'), (v_id, 'id_proof', v_id || '/id.pdf'), (v_id, 'cancelled_cheque', v_id || '/chq.pdf');
  insert into public.operator_payment_mandates (operator_id, file_path) values (v_id, v_id || '/m.pdf');
  if (public.operator_completeness(v_id) ->> 'percent')::int <> 100 then raise exception 'FAIL B2: operator not 100%%'; end if;
  perform public.submit_operator_application(v_id);
end $$;

-- B2. admin verifies and approves the operator
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ref where tag = 'OP'); d record;
begin
  perform public.admin_review_operator(v_id, 'start_review');
  for d in select id from public.operator_documents where operator_id = v_id loop
    perform public.admin_review_operator_document(d.id, 'verify');
  end loop;
  perform public.admin_review_mandate(v_id, 'verify');
  if (public.admin_review_operator(v_id, 'approve')).status <> 'approved' then raise exception 'FAIL B3: operator not approved'; end if;
end $$;

-- B3. approved operator sets up a bus, stage by stage
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'BUS', (public.create_bus((select id from t_ref where tag = 'OP'), 'Journey One', 'AN01J0001', 'ac_seater', 3, 'Tata', 'Starbus', 2022, 2022)).id;

do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); r jsonb;
begin
  perform public.save_bus_layout(v_bus, '{"rows":2,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"},
    {"seat_code":"DRV","deck":1,"row_no":2,"col_no":3,"seat_type":"seater","kind":"crew"}]'::jsonb);
  perform public.save_bus_route(v_bus, (select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'),
    100, '06:00', 240, '{1,2,3,4,5,6,7}', jsonb_build_array(
      jsonb_build_object('name','Origin','city_id',(select id from t_ref where tag='SRC'),'is_boarding',true,'is_dropping',false,'arrival_offset_min',0,'departure_offset_min',0),
      jsonb_build_object('name','Middle','city_id',(select id from t_ref where tag='MID'),'is_boarding',true,'is_dropping',true,'arrival_offset_min',120,'departure_offset_min',125),
      jsonb_build_object('name','Dest','city_id',(select id from t_ref where tag='DST'),'is_boarding',false,'is_dropping',true,'arrival_offset_min',240,'departure_offset_min',240)));
  perform public.save_bus_schedule(v_bus, '06:00', '{1,2,3,4,5,6,7}', 30, 30, 10);
  update public.buses set exterior_photo_path = 'x/e.jpg', interior_photo_path = 'x/i.jpg' where id = v_bus;
  insert into public.bus_documents (bus_id, doc_type, file_path, expiry_date) values
    (v_bus, 'rc', 'x/rc.pdf', null), (v_bus, 'insurance', 'x/i.pdf', current_date + 200), (v_bus, 'fitness', 'x/f.pdf', current_date + 200),
    (v_bus, 'permit', 'x/p.pdf', current_date + 200), (v_bus, 'puc', 'x/u.pdf', current_date + 200);
end $$;

insert into t_ref select 'B_ORIGIN', id from public.boarding_points where name = 'Origin' and route_id = (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));
insert into t_ref select 'D_MID', id from public.dropping_points where name = 'Middle' and route_id = (select route_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'));

do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); r jsonb; b public.buses;
begin
  -- fares: base 500, Origin -> Middle 200, plus a 5% charge
  r := public.save_bus_fares(v_bus, jsonb_build_array(
      jsonb_build_object('seat_type','seater','base_fare_cents',50000),
      jsonb_build_object('seat_type','seater','base_fare_cents',20000,'from_point_id',(select id from t_ref where tag='B_ORIGIN'),'to_point_id',(select id from t_ref where tag='D_MID'))),
    '[{"name":"GST","kind":"percent","percent":5}]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL B4: %', r -> 'errors'; end if;

  r := public.bus_completeness(v_bus);
  if not (r ->> 'complete')::boolean then raise exception 'FAIL B5: bus not complete: %', r -> 'missing'; end if;
  b := public.submit_bus(v_bus);
  if b.lifecycle_status <> 'submitted' then raise exception 'FAIL B6'; end if;
end $$;

-- B4. admin reviews the bus
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); d record;
begin
  perform public.admin_review_bus(v_bus, 'start_review');
  for d in select id from public.bus_documents where bus_id = v_bus loop
    perform public.admin_review_bus_document(d.id, 'verify');
  end loop;
  if (public.admin_review_bus(v_bus, 'approve')).lifecycle_status <> 'approved' then raise exception 'FAIL B7: bus not approved'; end if;
end $$;

-- B5. operator activates; trips are generated from the schedule
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); n int;
begin
  perform public.activate_bus(v_bus);
  n := public.generate_bus_trips(v_bus, current_date + 1, current_date + 3);
  if n <> 3 then raise exception 'FAIL B8: expected 3 trips, got %', n; end if;
end $$;

-- B6. customer searches, holds and books at the configured stop-to-stop fare
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_bus uuid := (select id from t_ref where tag = 'BUS');
  v_trip uuid;
  res jsonb; hit jsonb; hold jsonb; bk jsonb; seat_ids uuid[];
  bo uuid := (select id from t_ref where tag = 'B_ORIGIN');
  dm uuid := (select id from t_ref where tag = 'D_MID');
begin
  select id into v_trip from public.bus_trips where bus_id = v_bus order by travel_date limit 1;
  res := public.search_trips((select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'MID'), (select travel_date from public.bus_trips where id = v_trip));
  select e into hit from jsonb_array_elements(res -> 'direct') e where (e ->> 'trip_id')::uuid = v_trip;
  if hit is null then raise exception 'FAIL B9: new bus not searchable after activation'; end if;
  if (hit ->> 'min_fare_cents')::int <> 21000 then raise exception 'FAIL B10: expected 21000 (200 + 5%%), got %', hit; end if;

  select array_agg((s ->> 'seat_id')::uuid) into seat_ids
  from (select s from jsonb_array_elements(public.get_trip_seat_map(v_trip, bo, dm) -> 'seats') s limit 2) x;
  if jsonb_array_length(public.get_trip_seat_map(v_trip) -> 'seats') <> 3 then
    raise exception 'FAIL B11: only bookable seats should be on the trip (crew position excluded)';
  end if;
  hold := public.create_seat_hold(v_trip, seat_ids, 300, bo, dm);
  bk := public.create_booking((hold ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"A","age":30,"gender":"male","phone":"9876543210"},{"full_name":"B","age":30,"gender":"female","phone":"9876543211"}]'::jsonb, bo, dm);
  if (bk ->> 'amount_cents')::int <> 42000 then raise exception 'FAIL B12: booking amount %', bk; end if;
end $$;

-- B7. suspending the operator hides everything, reinstating restores it
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
select public.admin_review_operator((select id from t_ref where tag = 'OP'), 'suspend', 'Compliance check');
reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  if private.is_bus_bookable((select id from t_ref where tag = 'BUS')) then raise exception 'FAIL B13: suspended operator bus still bookable'; end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
select public.admin_review_operator((select id from t_ref where tag = 'OP'), 'reinstate');
reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  if not private.is_bus_bookable((select id from t_ref where tag = 'BUS')) then raise exception 'FAIL B14: reinstated operator bus not restored'; end if;
end $$;

rollback;
select 'onboarding_e2e: all assertions passed' as result;
