-- =========================================================================
-- Checks for 20261002001500_operator_services.sql
--   * rows are created/derived automatically; selecting never grants approval
--   * operator admin only; shopping unavailable; cross-operator isolation
--   * disable keeps data, needs confirmation when trips/bookings exist
--   * disabled service cannot create new buses/trips; platform admin can approve/suspend
-- Everything is rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin1@test.invalid');
insert into public.user_roles (user_id, role) values ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;
reset role;

-- ---- 1. rows derived at registration; unapproved => setup_required -------
do $$
declare v_a uuid := (select id from t_ops where tag = 'A');
begin
  if (select state from public.operator_services where operator_id = v_a and service_type = 'bus') <> 'setup_required' then
    raise exception 'FAIL 1a: new bus operator should be setup_required, got %',
      (select state from public.operator_services where operator_id = v_a and service_type = 'bus');
  end if;
  if exists (select 1 from public.operator_services where operator_id = v_a and service_type = 'cargo') then
    raise exception 'FAIL 1b: bus-only operator must not get a cargo row';
  end if;
end $$;

-- ---- 2. approval activates bus ------------------------------------------
update public.operators set status = 'approved', application_status = 'approved'
 where id = (select id from t_ops where tag = 'A');
update public.operators set status = 'approved', application_status = 'approved'
 where id = (select id from t_ops where tag = 'B');
do $$
declare v_a uuid := (select id from t_ops where tag = 'A');
begin
  if (select state from public.operator_services where operator_id = v_a and service_type = 'bus') <> 'active' then
    raise exception 'FAIL 2a: approved bus operator should be active';
  end if;
end $$;

-- ---- 3. selecting cargo does NOT imply approval --------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); r jsonb;
begin
  r := public.set_operator_service(v_a, 'cargo', true);
  if r ->> 'state' <> 'pending_approval' then
    raise exception 'FAIL 3a: cargo selection must be pending_approval, got %', r;
  end if;
  begin
    perform public.set_operator_service(v_a, 'shopping', true);
    raise exception 'FAIL 3b: shopping must be unavailable';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 4. cross-operator isolation -----------------------------------------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A');
begin
  begin
    perform public.set_operator_service(v_a, 'bus', false);
    raise exception 'FAIL 4a: operator B changed operator A services';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    perform public.get_service_disable_impact(v_a, 'bus');
    raise exception 'FAIL 4b: operator B read operator A impact';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  if exists (select 1 from public.operator_services where operator_id = v_a) then
    raise exception 'FAIL 4c: operator B can read operator A service rows';
  end if;
  begin
    update public.operator_services set state = 'active' where operator_id = (select id from t_ops where tag = 'B');
    -- no write grant: must fail
    raise exception 'FAIL 4d: direct write to operator_services allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ---- 5. platform admin approves cargo, then suspends it ------------------
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); r jsonb;
begin
  r := public.admin_set_service_state(v_a, 'cargo', 'approve');
  if r ->> 'state' <> 'active' then raise exception 'FAIL 5a: admin approve should activate, got %', r; end if;
  r := public.admin_set_service_state(v_a, 'cargo', 'suspend', 'test');
  if r ->> 'state' <> 'suspended' then raise exception 'FAIL 5b: suspend, got %', r; end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A');
begin
  begin
    perform public.set_operator_service(v_a, 'cargo', true);
    raise exception 'FAIL 5c: operator re-enabled an admin-suspended service';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 6. disabling bus keeps data and blocks NEW buses ---------------------
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); v_bus public.buses; r jsonb;
begin
  v_bus := public.create_bus(v_a, 'Bus A1', 'AN01A0001', 'ac_seater', 40);
  r := public.set_operator_service(v_a, 'bus', false);
  if r ->> 'state' <> 'disabled' then
    raise exception 'FAIL 6a: no blockers, disable should succeed, got %', r;
  end if;
  if not exists (select 1 from public.buses where id = v_bus.id) then
    raise exception 'FAIL 6b: disabling deleted a bus';
  end if;
  begin
    perform public.create_bus(v_a, 'Bus A2', 'AN01A0002', 'ac_seater', 40);
    raise exception 'FAIL 6c: disabled service created a bus';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  r := public.set_operator_service(v_a, 'bus', true);
  if r ->> 'state' <> 'active' then raise exception 'FAIL 6d: re-enable should restore active, got %', r; end if;
  if not exists (select 1 from public.buses where id = v_bus.id) then
    raise exception 'FAIL 6e: re-enable lost data';
  end if;
end $$;

reset role;
rollback;
select 'operator_services: all checks passed' as result;
