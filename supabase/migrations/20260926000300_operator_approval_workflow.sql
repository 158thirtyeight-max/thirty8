-- =========================================================================
-- Operator approval workflow (Phase 4)
--
-- All state transitions go through SECURITY DEFINER functions that check the
-- caller's role, validate the current state, and write an audit_logs row
-- (actor, before/after, reason). Direct table updates of these columns by
-- operators are already blocked by the Phase 2 guard trigger.
--
-- Lifecycle: draft -> submitted -> under_review -> approved | rejected
--            \-> changes_requested -> (operator edits) -> submitted
-- Suspension/reinstatement act on operators.status and leave the application
-- history intact.
-- =========================================================================

create index audit_logs_after_operator_idx on public.audit_logs ((after ->> 'operator_id'))
  where after ? 'operator_id';

-- ---------------------------------------------------------------------
-- Operator submits the application (only when 100% complete)
-- ---------------------------------------------------------------------
create or replace function public.submit_operator_application(p_operator_id uuid)
returns public.operators
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators;
  v_before jsonb;
  v_c jsonb;
begin
  if (select auth.uid()) is null then
    raise exception 'Not authenticated';
  end if;
  if not private.is_operator_admin(p_operator_id) then
    raise exception 'Only the operator admin can submit the application';
  end if;

  select * into v_op from public.operators where id = p_operator_id for update;
  if v_op.id is null then
    raise exception 'Operator not found';
  end if;
  if v_op.application_status not in ('draft', 'changes_requested') then
    raise exception 'Application cannot be submitted while %', v_op.application_status;
  end if;

  v_c := public.operator_completeness(p_operator_id);
  if not (v_c ->> 'complete')::boolean then
    raise exception 'Registration incomplete. Missing: %', (select string_agg(m, ', ') from jsonb_array_elements_text(v_c -> 'missing') m);
  end if;

  v_before := jsonb_build_object('application_status', v_op.application_status, 'status', v_op.status);

  update public.operators
  set application_status = 'submitted',
      submitted_at = now(),
      review_reason = null,
      onboarding_step = 6
  where id = p_operator_id
  returning * into v_op;

  perform private.write_audit(
    'operator.submitted', 'operator', p_operator_id, v_before,
    jsonb_build_object('operator_id', p_operator_id, 'application_status', v_op.application_status)
  );
  return v_op;
end;
$$;

-- ---------------------------------------------------------------------
-- Admin reviews an operator application / suspends / reinstates
-- ---------------------------------------------------------------------
create or replace function public.admin_review_operator(
  p_operator_id uuid,
  p_action text,
  p_reason text default null
)
returns public.operators
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators;
  v_before jsonb;
  v_c jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not private.is_platform_admin() then
    raise exception 'Only platform admins can review operators';
  end if;
  if p_action in ('reject', 'request_changes', 'suspend') and v_reason is null then
    raise exception 'A reason is required to %', replace(p_action, '_', ' ');
  end if;

  select * into v_op from public.operators where id = p_operator_id for update;
  if v_op.id is null then
    raise exception 'Operator not found';
  end if;
  v_before := jsonb_build_object(
    'application_status', v_op.application_status, 'status', v_op.status, 'review_reason', v_op.review_reason
  );

  if p_action = 'start_review' then
    if v_op.application_status <> 'submitted' then
      raise exception 'Only a submitted application can move to review (currently %)', v_op.application_status;
    end if;
    update public.operators set application_status = 'under_review' where id = p_operator_id returning * into v_op;

  elsif p_action = 'approve' then
    if v_op.application_status not in ('submitted', 'under_review') then
      raise exception 'Only a submitted application can be approved (currently %)', v_op.application_status;
    end if;
    v_c := public.operator_completeness(p_operator_id);
    if not (v_c ->> 'complete')::boolean then
      raise exception 'Application is incomplete: %', (select string_agg(m, ', ') from jsonb_array_elements_text(v_c -> 'missing') m);
    end if;
    if exists (select 1 from public.operator_documents where operator_id = p_operator_id and status = 'pending')
       or exists (select 1 from public.operator_payment_mandates where operator_id = p_operator_id and status = 'pending') then
      raise exception 'Verify or reject every uploaded document (and the payment mandate) before approving';
    end if;
    update public.operators
    set application_status = 'approved', status = 'approved',
        approved_by = (select auth.uid()), approved_at = now(),
        reviewed_by = (select auth.uid()), reviewed_at = now(), review_reason = null
    where id = p_operator_id returning * into v_op;

  elsif p_action = 'reject' then
    if v_op.application_status not in ('submitted', 'under_review') then
      raise exception 'Only a submitted application can be rejected (currently %)', v_op.application_status;
    end if;
    update public.operators
    set application_status = 'rejected', status = 'rejected',
        reviewed_by = (select auth.uid()), reviewed_at = now(), review_reason = v_reason
    where id = p_operator_id returning * into v_op;

  elsif p_action = 'request_changes' then
    if v_op.application_status not in ('submitted', 'under_review') then
      raise exception 'Changes can only be requested on a submitted application (currently %)', v_op.application_status;
    end if;
    update public.operators
    set application_status = 'changes_requested',
        reviewed_by = (select auth.uid()), reviewed_at = now(), review_reason = v_reason
    where id = p_operator_id returning * into v_op;

  elsif p_action = 'suspend' then
    if v_op.status <> 'approved' then
      raise exception 'Only an approved operator can be suspended (currently %)', v_op.status;
    end if;
    update public.operators
    set status = 'suspended', reviewed_by = (select auth.uid()), reviewed_at = now(), review_reason = v_reason
    where id = p_operator_id returning * into v_op;

  elsif p_action = 'reinstate' then
    if v_op.status <> 'suspended' then
      raise exception 'Only a suspended operator can be reinstated (currently %)', v_op.status;
    end if;
    update public.operators
    set status = 'approved', reviewed_by = (select auth.uid()), reviewed_at = now(), review_reason = null
    where id = p_operator_id returning * into v_op;

  else
    raise exception 'Unknown action %', p_action;
  end if;

  perform private.write_audit(
    'operator.' || p_action, 'operator', p_operator_id, v_before,
    jsonb_build_object(
      'operator_id', p_operator_id, 'application_status', v_op.application_status,
      'status', v_op.status, 'reason', v_reason
    )
  );
  return v_op;
