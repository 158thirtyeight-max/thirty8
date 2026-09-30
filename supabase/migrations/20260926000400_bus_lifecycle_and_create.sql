-- =========================================================================
-- Bus lifecycle, legacy flagging and approved-operator-only creation (Phase 5)
--
-- * Every bus has its own lifecycle (draft -> submitted -> under_review ->
--   changes_requested / approved -> active -> suspended / inactive),
--   separate from the operator's approval and from the legacy operational
--   `status` (active/maintenance/inactive).
-- * Buses that existed before this migration are flagged is_legacy = true
--   and kept `active` so search/holds/bookings keep working. They are NEVER
--   marked as reviewed/approved here: bus_verification_state() reports them
--   as 'legacy' until an admin migrates them.
-- * Buses can only be created through create_bus(), which requires an
--   approved operator. Direct inserts are no longer permitted for operators.
-- =========================================================================

create type public.bus_lifecycle as enum (
  'draft',
  'submitted',
  'under_review',
  'changes_requested',
  'approved',
  'active',
  'suspended',
  'inactive'
);

alter table public.buses
  add column lifecycle_status public.bus_lifecycle not null default 'draft',
  add column is_legacy boolean not null default false,
  add column legacy_reviewed_at timestamptz,
  add column legacy_reviewed_by uuid references public.profiles (id),
  add column name text,
  add column manufacturer text,
  add column model text,
  add column manufacturing_year smallint,
  add column registration_year smallint,
  add column chassis_number text,
  add column engine_number text,
  add column exterior_photo_path text,
  add column interior_photo_path text,
  add column submitted_at timestamptz,
  add column reviewed_at timestamptz,
  add column reviewed_by uuid references public.profiles (id),
  add column review_reason text,
  add column approved_at timestamptz,
  add column approved_by uuid references public.profiles (id),
  add column activated_at timestamptz,
  add constraint buses_manufacturing_year_chk check (manufacturing_year is null or manufacturing_year between 1980 and 2100),
  add constraint buses_registration_year_chk check (registration_year is null or registration_year between 1980 and 2100);

create index buses_lifecycle_idx on public.buses (lifecycle_status);
create index buses_legacy_idx on public.buses (is_legacy) where is_legacy;
create index buses_reviewed_by_idx on public.buses (reviewed_by) where reviewed_by is not null;
create index buses_approved_by_idx on public.buses (approved_by) where approved_by is not null;
create index buses_legacy_reviewed_by_idx on public.buses (legacy_reviewed_by) where legacy_reviewed_by is not null;

-- Existing buses: keep them live, but mark them as legacy / unmigrated. No
-- approval or review fields are stamped.
update public.buses set is_legacy = true, lifecycle_status = 'active';

