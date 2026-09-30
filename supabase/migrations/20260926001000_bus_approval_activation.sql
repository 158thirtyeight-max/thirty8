-- =========================================================================
-- Bus approval and activation (Phase 11)
--
-- Lifecycle: draft -> submitted -> under_review -> changes_requested | approved
--            -> active -> suspended | inactive.
-- A bus reaches customers only when ALL of these hold (checked again at
-- activation, and continuously by private.is_bus_bookable):
--   1 operator approved   2 bus approved   3 required documents verified and
--   unexpired   4 seat layout valid   5 route configured   6 fares configured
--   7 schedule configured   8 required operational info complete
--
-- Legacy buses (existing before the workflow) stay active and bookable while
-- they migrate: submit_bus sets legacy_migration_status instead of taking the
-- bus offline, and admin approval clears is_legacy.
-- =========================================================================

alter table public.buses
  add column legacy_migration_status text
    check (legacy_migration_status is null or legacy_migration_status in ('submitted', 'under_review', 'changes_requested'));

-- Refresh the update guard so legacy_migration_status is workflow-only too.
-- (Still references only public objects: invoker-rights code cannot resolve the private schema.)
create or replace function private.guard_bus_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') or public.am_i_platform_admin() then
    return new;
  end if;

  if new.operator_id is distinct from old.operator_id
    or new.lifecycle_status is distinct from old.lifecycle_status
    or new.is_legacy is distinct from old.is_legacy
    or new.legacy_migration_status is distinct from old.legacy_migration_status
    or new.legacy_reviewed_at is distinct from old.legacy_reviewed_at
    or new.legacy_reviewed_by is distinct from old.legacy_reviewed_by
    or new.submitted_at is distinct from old.submitted_at
    or new.reviewed_at is distinct from old.reviewed_at
    or new.reviewed_by is distinct from old.reviewed_by
    or new.review_reason is distinct from old.review_reason
    or new.approved_at is distinct from old.approved_at
    or new.approved_by is distinct from old.approved_by
    or new.activated_at is distinct from old.activated_at then
    raise exception 'Bus approval and lifecycle fields can only be changed through the review workflow';
  end if;

  if not exists (
    select 1 from public.operators o
    where o.id = old.operator_id and o.status = 'approved' and o.application_status = 'approved'
  ) then
    raise exception 'The operator account is not approved; buses cannot be edited';
  end if;

  if old.lifecycle_status not in ('draft', 'changes_requested') and not old.is_legacy then
    if new.registration_number is distinct from old.registration_number
      or new.bus_type is distinct from old.bus_type
      or new.total_seats is distinct from old.total_seats
      or new.name is distinct from old.name
      or new.manufacturer is distinct from old.manufacturer
      or new.model is distinct from old.model
      or new.manufacturing_year is distinct from old.manufacturing_year
      or new.registration_year is distinct from old.registration_year
      or new.chassis_number is distinct from old.chassis_number
      or new.engine_number is distinct from old.engine_number then
      raise exception 'Core vehicle details are locked while the bus is %', old.lifecycle_status;
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Completeness of a bus: the checklist shown to the operator and re-checked
-- by submit / approve / activate. Returns
--   {percent, complete, missing[], items[{key,label,section,ok}], details{section:[errors]}}
-- ---------------------------------------------------------------------
create or replace function private.bus_checklist(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_items jsonb := '[]'::jsonb;
  v_details jsonb := '{}'::jsonb;
  v_doc record;
  v_layout jsonb;
  v_route jsonb;
  v_fare jsonb;
  v_sched jsonb;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;

  -- A: basic information and photographs
  v_items := private.completeness_item(v_items, 'name', 'Bus name', 'basic', coalesce(btrim(v_bus.name), '') <> '');
  v_items := private.completeness_item(v_items, 'manufacturer', 'Manufacturer', 'basic', coalesce(btrim(v_bus.manufacturer), '') <> '');
  v_items := private.completeness_item(v_items, 'model', 'Model', 'basic', coalesce(btrim(v_bus.model), '') <> '');
  v_items := private.completeness_item(v_items, 'mfg_year', 'Manufacturing year', 'basic', v_bus.manufacturing_year is not null);
  v_items := private.completeness_item(v_items, 'reg_year', 'Registration year', 'basic', v_bus.registration_year is not null);
  v_items := private.completeness_item(v_items, 'exterior', 'Exterior photograph', 'basic', v_bus.exterior_photo_path is not null);
  v_items := private.completeness_item(v_items, 'interior', 'Interior photograph', 'basic', v_bus.interior_photo_path is not null);

  -- B: required documents (present, not expired, not rejected)
  for v_doc in select * from private.bus_document_checks(p_bus_id) where required loop
    v_items := private.completeness_item(
      v_items, 'doc:' || v_doc.doc_type, v_doc.label, 'documents',
      v_doc.present and not v_doc.expired and coalesce(v_doc.status, '') <> 'rejected'
    );
  end loop;

  -- C-F: seat layout, route, fares, schedule
  v_layout := public.validate_bus_layout(p_bus_id);
  v_route := public.validate_bus_route(p_bus_id);
  v_fare := public.validate_bus_fares(p_bus_id);
  v_sched := public.validate_bus_schedule(p_bus_id);

  v_items := private.completeness_item(v_items, 'layout', 'Seat layout', 'seats', (v_layout ->> 'valid')::boolean);
  v_items := private.completeness_item(v_items, 'route', 'Route', 'route', (v_route ->> 'valid')::boolean);
  v_items := private.completeness_item(v_items, 'fare', 'Fare', 'fare', (v_fare ->> 'valid')::boolean);
  v_items := private.completeness_item(v_items, 'schedule', 'Schedule', 'schedule', (v_sched ->> 'valid')::boolean);

  v_details := jsonb_build_object(
    'seats', coalesce(v_layout -> 'errors', '[]'::jsonb),
    'route', coalesce(v_route -> 'errors', '[]'::jsonb),
    'fare', coalesce(v_fare -> 'errors', '[]'::jsonb),
    'schedule', coalesce(v_sched -> 'errors', '[]'::jsonb)
  );

  return private.summarize_completeness(v_items) || jsonb_build_object('details', v_details);
end;
$$;

revoke execute on function private.bus_checklist(uuid) from public, anon;
grant execute on function private.bus_checklist(uuid) to authenticated;

create or replace function public.bus_completeness(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_op uuid := private.bus_operator_id(p_bus_id);
begin
  if v_op is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_op) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  return private.bus_checklist(p_bus_id);
end;
$$;

revoke execute on function public.bus_completeness(uuid) from public, anon;
grant execute on function public.bus_completeness(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Everything that stops a bus becoming active/bookable, as readable text.
-- ---------------------------------------------------------------------
create or replace function private.bus_activation_blockers(p_bus_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_out text[] := '{}';
  v_doc record;
  v_check jsonb;
  v_item jsonb;
  v_sec text;
  v_err text;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;

  -- 1. operator approved
  if not private.operator_is_approved(v_bus.operator_id) then
    v_out := array_append(v_out, 'The operator account is not approved');
  end if;

  -- 2. bus approved by an admin
  if not (v_bus.lifecycle_status = 'approved'
          or (v_bus.lifecycle_status = 'inactive' and v_bus.approved_by is not null)
          or (v_bus.lifecycle_status = 'active')) then
    v_out := array_append(v_out, 'The bus has not been approved yet');
  end if;
  if v_bus.is_legacy then
    v_out := array_append(v_out, 'The bus is a legacy bus and has not been reviewed');
  end if;

  -- 3. required documents verified and unexpired
  for v_doc in select * from private.bus_document_checks(p_bus_id) where required and not ok loop
    v_out := v_out || (v_doc.label || case
      when not v_doc.present then ' is missing'
      when v_doc.expired then ' has expired'
      when v_doc.status = 'rejected' then ' was rejected'
      else ' is awaiting verification' end);
  end loop;

  -- 4-8. layout, route, fare, schedule and basic information
  v_check := private.bus_checklist(p_bus_id);
  for v_item in select * from jsonb_array_elements(v_check -> 'items') loop
    if not (v_item ->> 'ok')::boolean and v_item ->> 'section' not in ('documents', 'seats', 'route', 'fare', 'schedule') then
      v_out := v_out || ((v_item ->> 'label') || ' is missing');
    end if;
  end loop;
  for v_sec in select unnest(array['seats', 'route', 'fare', 'schedule']) loop
    for v_err in select jsonb_array_elements_text(v_check -> 'details' -> v_sec) loop
      v_out := v_out || (initcap(v_sec) || ': ' || v_err);
    end loop;
  end loop;

  return v_out;
end;
$$;

revoke execute on function private.bus_activation_blockers(uuid) from public, anon;
grant execute on function private.bus_activation_blockers(uuid) to authenticated;

create or replace function public.bus_activation_readiness(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_op uuid := private.bus_operator_id(p_bus_id);
  v_blockers text[];
begin
  if v_op is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_op) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  v_blockers := private.bus_activation_blockers(p_bus_id);
  return jsonb_build_object('ready', coalesce(array_length(v_blockers, 1), 0) = 0, 'blockers', to_jsonb(v_blockers));
end;
$$;

revoke execute on function public.bus_activation_readiness(uuid) from public, anon;
grant execute on function public.bus_activation_readiness(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Operator submits a bus for review (all setup stages complete)
-- ---------------------------------------------------------------------
create or replace function public.submit_bus(p_bus_id uuid)
returns public.buses
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_c jsonb;
  v_before jsonb;
  v_missing text;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_staff(v_bus.operator_id) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;

  if v_bus.is_legacy then
    if v_bus.lifecycle_status <> 'active' or v_bus.legacy_migration_status in ('submitted', 'under_review') then
      raise exception 'This legacy bus cannot be submitted right now';
    end if;
  elsif v_bus.lifecycle_status not in ('draft', 'changes_requested') then
    raise exception 'A bus can only be submitted from draft or after changes were requested (currently %)', v_bus.lifecycle_status;
  end if;

  v_c := private.bus_checklist(p_bus_id);
  if not (v_c ->> 'complete')::boolean then
    select string_agg(m, ', ') into v_missing from jsonb_array_elements_text(v_c -> 'missing') m;
    raise exception 'Bus setup is incomplete. Missing: %', v_missing;
  end if;

  v_before := jsonb_build_object('lifecycle_status', v_bus.lifecycle_status, 'legacy_migration_status', v_bus.legacy_migration_status);

  if v_bus.is_legacy then
    update public.buses set legacy_migration_status = 'submitted', submitted_at = now(), review_reason = null
    where id = p_bus_id returning * into v_bus;
  else
    update public.buses set lifecycle_status = 'submitted', submitted_at = now(), review_reason = null
    where id = p_bus_id returning * into v_bus;
  end if;

  perform private.write_audit(
    'bus.submitted', 'bus', p_bus_id, v_before,
    jsonb_build_object('operator_id', v_bus.operator_id, 'lifecycle_status', v_bus.lifecycle_status,
                       'legacy_migration_status', v_bus.legacy_migration_status, 'legacy', v_bus.is_legacy)
  );
  return v_bus;
end;
$$;

-- ---------------------------------------------------------------------
-- Admin review of a bus
--   start_review | approve | request_changes | reject | suspend | reinstate
-- ---------------------------------------------------------------------
create or replace function public.admin_review_bus(p_bus_id uuid, p_action text, p_reason text default null)
returns public.buses
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_before jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_in_review boolean;
  v_blockers text[];
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can review buses'; end if;
  if p_action in ('reject', 'request_changes', 'suspend') and v_reason is null then
    raise exception 'A reason is required to %', replace(p_action, '_', ' ');
  end if;

  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  v_before := jsonb_build_object(
    'lifecycle_status', v_bus.lifecycle_status, 'legacy_migration_status', v_bus.legacy_migration_status,
    'is_legacy', v_bus.is_legacy, 'review_reason', v_bus.review_reason
  );

  v_in_review := case when v_bus.is_legacy
                      then v_bus.legacy_migration_status in ('submitted', 'under_review')
                      else v_bus.lifecycle_status in ('submitted', 'under_review') end;

  if p_action = 'start_review' then
    if not v_in_review then raise exception 'The bus has not been submitted for review'; end if;
    if v_bus.is_legacy then
      update public.buses set legacy_migration_status = 'under_review' where id = p_bus_id returning * into v_bus;
    else
      update public.buses set lifecycle_status = 'under_review' where id = p_bus_id returning * into v_bus;
    end if;

  elsif p_action = 'approve' then
    if not v_in_review then raise exception 'The bus has not been submitted for review'; end if;
    if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
    if exists (select 1 from public.bus_documents where bus_id = p_bus_id and status = 'pending') then
      raise exception 'Verify or reject every uploaded document before approving the bus';
    end if;
    -- documents, layout, route, fares, schedule and basic info must all be in order
    select coalesce(array_agg(b), '{}') into v_blockers
    from unnest(private.bus_activation_blockers(p_bus_id)) b
    where b not in ('The bus has not been approved yet', 'The bus is a legacy bus and has not been reviewed');
    if array_length(v_blockers, 1) > 0 then
      raise exception 'The bus cannot be approved: %', array_to_string(v_blockers, '; ');
    end if;

    if v_bus.is_legacy then
      update public.buses
      set is_legacy = false, legacy_migration_status = null,
          legacy_reviewed_at = now(), legacy_reviewed_by = (select auth.uid()),
          approved_at = now(), approved_by = (select auth.uid()),
          reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = null
      where id = p_bus_id returning * into v_bus;   -- stays active and bookable
    else
      update public.buses
      set lifecycle_status = 'approved',
          approved_at = now(), approved_by = (select auth.uid()),
          reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = null
      where id = p_bus_id returning * into v_bus;
    end if;

  elsif p_action = 'request_changes' then
    if not v_in_review then raise exception 'Changes can only be requested on a submitted bus'; end if;
    if v_bus.is_legacy then
      update public.buses
      set legacy_migration_status = 'changes_requested', reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = v_reason
      where id = p_bus_id returning * into v_bus;
    else
      update public.buses
      set lifecycle_status = 'changes_requested', reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = v_reason
      where id = p_bus_id returning * into v_bus;
    end if;

  elsif p_action = 'reject' then
    if v_bus.is_legacy then
      raise exception 'A legacy bus cannot be rejected; request changes or suspend it';
    end if;
    if v_bus.lifecycle_status not in ('submitted', 'under_review') then
      raise exception 'Only a submitted bus can be rejected (currently %)', v_bus.lifecycle_status;
    end if;
    update public.buses
    set lifecycle_status = 'inactive', reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = v_reason
    where id = p_bus_id returning * into v_bus;

  elsif p_action = 'suspend' then
    if v_bus.lifecycle_status not in ('approved', 'active') then
      raise exception 'Only an approved or active bus can be suspended (currently %)', v_bus.lifecycle_status;
    end if;
    update public.buses
    set lifecycle_status = 'suspended', reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = v_reason
    where id = p_bus_id returning * into v_bus;
    update public.bus_services set status = 'paused' where bus_id = p_bus_id and status = 'active';

  elsif p_action = 'reinstate' then
    if v_bus.lifecycle_status = 'suspended' then
      update public.buses
      set lifecycle_status = case when v_bus.activated_at is not null or v_bus.is_legacy then 'active'::public.bus_lifecycle
                                  else 'approved'::public.bus_lifecycle end,
          reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = null
      where id = p_bus_id returning * into v_bus;
      if v_bus.lifecycle_status = 'active' then
        update public.bus_services set status = 'active' where bus_id = p_bus_id and status = 'paused';
      end if;
    elsif v_bus.lifecycle_status = 'inactive' and v_bus.approved_by is null then
      -- a rejected bus goes back to the operator as a draft
      update public.buses
      set lifecycle_status = 'draft', reviewed_at = now(), reviewed_by = (select auth.uid()), review_reason = null
      where id = p_bus_id returning * into v_bus;
    else
      raise exception 'Only a suspended or rejected bus can be reinstated (currently %)', v_bus.lifecycle_status;
    end if;

  else
    raise exception 'Unknown action %', p_action;
  end if;

  perform private.write_audit(
    'bus.' || p_action, 'bus', p_bus_id, v_before,
    jsonb_build_object(
      'operator_id', v_bus.operator_id, 'lifecycle_status', v_bus.lifecycle_status,
      'legacy_migration_status', v_bus.legacy_migration_status, 'is_legacy', v_bus.is_legacy, 'reason', v_reason
    )
  );
  return v_bus;
end;
$$;

-- ---------------------------------------------------------------------
-- Activation: makes an approved bus bookable. Operator staff or admin.
-- Re-checks every condition at this moment (documents may have expired since approval).
-- ---------------------------------------------------------------------
create or replace function public.activate_bus(p_bus_id uuid)
returns public.buses
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_blockers text[];
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  if v_bus.lifecycle_status = 'active' then
    return v_bus;
  end if;
  if not (v_bus.lifecycle_status = 'approved' or (v_bus.lifecycle_status = 'inactive' and v_bus.approved_by is not null)) then
    raise exception 'Only an approved bus can be activated (currently %)', v_bus.lifecycle_status;
  end if;

  v_blockers := private.bus_activation_blockers(p_bus_id);
  if array_length(v_blockers, 1) > 0 then
    raise exception 'The bus cannot be activated: %', array_to_string(v_blockers, '; ');
  end if;

  update public.buses
  set lifecycle_status = 'active', status = 'active', activated_at = now()
  where id = p_bus_id returning * into v_bus;
  update public.bus_services set status = 'active' where bus_id = p_bus_id and status = 'paused';

  perform private.write_audit(
    'bus.activated', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'lifecycle_status', 'active')
  );
  return v_bus;
end;
$$;

-- Operator takes an active bus out of service (can be reactivated later if it was approved).
create or replace function public.deactivate_bus(p_bus_id uuid)
returns public.buses
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  if v_bus.lifecycle_status <> 'active' then
    raise exception 'Only an active bus can be deactivated (currently %)', v_bus.lifecycle_status;
  end if;
  if v_bus.is_legacy then
    raise exception 'Legacy buses are managed through the migration review; ask an admin to suspend it';
  end if;

  update public.buses set lifecycle_status = 'inactive' where id = p_bus_id returning * into v_bus;
  update public.bus_services set status = 'paused' where bus_id = p_bus_id and status = 'active';

  perform private.write_audit(
    'bus.deactivated', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'lifecycle_status', 'inactive')
  );
  return v_bus;
end;
$$;

revoke execute on function public.submit_bus(uuid) from public, anon;
revoke execute on function public.admin_review_bus(uuid, text, text) from public, anon;
revoke execute on function public.activate_bus(uuid) from public, anon;
revoke execute on function public.deactivate_bus(uuid) from public, anon;
grant execute on function public.submit_bus(uuid) to authenticated;
grant execute on function public.admin_review_bus(uuid, text, text) to authenticated;
grant execute on function public.activate_bus(uuid) to authenticated;
grant execute on function public.deactivate_bus(uuid) to authenticated;

-- Approving an operator's suspension already hides its buses through
-- private.is_bus_bookable (operator status must be approved). Suspending an
-- operator also pauses nothing here on purpose: reinstating the operator
-- restores its buses exactly as they were.
