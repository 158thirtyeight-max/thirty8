-- =========================================================================
-- Phase 2 checks for 20260926000100_onboarding_foundation.sql
--
-- Run against a local/branch database AFTER `supabase db push`
-- (e.g. `psql "$DB_URL" -f supabase/tests/onboarding_phase2.sql`).
-- Everything runs in one transaction and is rolled back; any failed
-- assertion raises an exception. Test rows only exist inside the
-- rolled-back transaction.
-- =========================================================================
begin;

-- Two test users (profiles are created by the on_auth_user_created trigger).
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;

-- ---- 1. registration starts as a draft --------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); v_status text;
begin
  select application_status::text into v_status from public.operators where id = v_id;
  if v_status <> 'draft' then raise exception 'FAIL 1: new operator should be draft, got %', v_status; end if;
end $$;

-- ---- 2. operator cannot self-approve / change review fields -----------
do $$
declare v_id uuid := (select id from t_ops where tag = 'A');
begin
  begin
    update public.operators set status = 'approved' where id = v_id;
    raise exception 'FAIL 2a: operator changed own status';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    update public.operators set application_status = 'approved' where id = v_id;
    raise exception 'FAIL 2b: operator changed own application_status';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    update public.operators set review_reason = 'x' where id = v_id;
    raise exception 'FAIL 2c: operator changed review_reason';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  -- allowed: editing own business name / onboarding step
  update public.operators set name = 'Op A renamed', onboarding_step = 2 where id = v_id;
end $$;

-- ---- 3. profile / KYC constraints -------------------------------------
do $$
declare v_id uuid := (select id from t_ops where tag = 'A');
begin
  insert into public.operator_profiles (operator_id, owner_name, address, city, district, state, pin_code)
  values (v_id, 'Owner', '1 Main St', 'Port Blair', 'South Andaman', 'Andaman and Nicobar Islands', '744101');

  begin
    update public.operator_profiles set pin_code = '044101' where operator_id = v_id;
    raise exception 'FAIL 3a: bad PIN accepted';
  exception when check_violation then null; end;

  begin
    insert into public.operator_kyc (operator_id, pan_number) values (v_id, 'BADPAN');
    raise exception 'FAIL 3b: bad PAN accepted';
  exception when check_violation then null; end;

  begin
    insert into public.operator_kyc (operator_id, pan_number, gst_registered, gstin)
    values (v_id, 'ABCDE1234F', false, '35ABCDE1234F1Z5');
    raise exception 'FAIL 3c: GSTIN accepted while gst_registered = false';
  exception when check_violation then null; end;

  insert into public.operator_kyc (operator_id, pan_number, gst_registered) values (v_id, 'ABCDE1234F', false);
end $$;

-- ---- 4. documents: verification cannot be set by the operator ---------
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); v_doc uuid; v_status text; v_ver int;
begin
  insert into public.operator_documents (operator_id, doc_type, file_path, file_name, status)
  values (v_id, 'pan_card', v_id || '/pan_1.pdf', 'pan.pdf', 'verified')
  returning id, status into v_doc, v_status;
  if v_status <> 'pending' then raise exception 'FAIL 4a: operator inserted a % document', v_status; end if;

  begin
    update public.operator_documents set status = 'verified' where id = v_doc;
    raise exception 'FAIL 4b: operator verified own document';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  update public.operator_documents set file_path = v_id || '/pan_2.pdf' where id = v_doc
  returning version into v_ver;
  if v_ver <> 2 then raise exception 'FAIL 4c: replacing a file should bump version, got %', v_ver; end if;

  begin
    insert into public.operator_documents (operator_id, doc_type, file_path) values (v_id, 'pan_card', v_id || '/dup.pdf');
    raise exception 'FAIL 4d: duplicate pan_card row allowed';
  exception when unique_violation then null; end;
end $$;

-- ---- 5. tenant isolation ----------------------------------------------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); n int;
begin
  select count(*) into n from public.operator_documents where operator_id = v_a;
  if n <> 0 then raise exception 'FAIL 5a: operator B can read A documents'; end if;
  select count(*) into n from public.operator_kyc where operator_id = v_a;
  if n <> 0 then raise exception 'FAIL 5b: operator B can read A KYC'; end if;
  select count(*) into n from public.operator_profiles where operator_id = v_a;
  if n <> 0 then raise exception 'FAIL 5c: operator B can read A profile'; end if;
  begin
    perform public.operator_completeness(v_a);
    raise exception 'FAIL 5d: operator B can compute A completeness';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 6. completeness ---------------------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); r jsonb;
begin
  r := public.operator_completeness(v_id);
  if (r ->> 'complete')::boolean then raise exception 'FAIL 6a: should be incomplete (no ID proof yet)'; end if;
  if not (r -> 'missing') ? 'Authorized person identity / address proof' then
    raise exception 'FAIL 6b: missing list lacks id proof: %', r -> 'missing';
  end if;
  if (r -> 'missing') ? 'GST registration certificate' then
    raise exception 'FAIL 6c: GST certificate must not be required when not GST registered';
  end if;

  insert into public.operator_documents (operator_id, doc_type, file_path) values (v_id, 'id_proof', v_id || '/id.pdf');
  r := public.operator_completeness(v_id);
  -- Business/KYC/document sections must be satisfied (bank + mandate sections
  -- arrive in Phase 3 and are checked in onboarding_phase3.sql).
  if exists (select 1 from jsonb_array_elements(r -> 'items') i
             where not (i ->> 'ok')::boolean and i ->> 'section' in ('business', 'kyc', 'documents')) then
    raise exception 'FAIL 6d: business/kyc/documents incomplete, missing: %', r -> 'missing';
  end if;

  -- GST registered => certificate + GSTIN become mandatory
  update public.operator_kyc set gst_registered = true where operator_id = v_id;
  r := public.operator_completeness(v_id);
  if (r ->> 'complete')::boolean then raise exception 'FAIL 6e: GST registered but nothing required'; end if;
  if not (r -> 'missing') ? 'GST registration certificate' or not (r -> 'missing') ? 'GSTIN' then
    raise exception 'FAIL 6f: GST items missing from list: %', r -> 'missing';
  end if;
end $$;

-- ---- 7. locked once submitted -----------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set application_status = 'submitted' where id = (select id from t_ops where tag = 'A');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_id uuid := (select id from t_ops where tag = 'A'); n int;
begin
  update public.operator_profiles set city = 'Changed' where operator_id = v_id;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 7a: profile editable while submitted'; end if;
  begin
    insert into public.operator_documents (operator_id, doc_type, file_path) values (v_id, 'other_registration', v_id || '/o.pdf');
    raise exception 'FAIL 7b: document insert allowed while submitted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 8. backfill sanity ------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
do $$
declare n int;
begin
  select count(*) into n from public.operators
  where status = 'approved' and application_status <> 'approved'
    and id not in (select id from t_ops);
  if n <> 0 then raise exception 'FAIL 8: % pre-existing approved operators not backfilled to approved', n; end if;
end $$;

rollback;
select 'onboarding_phase2: all assertions passed' as result;
