-- =========================================================================
-- Phase 5 checks for 20260926000400_bus_lifecycle_and_create.sql
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

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;

-- Approve operator A only (B stays a draft/pending applicant).
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved'
where id = (select id from t_ops where tag = 'A');

-- ---- 1. unapproved operator cannot create buses -----------------------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_b uuid := (select id from t_ops where tag = 'B');
begin
  begin
    perform public.create_bus(v_b, 'Bus B', 'AN01B0001', 'ac_seater', 40);
    raise exception 'FAIL 1a: unapproved operator created a bus via RPC';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    insert into public.buses (operator_id, registration_number, bus_type, total_seats)
    values (v_b, 'AN01B0002', 'ac_seater', 40);
    raise exception 'FAIL 1b: unapproved operator inserted a bus directly';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 2. approved operator: RPC works, direct insert does not ----------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); v_bus public.buses;
begin
  v_bus := public.create_bus(v_a, 'Bus A1', ' an01a0001 ', 'ac_seater', 40, 'Tata', 'Starbus', 2022, 2022);
  insert into t_bus values ('A1', v_bus.id);
  if v_bus.lifecycle_status <> 'draft' or v_bus.is_legacy then
    raise exception 'FAIL 2a: new bus must be a non-legacy draft (% / %)', v_bus.lifecycle_status, v_bus.is_legacy;
  end if;
  if v_bus.registration_number <> 'AN01A0001' then
    raise exception 'FAIL 2b: registration number not normalized: %', v_bus.registration_number;
  end if;
  if public.bus_verification_state(v_bus.id) <> 'unverified' then
    raise exception 'FAIL 2c: new bus should be unverified';
  end if;

  begin
    insert into public.buses (operator_id, registration_number, bus_type, total_seats)
    values (v_a, 'AN01A0002', 'ac_seater', 40);
    raise exception 'FAIL 2d: approved operator inserted a bus directly (bypassing create_bus)';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  begin
    perform public.create_bus(v_a, 'Dup', 'AN01A0001', 'ac_seater', 40);
    raise exception 'FAIL 2e: duplicate registration accepted';
  exception when unique_violation then null; end;

  begin
    perform public.create_bus(v_a, 'Big', 'AN01A0009', 'ac_seater', 500);
    raise exception 'FAIL 2f: 500 seats accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 3. operator cannot self-approve / activate a bus -----------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1');
begin
  begin
    update public.buses set lifecycle_status = 'active' where id = v_bus;
    raise exception 'FAIL 3a: operator activated own bus';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    update public.buses set is_legacy = true where id = v_bus;
    raise exception 'FAIL 3b: operator flagged own bus legacy';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    update public.buses set approved_by = auth.uid() where id = v_bus;
    raise exception 'FAIL 3c: operator set approved_by';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  update public.buses set model = 'Starbus 2', name = 'Renamed' where id = v_bus; -- draft: editable
end $$;

-- ---- 4. core details lock once out of draft ---------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'under_review' where id = (select id from t_bus where tag = 'A1');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1');
begin
  begin
    update public.buses set total_seats = 60 where id = v_bus;
    raise exception 'FAIL 4: core details editable while under review';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 5. drafts / in-review buses are not publicly readable ------------
reset role;
select set_config('request.jwt.claims', '', true);
set local role anon;
do $$
declare n int;
begin
  select count(*) into n from public.buses where registration_number = 'AN01A0001';
  if n <> 0 then raise exception 'FAIL 5: anon can read an under-review bus'; end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---- 6. legacy: existing buses flagged, never stamped approved --------
do $$
declare n int;
begin
  select count(*) into n from public.buses where is_legacy and (approved_by is not null or reviewed_by is not null);
  if n <> 0 then raise exception 'FAIL 6a: % legacy buses carry review/approval stamps', n; end if;
  select count(*) into n from public.buses where is_legacy and lifecycle_status <> 'active';
  if n <> 0 then raise exception 'FAIL 6b: % legacy buses are not active', n; end if;
end $$;

rollback;
select 'onboarding_phase5: all assertions passed' as result;
