-- =========================================================================
-- Phase 10 checks for 20260926000900_schedule.sql
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;
create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;

insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (insert into public.cities (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'S Src') returning id)
  insert into t_ref select 'SRC', id from c;
with c as (insert into public.cities (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'S Dst') returning id)
  insert into t_ref select 'DST', id from c;

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
insert into t_ref select 'BUS', (public.create_bus((select id from t_ops where tag = 'A'), 'Sched Bus', 'AN01S0001', 'ac_seater', 2)).id;

do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); r jsonb;
begin
  -- no route yet
  if (public.validate_bus_schedule(v_bus) ->> 'valid')::boolean then raise exception 'FAIL 1a: schedule valid without a route'; end if;

  perform public.save_bus_layout(v_bus, '{"rows":1,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"}]'::jsonb);
  perform public.save_bus_route(v_bus, (select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'),
    50, '07:00', 120, '{1,2,3,4,5,6,7}', '[
      {"name":"A","is_boarding":true,"is_dropping":false,"arrival_offset_min":0,"departure_offset_min":0},
      {"name":"B","is_boarding":false,"is_dropping":true,"arrival_offset_min":120,"departure_offset_min":120}]'::jsonb);

  -- route exists but the schedule was never confirmed
  r := public.validate_bus_schedule(v_bus);
  if (r ->> 'valid')::boolean or not (r ->> 'errors') like '%not been confirmed%' then
    raise exception 'FAIL 1b: unconfirmed schedule not reported: %', r;
  end if;

  -- save
  r := public.save_bus_schedule(v_bus, '08:30', '{1,2,3,4,5}', 45, 30, 10);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 2a: valid schedule rejected: %', r -> 'errors'; end if;
  if (select default_departure_time::text from public.bus_services where bus_id = v_bus) <> '08:30:00' then
    raise exception 'FAIL 2b: departure not saved';
  end if;

  -- invalid inputs
  begin
    perform public.save_bus_schedule(v_bus, '08:30', '{}', 45, 30, 10);
    raise exception 'FAIL 3a: no operating days accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_schedule(v_bus, '08:30', '{1}', 0, 30, 10);
    raise exception 'FAIL 3b: booking window of 0 days accepted';
  exception when check_violation then null; end;
  begin
    perform public.save_bus_schedule(v_bus, '08:30', '{1}', 30, -5, 10);
    raise exception 'FAIL 3c: negative cut-off accepted';
  exception when check_violation then null; end;
  begin
    perform public.save_bus_schedule(v_bus, '08:30', '{8}', 30, 30, 10);
    raise exception 'FAIL 3d: weekday 8 accepted';
  exception when check_violation then null; end;
end $$;

-- ---- 4. trips can only be generated for an active bus -------------------
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS');
begin
  begin
    perform public.generate_bus_trips(v_bus, current_date + 1, current_date + 7);
    raise exception 'FAIL 4: trips generated for a draft bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'active' where id = (select id from t_ref where tag = 'BUS');
update public.bus_services set status = 'active' where bus_id = (select id from t_ref where tag = 'BUS');

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_bus uuid := (select id from t_ref where tag = 'BUS');
  v_from date := current_date + 1;
  v_to date := current_date + 14;
  v_expected int;
  n int;
begin
  select count(*) into v_expected from generate_series(v_from, v_to, interval '1 day') d
  where extract(isodow from d) between 1 and 5;

  n := public.generate_bus_trips(v_bus, v_from, v_to);
  if n <> v_expected then raise exception 'FAIL 5a: expected % weekday trips, created %', v_expected, n; end if;

  -- idempotent
  if public.generate_bus_trips(v_bus, v_from, v_to) <> 0 then raise exception 'FAIL 5b: second run created duplicates'; end if;

  -- no weekend trips; trip window matches the schedule
  if exists (select 1 from public.bus_trips where bus_id = v_bus and extract(isodow from travel_date) in (6, 7)) then
    raise exception 'FAIL 5c: trip generated on a non-operating day';
  end if;
  if exists (
    select 1 from public.bus_trips t
    where t.bus_id = v_bus
      and (t.booking_close_at <> t.departure_at - interval '30 minutes'
           or t.arrival_at <> t.departure_at + interval '120 minutes'
           or (t.departure_at at time zone 'Asia/Kolkata')::time <> time '08:30')
  ) then
    raise exception 'FAIL 5d: trip times do not follow the schedule';
  end if;

  -- trip inventory exists for the generated trips
  if exists (select 1 from public.bus_trips t where t.bus_id = v_bus and t.available_seats <> 2) then
    raise exception 'FAIL 5e: generated trips do not have both bookable seats';
  end if;

  begin
    perform public.generate_bus_trips(v_bus, v_from, v_from + 200);
    raise exception 'FAIL 5f: 200-day range accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- ---- 6. another operator cannot generate/alter -------------------------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS');
begin
  begin
    perform public.generate_bus_trips(v_bus, current_date + 1, current_date + 3);
    raise exception 'FAIL 6a: operator B generated trips for A';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.save_bus_schedule(v_bus, '10:00', '{1}', 30, 0, 0);
    raise exception 'FAIL 6b: operator B changed A schedule';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

rollback;
select 'onboarding_phase10: all assertions passed' as result;
