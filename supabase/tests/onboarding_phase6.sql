-- =========================================================================
-- Phase 6 checks for 20260926000500_bus_documents.sql
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin@test.invalid');
insert into public.user_roles (user_id, role) values ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin');

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

reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_bus select 'A1', (public.create_bus((select id from t_ops where tag = 'A'), 'Bus A1', 'AN01A0001', 'ac_seater', 40)).id;

-- ---- 1. add documents, verification cannot be self-set ----------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1'); v_doc uuid; v_status text; v_ver int;
begin
  insert into public.bus_documents (bus_id, doc_type, doc_number, issue_date, expiry_date, file_path, status)
  values (v_bus, 'insurance', 'POL-1', current_date - 100, current_date + 265, 'x/y/ins.pdf', 'verified')
  returning id, status into v_doc, v_status;
  if v_status <> 'pending' then raise exception 'FAIL 1a: inserted as %', v_status; end if;

  begin
    update public.bus_documents set status = 'verified' where id = v_doc;
    raise exception 'FAIL 1b: operator verified own bus document';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;

  -- changing the expiry date is a document change: re-verification required
  update public.bus_documents set expiry_date = current_date + 300 where id = v_doc returning version, status into v_ver, v_status;
  if v_ver <> 2 or v_status <> 'pending' then raise exception 'FAIL 1c: expected v2/pending, got v%/%', v_ver, v_status; end if;

  begin
    insert into public.bus_documents (bus_id, doc_type, issue_date, expiry_date, file_path)
    values (v_bus, 'puc', current_date, current_date - 1, 'x/y/puc.pdf');
    raise exception 'FAIL 1d: expiry before issue accepted';
  exception when check_violation then null; end;

  begin
    insert into public.bus_documents (bus_id, doc_type, file_path) values (v_bus, 'insurance', 'x/y/dup.pdf');
    raise exception 'FAIL 1e: duplicate insurance row accepted';
  exception when unique_violation then null; end;
end $$;

-- ---- 2. other operator cannot see or add documents to A's bus ---------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1'); n int;
begin
  select count(*) into n from public.bus_documents where bus_id = v_bus;
  if n <> 0 then raise exception 'FAIL 2a: operator B can read A bus documents'; end if;
  begin
    insert into public.bus_documents (bus_id, doc_type, file_path) values (v_bus, 'rc', 'x/y/rc.pdf');
    raise exception 'FAIL 2b: operator B added a document to A bus';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 3. admin review + expired documents ------------------------------
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1'); v_doc uuid; d public.bus_documents; r record;
begin
  select id into v_doc from public.bus_documents where bus_id = v_bus and doc_type = 'insurance';
  begin
    perform public.admin_review_bus_document(v_doc, 'reject');
    raise exception 'FAIL 3a: rejected without reason';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  d := public.admin_review_bus_document(v_doc, 'verify');
  if d.status <> 'verified' or d.reviewed_by is null then raise exception 'FAIL 3b: not verified/stamped'; end if;
end $$;

-- private helpers are not callable by API roles; check them as the database owner
reset role;
select set_config('request.jwt.claims', '', true);
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1'); r record;
begin
  select * into r from private.bus_document_checks(v_bus) where doc_type = 'insurance';
  if not r.ok then raise exception 'FAIL 3c: verified, unexpired insurance should be ok'; end if;
  select * into r from private.bus_document_checks(v_bus) where doc_type = 'rc';
  if r.ok or r.present then raise exception 'FAIL 3d: missing RC reported ok'; end if;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
update public.bus_documents set expiry_date = current_date - 1
where bus_id = (select id from t_bus where tag = 'A1') and doc_type = 'insurance';
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1'); r record;
begin
  select * into r from private.bus_document_checks(v_bus) where doc_type = 'insurance';
  if r.ok or not r.expired then raise exception 'FAIL 3e: expired insurance treated as ok'; end if;
  if (select expiry_state from public.bus_document_expiry where bus_id = v_bus and doc_type = 'insurance') <> 'expired' then
    raise exception 'FAIL 3f: expiry view did not flag expired';
  end if;
end $$;

-- verifying an expired document is refused
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_doc uuid := (select id from public.bus_documents where doc_type = 'insurance' and bus_id = (select id from t_bus where tag = 'A1'));
begin
  begin
    perform public.admin_review_bus_document(v_doc, 'verify');
    raise exception 'FAIL 3g: expired document verified';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 4. requirement configurable --------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.document_requirements set required = false where scope = 'bus' and doc_type = 'puc';
update public.document_requirements set condition = '{"bus_type_in": ["ac_sleeper"]}' where scope = 'bus' and doc_type = 'permit';
do $$
declare v_bus uuid := (select id from t_bus where tag = 'A1');
begin
  if exists (select 1 from private.bus_document_checks(v_bus) where doc_type = 'permit') then
    raise exception 'FAIL 4: permit requirement should not apply to ac_seater';
  end if;
end $$;

rollback;
select 'onboarding_phase6: all assertions passed' as result;
