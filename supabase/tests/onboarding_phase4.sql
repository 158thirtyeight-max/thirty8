-- =========================================================================
-- Phase 4 checks for 20260926000300_operator_approval_workflow.sql
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- Needs one platform admin user, created here.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin@test.invalid');
insert into public.user_roles (user_id, role) values ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;

-- Operator A: fully filled application (all sections), GST not registered.
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A');
begin
  -- 1. incomplete application cannot be submitted
  begin
    perform public.submit_operator_application(v_id);
    raise exception 'FAIL 1: incomplete application submitted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  insert into public.operator_profiles (operator_id, owner_name, address, city, district, state, pin_code)
  values (v_id, 'Owner', '1 Main St', 'Port Blair', 'South Andaman', 'Andaman and Nicobar Islands', '744101');
  insert into public.operator_kyc (operator_id, pan_number, gst_registered) values (v_id, 'ABCDE1234F', false);
  insert into public.operator_bank_details
    (operator_id, account_holder_name, bank_name, branch_name, account_number, ifsc, account_type)
  values (v_id, 'Op A Pvt Ltd', 'SBI', 'Port Blair', '123456789012', 'SBIN0001234', 'current');
  insert into public.operator_documents (operator_id, doc_type, file_path) values
    (v_id, 'pan_card', v_id || '/pan.pdf'),
    (v_id, 'id_proof', v_id || '/id.pdf'),
    (v_id, 'cancelled_cheque', v_id || '/chq.pdf');
  insert into public.operator_payment_mandates (operator_id, file_path) values (v_id, v_id || '/m.pdf');
end $$;

-- 2. another operator cannot submit A's application
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A');
begin
  begin
    perform public.submit_operator_application(v_a);
    raise exception 'FAIL 2: operator B submitted A application';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- 3. A submits
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); v_status text;
begin
  select application_status::text into v_status from public.submit_operator_application(v_id);
  if v_status <> 'submitted' then raise exception 'FAIL 3a: expected submitted, got %', v_status; end if;
  begin
    perform public.submit_operator_application(v_id);
    raise exception 'FAIL 3b: double submit allowed';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    perform public.admin_review_operator(v_id, 'approve');
    raise exception 'FAIL 3c: operator approved own application via RPC';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- 4. admin flow
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); v_status text; v_doc uuid;
begin
  select application_status::text into v_status from public.admin_review_operator(v_id, 'start_review');
  if v_status <> 'under_review' then raise exception 'FAIL 4a: expected under_review, got %', v_status; end if;

  -- pending documents block approval
  begin
    perform public.admin_review_operator(v_id, 'approve');
    raise exception 'FAIL 4b: approved with unverified documents';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  -- reason is mandatory
  begin
    perform public.admin_review_operator(v_id, 'request_changes', '  ');
    raise exception 'FAIL 4c: changes requested without a reason';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    perform public.admin_review_operator_document((select id from public.operator_documents where operator_id = v_id and doc_type = 'pan_card'), 'reject');
    raise exception 'FAIL 4d: document rejected without a reason';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  -- request changes
  select application_status::text into v_status from public.admin_review_operator(v_id, 'request_changes', 'PAN scan is blurry');
  if v_status <> 'changes_requested' then raise exception 'FAIL 4e: got %', v_status; end if;
  if (select review_reason from public.operators where id = v_id) <> 'PAN scan is blurry' then
    raise exception 'FAIL 4f: reason not stored';
  end if;
end $$;

-- 5. operator can edit again, resubmit
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); v_status text;
begin
  update public.operator_profiles set city = 'Port Blair (edited)' where operator_id = v_id;
  select application_status::text into v_status from public.submit_operator_application(v_id);
  if v_status <> 'submitted' then raise exception 'FAIL 5a: resubmit got %', v_status; end if;
  if (select review_reason from public.operators where id = v_id) is not null then
    raise exception 'FAIL 5b: stale review reason not cleared on resubmit';
  end if;
end $$;

-- 6. verify everything then approve
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); r record; v_op public.operators;
begin
  for r in select id from public.operator_documents where operator_id = v_id loop
    perform public.admin_review_operator_document(r.id, 'verify');
  end loop;
  perform public.admin_review_mandate(v_id, 'verify');
  v_op := public.admin_review_operator(v_id, 'approve');
  if v_op.status <> 'approved' or v_op.application_status <> 'approved' then
    raise exception 'FAIL 6a: not approved (% / %)', v_op.status, v_op.application_status;
  end if;
  if v_op.approved_by <> 'cccccccc-0000-0000-0000-00000000000c' or v_op.approved_at is null then
    raise exception 'FAIL 6b: approver / timestamp not recorded';
  end if;

  -- suspend / reinstate
  begin
    perform public.admin_review_operator(v_id, 'suspend');
    raise exception 'FAIL 6c: suspended without reason';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  v_op := public.admin_review_operator(v_id, 'suspend', 'Compliance check');
  if v_op.status <> 'suspended' then raise exception 'FAIL 6d: not suspended'; end if;
  v_op := public.admin_review_operator(v_id, 'reinstate');
  if v_op.status <> 'approved' then raise exception 'FAIL 6e: not reinstated'; end if;
end $$;

-- 7. audit trail written with actor + reasons
reset role;
select set_config('request.jwt.claims', '', true);
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); n int;
begin
  select count(*) into n from public.audit_logs
  where (entity_id = v_id or after ->> 'operator_id' = v_id::text)
    and action in ('operator.submitted', 'operator.start_review', 'operator.request_changes',
                   'operator.approve', 'operator.suspend', 'operator.reinstate')
    and actor_profile_id is not null;
  if n < 7 then raise exception 'FAIL 7a: expected >= 7 audit rows for the workflow, got %', n; end if;
  if not exists (select 1 from public.audit_logs where action = 'operator.request_changes'
                 and after ->> 'reason' = 'PAN scan is blurry') then
    raise exception 'FAIL 7b: change-request reason missing from audit';
  end if;
end $$;

-- 8. operators still cannot read audit logs
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  select count(*) into n from public.audit_logs;
  if n <> 0 then raise exception 'FAIL 8: operator can read audit_logs'; end if;
end $$;

rollback;
select 'onboarding_phase4: all assertions passed' as result;