-- ---------------------------------------------------------------------
-- Verification state for display everywhere (apps, admin, reports).
--   legacy     existing bus, never reviewed under the new workflow
--   verified   approved/active via the workflow (approved_by is recorded)
--   unverified everything else (draft, in review, suspended, ...)
-- ---------------------------------------------------------------------
create or replace function public.bus_verification_state(p_bus_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when b.is_legacy then 'legacy'
    when b.lifecycle_status in ('approved', 'active') and b.approved_by is not null then 'verified'
    else 'unverified'
  end
  from public.buses b
  where b.id = p_bus_id
    and (private.is_operator_staff(b.operator_id) or private.is_platform_admin());
$$;

revoke execute on function public.bus_verification_state(uuid) from public, anon;
grant execute on function public.bus_verification_state(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Operator approval helper
-- ---------------------------------------------------------------------
create or replace function private.operator_is_approved(p_operator_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.operators o
    where o.id = p_operator_id
      and o.status = 'approved'
      and o.application_status = 'approved'
  );
$$;

revoke execute on function private.operator_is_approved(uuid) from public, anon;
grant execute on function private.operator_is_approved(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Insert guard (defense in depth): outside of platform admins and trusted
-- server-side code (no auth.uid()), a bus can only be created for an approved
-- operator, and only in draft.
-- ---------------------------------------------------------------------
create or replace function private.guard_bus_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or public.am_i_platform_admin() then
    return new;
  end if;
  if not exists (
    select 1 from public.operators o
    where o.id = new.operator_id and o.status = 'approved' and o.application_status = 'approved'
  ) then
    raise exception 'Only an approved operator can create buses';
  end if;
  if new.lifecycle_status <> 'draft' or new.is_legacy then
    raise exception 'New buses must start as drafts';
  end if;
  return new;
end;
$$;

create trigger guard_bus_insert
  before insert on public.buses
  for each row execute function private.guard_bus_insert();

-- ---------------------------------------------------------------------
-- Update guard: lifecycle/review/legacy columns are workflow-only. Core
-- vehicle data is editable by the operator only while the bus is a draft
-- or has changes requested, or is a legacy bus (so it can be completed and
-- migrated). Suspended/unapproved operators cannot edit at all. Operational
-- fields (status, amenities, photos) stay editable.
-- SECURITY INVOKER: workflow RPCs run as the function owner and bypass this.
-- ---------------------------------------------------------------------
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

create trigger guard_bus_update
  before update on public.buses
  for each row execute function private.guard_bus_update();

-- ---------------------------------------------------------------------
-- RLS: no operator insert/delete. Staff can read and update their own
-- buses (subject to the guard above). The public sees only buses that have
-- been through review, so drafts/in-review buses never leak; approved,
-- active, suspended and inactive rows stay readable so existing bookings
-- can still show their bus.
-- ---------------------------------------------------------------------
drop policy buses_operator_manage on public.buses;
drop policy buses_select_public on public.buses;

-- Split so anonymous callers never evaluate the private role helpers (they have no
-- EXECUTE on them): anon gets only the plain-column rule.
create policy buses_select_public on public.buses
  for select to anon, authenticated
  using (status = 'active' and lifecycle_status in ('approved', 'active', 'suspended', 'inactive'));

create policy buses_select_staff on public.buses
  for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());

create policy buses_operator_update on public.buses
  for update to authenticated
  using (private.is_operator_staff(operator_id))
  with check (private.is_operator_staff(operator_id));

-- ---------------------------------------------------------------------
-- create_bus: the only way an operator creates a bus.
-- ---------------------------------------------------------------------
create or replace function public.create_bus(
  p_operator_id uuid,
  p_name text,
  p_registration_number text,
  p_bus_type text,
  p_total_seats integer,
  p_manufacturer text default null,
  p_model text default null,
  p_manufacturing_year integer default null,
  p_registration_year integer default null,
  p_chassis_number text default null,
  p_engine_number text default null,
  p_amenities text[] default '{}'
)
returns public.buses
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_reg text := upper(btrim(coalesce(p_registration_number, '')));
begin
  if (select auth.uid()) is null then
    raise exception 'Not authenticated';
  end if;
  if not (private.is_operator_admin(p_operator_id)
          or exists (select 1 from public.user_roles ur
                     where ur.user_id = (select auth.uid()) and ur.operator_id = p_operator_id
                       and ur.role = 'operator_staff')) then
    raise exception 'You are not allowed to add buses for this operator';
  end if;
  if not private.operator_is_approved(p_operator_id) then
    raise exception 'Only an approved operator can create buses';
  end if;
  if v_reg = '' then
    raise exception 'Registration number is required';
  end if;
  if p_total_seats is null or p_total_seats < 1 or p_total_seats > 80 then
    raise exception 'Total seats must be between 1 and 80';
  end if;

  insert into public.buses (
    operator_id, name, registration_number, bus_type, total_seats, manufacturer, model,
    manufacturing_year, registration_year, chassis_number, engine_number, amenities,
    lifecycle_status, is_legacy
  ) values (
    p_operator_id, nullif(btrim(coalesce(p_name, '')), ''), v_reg, p_bus_type, p_total_seats,
    nullif(btrim(coalesce(p_manufacturer, '')), ''), nullif(btrim(coalesce(p_model, '')), ''),
    p_manufacturing_year, p_registration_year,
    nullif(upper(btrim(coalesce(p_chassis_number, ''))), ''),
    nullif(upper(btrim(coalesce(p_engine_number, ''))), ''),
    coalesce(p_amenities, '{}'), 'draft', false
  ) returning * into v_bus;

  perform private.write_audit(
    'bus.created', 'bus', v_bus.id, null,
    jsonb_build_object('operator_id', p_operator_id, 'registration_number', v_reg, 'lifecycle_status', 'draft')
  );
  return v_bus;
end;
$$;

revoke execute on function public.create_bus(uuid, text, text, text, integer, text, text, integer, integer, text, text, text[]) from public, anon;
grant execute on function public.create_bus(uuid, text, text, text, integer, text, text, integer, integer, text, text, text[]) to authenticated;
