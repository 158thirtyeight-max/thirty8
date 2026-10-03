-- =========================================================================
-- Phase 3 checks for 20260926000200_operator_bank_mandate.sql
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;

-- ---- 1. bank constraints ----------------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A');
begin
  begin
    insert into public.operator_bank_details (operator_id, account_number) values (v_id, '12345');
    raise exception 'FAIL 1a: short account number accepted';
  exception when check_violation then null; end;
  begin
    insert into public.operator_bank_details (operator_id, account_number) values (v_id, '12345678901234567890');
    raise exception 'FAIL 1b: 20-digit account number accepted';
  exception when check_violation then null; end;
  begin
    insert into public.operator_bank_details (operator_id, ifsc) values (v_id, 'SBIN1234567');
    raise exception 'FAIL 1c: IFSC without 0 in 5th position accepted';
  exception when check_violation then null; end;
  begin
    insert into public.operator_bank_details (operator_id, ifsc) values (v_id, 'sbin0001234');
    raise exception 'FAIL 1d: lowercase IFSC accepted';
  exception when check_violation then null; end;
  begin
    insert into public.operator_bank_details (operator_id, micr) values (v_id, '12345');
    raise exception 'FAIL 1e: bad MICR accepted';
  exception when check_violation then null; end;
  begin
    insert into public.operator_bank_details (operator_id, account_type) values (v_id, 'wallet');
    raise exception 'FAIL 1f: bad account type accepted';
  exception when check_violation then null; end;

  insert into public.operator_bank_details
    (operator_id, account_holder_name, bank_name, branch_name, bank_address, account_number, ifsc, micr, account_type)
  values (v_id, 'Op A Pvt Ltd', 'State Bank of India', 'Port Blair', 'Aberdeen Bazaar', '123456789012', 'SBIN0001234', '744002001', 'current');
end $$;

-- ---- 2. tenant isolation ----------------------------------------------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); n int;
begin
  select count(*) into n from public.operator_bank_details where operator_id = v_a;
  if n <> 0 then raise exception 'FAIL 2a: operator B can read A bank details'; end if;
  begin
    insert into public.operator_payment_mandates (operator_id, file_path) values (v_a, v_a || '/m.pdf');
    raise exception 'FAIL 2b: operator B inserted a mandate for A';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 3. mandate verification is admin-only ----------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); v_status text; v_ver int;
begin
  insert into public.operator_payment_mandates (operator_id, file_path, file_name, status)
  values (v_id, v_id || '/m1.pdf', 'm.pdf', 'verified')
  returning status into v_status;
  if v_status <> 'pending' then raise exception 'FAIL 3a: mandate inserted as %', v_status; end if;

  begin
    update public.operator_payment_mandates set status = 'verified' where operator_id = v_id;
    raise exception 'FAIL 3b: operator verified own mandate';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  update public.operator_payment_mandates set file_path = v_id || '/m2.pdf' where operator_id = v_id
  returning version into v_ver;
  if v_ver <> 2 then raise exception 'FAIL 3c: replacing mandate should bump version, got %', v_ver; end if;
end $$;

-- ---- 4. completeness includes bank + mandate --------------------------
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); r jsonb;
begin
  r := public.operator_completeness(v_id);
  if (r -> 'missing') ? 'Cancelled cheque' then
    raise exception 'FAIL 4a: cancelled cheque is no longer required: %', r -> 'missing';
  end if;
  if (r -> 'missing') ? 'Signed & stamped payment mandate' then
    raise exception 'FAIL 4b: mandate uploaded but reported missing';
  end if;
  if (r -> 'missing') ? 'Account number' or (r -> 'missing') ? 'IFSC' then
    raise exception 'FAIL 4c: saved bank fields reported missing';
  end if;

end $$;

-- ---- 5. a rejected mandate counts as missing --------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.operator_payment_mandates set status = 'rejected', rejection_reason = 'Unsigned'
where operator_id = (select id from t_ops where tag = 'A');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); r jsonb;
begin
  r := public.operator_completeness(v_id);
  if not (r -> 'missing') ? 'Signed & stamped payment mandate' then
    raise exception 'FAIL 5: rejected mandate should count as missing';
  end if;
end $$;

-- ---- 6. requirement is admin-configurable ------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.document_requirements set required = false where scope = 'operator' and doc_type = 'payment_mandate';
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); r jsonb;
begin
  r := public.operator_completeness(v_id);
  if (r -> 'missing') ? 'Signed & stamped payment mandate' then
    raise exception 'FAIL 6: mandate no longer required but still reported missing';
  end if;
end $$;

rollback;
select 'onboarding_phase3: all assertions passed' as result;