end;
$$;

-- ---------------------------------------------------------------------
-- Admin verifies / rejects one operator document
-- ---------------------------------------------------------------------
create or replace function public.admin_review_operator_document(
  p_doc_id uuid,
  p_action text,
  p_reason text default null
)
returns public.operator_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc public.operator_documents;
  v_before jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not private.is_platform_admin() then
    raise exception 'Only platform admins can review documents';
  end if;
  if p_action not in ('verify', 'reject') then
    raise exception 'Unknown action %', p_action;
  end if;
  if p_action = 'reject' and v_reason is null then
    raise exception 'A reason is required to reject a document';
  end if;

  select * into v_doc from public.operator_documents where id = p_doc_id for update;
  if v_doc.id is null then
    raise exception 'Document not found';
  end if;
  v_before := jsonb_build_object('status', v_doc.status, 'rejection_reason', v_doc.rejection_reason);

  update public.operator_documents
  set status = case p_action when 'verify' then 'verified' else 'rejected' end,
      reviewed_by = (select auth.uid()), reviewed_at = now(),
      rejection_reason = case p_action when 'reject' then v_reason else null end
  where id = p_doc_id returning * into v_doc;

  perform private.write_audit(
    'operator_document.' || p_action, 'operator_document', p_doc_id, v_before,
    jsonb_build_object('operator_id', v_doc.operator_id, 'doc_type', v_doc.doc_type,
                       'status', v_doc.status, 'reason', v_reason)
  );
  return v_doc;
end;
$$;

-- ---------------------------------------------------------------------
-- Admin verifies / rejects the payment mandate
-- ---------------------------------------------------------------------
create or replace function public.admin_review_mandate(
  p_operator_id uuid,
  p_action text,
  p_reason text default null
)
returns public.operator_payment_mandates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m public.operator_payment_mandates;
  v_before jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not private.is_platform_admin() then
    raise exception 'Only platform admins can review the payment mandate';
  end if;
  if p_action not in ('verify', 'reject') then
    raise exception 'Unknown action %', p_action;
  end if;
  if p_action = 'reject' and v_reason is null then
    raise exception 'A reason is required to reject the mandate';
  end if;

  select * into v_m from public.operator_payment_mandates where operator_id = p_operator_id for update;
  if v_m.operator_id is null then
    raise exception 'No payment mandate uploaded';
  end if;
  v_before := jsonb_build_object('status', v_m.status, 'rejection_reason', v_m.rejection_reason);

  update public.operator_payment_mandates
  set status = case p_action when 'verify' then 'verified' else 'rejected' end,
      reviewed_by = (select auth.uid()), reviewed_at = now(),
      rejection_reason = case p_action when 'reject' then v_reason else null end
  where operator_id = p_operator_id returning * into v_m;

  perform private.write_audit(
    'operator_mandate.' || p_action, 'operator_mandate', p_operator_id, v_before,
    jsonb_build_object('operator_id', p_operator_id, 'status', v_m.status, 'reason', v_reason)
  );
  return v_m;
end;
$$;

revoke execute on function public.submit_operator_application(uuid) from public, anon;
revoke execute on function public.admin_review_operator(uuid, text, text) from public, anon;
revoke execute on function public.admin_review_operator_document(uuid, text, text) from public, anon;
revoke execute on function public.admin_review_mandate(uuid, text, text) from public, anon;
grant execute on function public.submit_operator_application(uuid) to authenticated;
grant execute on function public.admin_review_operator(uuid, text, text) to authenticated;
grant execute on function public.admin_review_operator_document(uuid, text, text) to authenticated;
grant execute on function public.admin_review_mandate(uuid, text, text) to authenticated;
