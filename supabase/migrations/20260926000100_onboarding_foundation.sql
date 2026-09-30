-- =========================================================================
-- Operator onboarding foundation (Phase 2)
--
-- Adds a separate operator *application* lifecycle on top of the existing
-- operators.status (which customer-facing RLS/search/cargo code relies on and
-- is therefore left untouched), plus profile/KYC/document storage, an
-- admin-configurable document requirement table, an audit helper, guard
-- triggers that stop operators editing review/approval columns, and a
-- completeness function that is the single source of truth for "what is
-- still missing".
--
-- All changes are additive and backward compatible.
-- =========================================================================

-- ---------------------------------------------------------------------
-- Application lifecycle
-- ---------------------------------------------------------------------
create type public.application_status as enum (
  'draft',
  'submitted',
  'under_review',
  'changes_requested',
  'approved',
  'rejected'
);

alter table public.operators
  add column application_status public.application_status not null default 'draft',
  add column onboarding_step smallint not null default 1,
  add column submitted_at timestamptz,
  add column reviewed_at timestamptz,
  add column reviewed_by uuid references public.profiles (id),
  add column review_reason text;

create index operators_application_status_idx on public.operators (application_status);
create index operators_reviewed_by_idx on public.operators (reviewed_by) where reviewed_by is not null;

-- Backfill existing operators from their current status. Nobody is forced to
-- re-enter data: completeness is only enforced when an operator (re)submits.
update public.operators
set application_status = case status
      when 'approved' then 'approved'::public.application_status
      when 'pending' then 'submitted'::public.application_status
      when 'rejected' then 'rejected'::public.application_status
      when 'suspended' then 'approved'::public.application_status
    end,
    submitted_at = coalesce(submitted_at, created_at),
    reviewed_at = case when status in ('approved', 'rejected') then coalesce(approved_at, updated_at) else null end,
    reviewed_by = case when status = 'approved' then approved_by else null end;

-- ---------------------------------------------------------------------
-- Audit helper. audit_logs already exists but nothing wrote to it.
-- ---------------------------------------------------------------------
create or replace function private.write_audit(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_before jsonb default null,
  p_after jsonb default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, before, after)
  values ((select auth.uid()), p_action, p_entity_type, p_entity_id, p_before, p_after);
$$;

revoke execute on function private.write_audit(text, text, uuid, jsonb, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Editability: an operator may edit application data only while the
-- application is a draft or admin has asked for changes.
-- ---------------------------------------------------------------------
create or replace function private.operator_is_editable(p_operator_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.operators o
    where o.id = p_operator_id
      and o.application_status in ('draft', 'changes_requested')
  );
$$;

revoke execute on function private.operator_is_editable(uuid) from public, anon;
grant execute on function private.operator_is_editable(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Guard: only platform admins (or trusted definer/service code, which runs
-- as a role other than authenticated/anon) may change status, application
-- status, review and approval columns. Closes the gap where
-- operators_update_own let an operator_admin approve themselves.
-- SECURITY INVOKER on purpose: current_user is 'authenticated' for direct
-- client writes and the function owner inside SECURITY DEFINER workflow RPCs.
-- ---------------------------------------------------------------------
create or replace function private.protect_operator_workflow()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;
  end if;
  if public.am_i_platform_admin() then
    return new;
  end if;

  if new.status is distinct from old.status
    or new.application_status is distinct from old.application_status
    or new.submitted_at is distinct from old.submitted_at
    or new.reviewed_at is distinct from old.reviewed_at
    or new.reviewed_by is distinct from old.reviewed_by
    or new.review_reason is distinct from old.review_reason
    or new.approved_by is distinct from old.approved_by
    or new.approved_at is distinct from old.approved_at
    or new.rating is distinct from old.rating then
    raise exception 'Only platform admins can change operator approval or review fields';
  end if;
  return new;
end;
$$;

create trigger protect_operator_workflow
  before update on public.operators
  for each row execute function private.protect_operator_workflow();

-- ---------------------------------------------------------------------
-- Operator profile (business details beyond the operators row)
-- ---------------------------------------------------------------------
create table public.operator_profiles (
  operator_id uuid primary key references public.operators (id) on delete cascade,
  owner_name text,
  business_type_detail text,
  address text,
  contact_address text,
  city text,
  district text,
  state text,
  pin_code text,
  logo_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_profiles_pin_chk check (pin_code is null or pin_code ~ '^[1-9][0-9]{5}$')
);

create trigger set_updated_at
  before update on public.operator_profiles
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------
-- KYC & tax
-- ---------------------------------------------------------------------
create table public.operator_kyc (
  operator_id uuid primary key references public.operators (id) on delete cascade,
  pan_number text,
  gst_registered boolean,
  gstin text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_kyc_pan_chk check (pan_number is null or pan_number ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  constraint operator_kyc_gstin_chk check (
    gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
  ),
  constraint operator_kyc_gstin_requires_gst_chk check (gstin is null or gst_registered is true)
);

create trigger set_updated_at
  before update on public.operator_kyc
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------
-- Operator documents (PAN card, GST certificate, ID proof, ...)
-- One current row per (operator, doc_type); re-uploading replaces the file,
-- bumps version and resets verification to pending. 'other_registration'
-- may be uploaded more than once.
-- ---------------------------------------------------------------------
create table public.operator_documents (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id) on delete cascade,
  doc_type text not null,
  file_path text not null,
  file_name text,
  doc_number text,
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  version integer not null default 1,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index operator_documents_one_per_type_idx
  on public.operator_documents (operator_id, doc_type)
  where doc_type <> 'other_registration';
create index operator_documents_operator_id_idx on public.operator_documents (operator_id);
create index operator_documents_reviewed_by_idx on public.operator_documents (reviewed_by) where reviewed_by is not null;

create trigger set_updated_at
  before update on public.operator_documents
  for each row execute function private.set_updated_at();

-- Operators cannot set or change verification state. Replacing the file resets it.
create or replace function private.protect_operator_document_review()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('authenticated', 'anon') or public.am_i_platform_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.status := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.rejection_reason := null;
    new.version := 1;
    return new;
  end if;

  if new.file_path is distinct from old.file_path then
    new.status := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.rejection_reason := null;
    new.version := old.version + 1;
  elsif new.status is distinct from old.status
    or new.reviewed_by is distinct from old.reviewed_by
    or new.reviewed_at is distinct from old.reviewed_at
    or new.rejection_reason is distinct from old.rejection_reason
    or new.version is distinct from old.version then
    raise exception 'Only platform admins can change document verification';
  end if;
  return new;
end;
$$;

create trigger protect_operator_document_review
  before insert or update on public.operator_documents
  for each row execute function private.protect_operator_document_review();

-- ---------------------------------------------------------------------
-- Admin-configurable document requirements (operator- and bus-scoped).
-- `condition` keys understood for operator scope: gst_registered (bool),
-- business_type_in (array of operator_business_type). Bus-scope conditions
-- are added in the bus-document phase.
-- ---------------------------------------------------------------------
create table public.document_requirements (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('operator', 'bus')),
  doc_type text not null,
  label text not null,
  required boolean not null default true,
  condition jsonb not null default '{}'::jsonb,
  has_expiry boolean not null default false,
  sort_order integer not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (scope, doc_type)
);

create trigger set_updated_at
  before update on public.document_requirements
  for each row execute function private.set_updated_at();

insert into public.document_requirements (scope, doc_type, label, required, condition, has_expiry, sort_order) values
  ('operator', 'pan_card', 'PAN card', true, '{}', false, 10),
  ('operator', 'gst_certificate', 'GST registration certificate', true, '{"gst_registered": true}', false, 20),
  ('operator', 'id_proof', 'Authorized person identity / address proof', true, '{}', false, 30),
  ('operator', 'other_registration', 'Other business registration documents', false, '{}', false, 40);

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.operator_profiles enable row level security;
alter table public.operator_kyc enable row level security;
alter table public.operator_documents enable row level security;
alter table public.document_requirements enable row level security;

create policy operator_profiles_select on public.operator_profiles
  for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy operator_profiles_insert on public.operator_profiles
  for insert to authenticated
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_profiles_update on public.operator_profiles
  for update to authenticated
  using (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id))
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_profiles_admin_all on public.operator_profiles
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy operator_kyc_select on public.operator_kyc
  for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy operator_kyc_insert on public.operator_kyc
  for insert to authenticated
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_kyc_update on public.operator_kyc
  for update to authenticated
  using (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id))
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_kyc_admin_all on public.operator_kyc
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy operator_documents_select on public.operator_documents
  for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy operator_documents_insert on public.operator_documents
  for insert to authenticated
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_documents_update on public.operator_documents
  for update to authenticated
  using (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id))
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_documents_delete on public.operator_documents
  for delete to authenticated
  using (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_documents_admin_all on public.operator_documents
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy document_requirements_select on public.document_requirements
  for select to authenticated
  using (true);
create policy document_requirements_admin_all on public.document_requirements
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- ---------------------------------------------------------------------
-- Private storage bucket for operator KYC documents.
-- Path convention: <operator_id>/<doc_type>_<epoch_ms>.<ext>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'operator-documents', 'operator-documents', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png']
)
on conflict (id) do nothing;

create policy "operator-documents staff read" on storage.objects
  for select to authenticated
  using (bucket_id = 'operator-documents' and private.is_operator_staff(((storage.foldername(name))[1])::uuid));

create policy "operator-documents admin-operator write" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'operator-documents'
    and private.is_operator_admin(((storage.foldername(name))[1])::uuid)
    and private.operator_is_editable(((storage.foldername(name))[1])::uuid)
  );

create policy "operator-documents admin-operator update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'operator-documents'
    and private.is_operator_admin(((storage.foldername(name))[1])::uuid)
    and private.operator_is_editable(((storage.foldername(name))[1])::uuid)
  )
  with check (
    bucket_id = 'operator-documents'
    and private.is_operator_admin(((storage.foldername(name))[1])::uuid)
    and private.operator_is_editable(((storage.foldername(name))[1])::uuid)
  );

create policy "operator-documents admin-operator delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'operator-documents'
    and private.is_operator_admin(((storage.foldername(name))[1])::uuid)
    and private.operator_is_editable(((storage.foldername(name))[1])::uuid)
  );
-- Platform admins are already covered by the existing "storage admin all" policy.

-- ---------------------------------------------------------------------
-- Completeness (single source of truth for the app, admin and submit RPC).
-- ---------------------------------------------------------------------
create or replace function private.requirement_applies(
  p_condition jsonb,
  p_business_type public.operator_business_type,
  p_gst_registered boolean
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_condition is null or p_condition = '{}'::jsonb then
    return true;
  end if;
  if p_condition ? 'gst_registered'
     and (p_condition ->> 'gst_registered')::boolean is distinct from coalesce(p_gst_registered, false) then
    return false;
  end if;
  if p_condition ? 'business_type_in'
     and not (p_business_type::text in (select jsonb_array_elements_text(p_condition -> 'business_type_in'))) then
    return false;
  end if;
  return true;
end;
$$;

create or replace function private.completeness_item(
  p_items jsonb,
  p_key text,
  p_label text,
  p_section text,
  p_ok boolean
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select p_items || jsonb_build_array(jsonb_build_object(
    'key', p_key, 'label', p_label, 'section', p_section, 'ok', coalesce(p_ok, false)
  ));
$$;

create or replace function private.summarize_completeness(p_items jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'percent',
      case when jsonb_array_length(p_items) = 0 then 100
           else floor(100.0 * (select count(*) from jsonb_array_elements(p_items) i where (i ->> 'ok')::boolean)
                      / jsonb_array_length(p_items))::int end,
    'complete', not exists (select 1 from jsonb_array_elements(p_items) i where not (i ->> 'ok')::boolean),
    'missing', coalesce((select jsonb_agg(i ->> 'label') from jsonb_array_elements(p_items) i where not (i ->> 'ok')::boolean), '[]'::jsonb),
    'items', p_items
  );
$$;

create or replace function public.operator_completeness(p_operator_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_op public.operators;
  v_prof public.operator_profiles;
  v_kyc public.operator_kyc;
  v_items jsonb := '[]'::jsonb;
  v_req record;
begin
  if not (private.is_operator_staff(p_operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  select * into v_op from public.operators where id = p_operator_id;
  if v_op.id is null then
    raise exception 'Operator not found';
  end if;
  select * into v_prof from public.operator_profiles where operator_id = p_operator_id;
  select * into v_kyc from public.operator_kyc where operator_id = p_operator_id;

  -- Step 1: business information
  v_items := private.completeness_item(v_items, 'name', 'Business name', 'business', coalesce(btrim(v_op.name), '') <> '');
  v_items := private.completeness_item(v_items, 'legal_name', 'Legal business name', 'business', coalesce(btrim(v_op.legal_name), '') <> '');
  v_items := private.completeness_item(v_items, 'owner_name', 'Owner / authorized person name', 'business', coalesce(btrim(v_prof.owner_name), '') <> '');
  v_items := private.completeness_item(v_items, 'contact_phone', 'Mobile number', 'business', coalesce(btrim(v_op.contact_phone), '') <> '');
  v_items := private.completeness_item(v_items, 'contact_email', 'Email address', 'business', coalesce(btrim(v_op.contact_email), '') <> '');
  v_items := private.completeness_item(v_items, 'address', 'Business address', 'business', coalesce(btrim(v_prof.address), '') <> '');
  v_items := private.completeness_item(v_items, 'city', 'City', 'business', coalesce(btrim(v_prof.city), '') <> '');
  v_items := private.completeness_item(v_items, 'district', 'District', 'business', coalesce(btrim(v_prof.district), '') <> '');
  v_items := private.completeness_item(v_items, 'state', 'State / UT', 'business', coalesce(btrim(v_prof.state), '') <> '');
  v_items := private.completeness_item(v_items, 'pin_code', 'PIN code', 'business', v_prof.pin_code is not null);

  -- Step 2: KYC & tax. GST is only mandatory when the operator is GST registered.
  v_items := private.completeness_item(v_items, 'pan_number', 'PAN number', 'kyc', v_kyc.pan_number is not null);
  v_items := private.completeness_item(v_items, 'gst_registered', 'GST registration status', 'kyc', v_kyc.gst_registered is not null);
  if v_kyc.gst_registered is true then
    v_items := private.completeness_item(v_items, 'gstin', 'GSTIN', 'kyc', v_kyc.gstin is not null);
  end if;

  -- Required documents come from the admin-configurable table.
  for v_req in
    select dr.doc_type, dr.label
    from public.document_requirements dr
    where dr.scope = 'operator'
      and dr.active
      and dr.required
      and private.requirement_applies(dr.condition, v_op.business_type, v_kyc.gst_registered)
    order by dr.sort_order
  loop
    v_items := private.completeness_item(
      v_items, 'doc:' || v_req.doc_type, v_req.label, 'documents',
      exists (
        select 1 from public.operator_documents d
        where d.operator_id = p_operator_id and d.doc_type = v_req.doc_type and d.status <> 'rejected'
      )
    );
  end loop;

  return private.summarize_completeness(v_items);
end;
$$;

revoke execute on function public.operator_completeness(uuid) from public, anon;
grant execute on function public.operator_completeness(uuid) to authenticated;
revoke execute on function private.requirement_applies(jsonb, public.operator_business_type, boolean) from public, anon;
revoke execute on function private.completeness_item(jsonb, text, text, text, boolean) from public, anon;
revoke execute on function private.summarize_completeness(jsonb) from public, anon;
grant execute on function private.requirement_applies(jsonb, public.operator_business_type, boolean) to authenticated;
grant execute on function private.completeness_item(jsonb, text, text, text, boolean) to authenticated;
grant execute on function private.summarize_completeness(jsonb) to authenticated;
