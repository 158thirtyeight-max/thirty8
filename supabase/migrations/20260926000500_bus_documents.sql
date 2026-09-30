-- =========================================================================
-- Bus documents (Phase 6): per-bus RC, insurance, fitness, permit, PUC, tax
-- and other transport documents, each with number, issue/expiry dates, file
-- and verification status. Requirements are admin-configurable.
-- =========================================================================

-- Bus-scoped requirements get their own step value.
alter table public.document_requirements drop constraint document_requirements_step_check;
alter table public.document_requirements
  add constraint document_requirements_step_check check (step in ('kyc', 'bank', 'mandate', 'bus'));

insert into public.document_requirements (scope, doc_type, label, required, condition, has_expiry, sort_order, step) values
  ('bus', 'rc', 'Registration Certificate (RC)', true, '{}', false, 10, 'bus'),
  ('bus', 'insurance', 'Vehicle insurance', true, '{}', true, 20, 'bus'),
  ('bus', 'fitness', 'Fitness certificate', true, '{}', true, 30, 'bus'),
  ('bus', 'permit', 'Route / tourist permit', true, '{}', true, 40, 'bus'),
  ('bus', 'puc', 'Pollution Under Control (PUC)', true, '{}', true, 50, 'bus'),
  ('bus', 'road_tax', 'Road / vehicle tax', false, '{}', true, 60, 'bus'),
  ('bus', 'other_transport', 'Other transport document', false, '{}', false, 70, 'bus');

-- Bus-scope condition matcher. Supported keys: bus_type_in, bus_type_not_in.
create or replace function private.bus_requirement_applies(p_condition jsonb, p_bus_type text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_condition is null or p_condition = '{}'::jsonb then
    return true;
  end if;
  if p_condition ? 'bus_type_in'
     and not (p_bus_type in (select jsonb_array_elements_text(p_condition -> 'bus_type_in'))) then
    return false;
  end if;
  if p_condition ? 'bus_type_not_in'
     and (p_bus_type in (select jsonb_array_elements_text(p_condition -> 'bus_type_not_in'))) then
    return false;
  end if;
  return true;
end;
$$;

revoke execute on function private.bus_requirement_applies(jsonb, text) from public, anon;
grant execute on function private.bus_requirement_applies(jsonb, text) to authenticated;

create or replace function private.bus_operator_id(p_bus_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select operator_id from public.buses where id = p_bus_id;
$$;

revoke execute on function private.bus_operator_id(uuid) from public, anon;
grant execute on function private.bus_operator_id(uuid) to authenticated;

-- ---------------------------------------------------------------------
create table public.bus_documents (
  id uuid primary key default gen_random_uuid(),
  bus_id uuid not null references public.buses (id) on delete cascade,
  doc_type text not null,
  doc_number text,
  issue_date date,
  expiry_date date,
  bucket text not null default 'bus-documents' check (bucket in ('bus-documents', 'insurance-documents')),
  file_path text not null,
  file_name text,
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  version integer not null default 1,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bus_documents_dates_chk check (issue_date is null or expiry_date is null or expiry_date >= issue_date)
);

create unique index bus_documents_one_per_type_idx
  on public.bus_documents (bus_id, doc_type)
  where doc_type <> 'other_transport';
create index bus_documents_bus_id_idx on public.bus_documents (bus_id);
create index bus_documents_expiry_idx on public.bus_documents (expiry_date) where expiry_date is not null;
create index bus_documents_reviewed_by_idx on public.bus_documents (reviewed_by) where reviewed_by is not null;

create trigger set_updated_at
  before update on public.bus_documents
  for each row execute function private.set_updated_at();

-- Backfill: carry existing bus insurance policies (which live in the older
-- operator_insurance table and the insurance-documents bucket) into
-- bus_documents. The originals are left untouched.
insert into public.bus_documents (
  bus_id, doc_type, doc_number, issue_date, expiry_date, bucket, file_path, file_name,
  status, reviewed_by, reviewed_at, rejection_reason
)
select distinct on (oi.bus_id)
  oi.bus_id, 'insurance', oi.policy_number, oi.valid_from, oi.valid_until,
  'insurance-documents', oi.document_url, split_part(oi.document_url, '/', 2),
  case when oi.status = 'rejected' then 'rejected'
       when oi.status in ('verified', 'expired') then 'verified'
       else 'pending' end,
  oi.verified_by, oi.verified_at, oi.rejection_reason
from public.operator_insurance oi
join public.buses b on b.id = oi.bus_id
where oi.bus_id is not null and oi.document_url is not null
order by oi.bus_id, oi.valid_until desc;

-- Operators cannot set or change verification; replacing the file resets it.
create or replace function private.protect_bus_document_review()
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

  if new.bus_id is distinct from old.bus_id then
    raise exception 'A document cannot be moved to another bus';
  end if;

  if new.file_path is distinct from old.file_path
     or new.doc_number is distinct from old.doc_number
     or new.issue_date is distinct from old.issue_date
     or new.expiry_date is distinct from old.expiry_date then
    -- Any change to the document itself needs re-verification.
    new.status := 'pending';
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.rejection_reason := null;
    new.version := old.version + 1;
    if new.file_path is distinct from old.file_path then
      new.bucket := 'bus-documents';
    end if;
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

create trigger protect_bus_document_review
  before insert or update on public.bus_documents
  for each row execute function private.protect_bus_document_review();

-- ---------------------------------------------------------------------
-- RLS: staff of the bus's approved operator manage documents (renewals are
-- allowed at any lifecycle stage and always reset verification); admin all.
-- Deleting is limited to buses still being set up.
-- ---------------------------------------------------------------------
alter table public.bus_documents enable row level security;

create policy bus_documents_select on public.bus_documents
  for select to authenticated
  using (private.is_operator_staff(private.bus_operator_id(bus_id)) or private.is_platform_admin());

create policy bus_documents_insert on public.bus_documents
  for insert to authenticated
  with check (
    private.is_operator_staff(private.bus_operator_id(bus_id))
    and private.operator_is_approved(private.bus_operator_id(bus_id))
  );

create policy bus_documents_update on public.bus_documents
  for update to authenticated
  using (
    private.is_operator_staff(private.bus_operator_id(bus_id))
    and private.operator_is_approved(private.bus_operator_id(bus_id))
  )
  with check (
    private.is_operator_staff(private.bus_operator_id(bus_id))
    and private.operator_is_approved(private.bus_operator_id(bus_id))
  );

create policy bus_documents_delete on public.bus_documents
  for delete to authenticated
  using (
    private.is_operator_staff(private.bus_operator_id(bus_id))
    and exists (
      select 1 from public.buses b
      where b.id = bus_documents.bus_id
        and (b.lifecycle_status in ('draft', 'changes_requested') or b.is_legacy)
    )
  );

create policy bus_documents_admin_all on public.bus_documents
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- ---------------------------------------------------------------------
-- Private bucket. Path: <operator_id>/<bus_id>/<doc_type>_<epoch_ms>.<ext>
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'bus-documents', 'bus-documents', false, 10485760,
  array['application/pdf', 'image/jpeg', 'image/png']
)
on conflict (id) do nothing;

create policy "bus-documents staff read" on storage.objects
  for select to authenticated
  using (bucket_id = 'bus-documents' and private.is_operator_staff(((storage.foldername(name))[1])::uuid));

create policy "bus-documents staff write" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'bus-documents'
    and private.is_operator_staff(((storage.foldername(name))[1])::uuid)
    and private.operator_is_approved(((storage.foldername(name))[1])::uuid)
  );

create policy "bus-documents staff update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'bus-documents'
    and private.is_operator_staff(((storage.foldername(name))[1])::uuid)
    and private.operator_is_approved(((storage.foldername(name))[1])::uuid)
  )
  with check (
    bucket_id = 'bus-documents'
    and private.is_operator_staff(((storage.foldername(name))[1])::uuid)
  );

create policy "bus-documents staff delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'bus-documents'
    and private.is_operator_staff(((storage.foldername(name))[1])::uuid)
  );
-- Platform admins are covered by the existing "storage admin all" policy.

-- ---------------------------------------------------------------------
-- Expiry tracking. Docs past their expiry date are reported as expired and
-- treated as missing by readiness checks; nothing is auto-suspended.
-- ---------------------------------------------------------------------
create or replace view public.bus_document_expiry
with (security_invoker = true) as
select
  d.id, d.bus_id, b.operator_id, b.registration_number, d.doc_type, d.expiry_date,
  (d.expiry_date - current_date) as days_to_expiry,
  case
    when d.expiry_date is null then 'no_expiry'
    when d.expiry_date < current_date then 'expired'
    when d.expiry_date <= current_date + 30 then 'expiring_soon'
    else 'valid'
  end as expiry_state
from public.bus_documents d
join public.buses b on b.id = d.bus_id;

grant select on public.bus_document_expiry to authenticated;

-- Documents that a bus needs (configured + applicable), with their state.
create or replace function private.bus_document_checks(p_bus_id uuid)
returns table (doc_type text, label text, required boolean, has_expiry boolean,
               present boolean, status text, expired boolean, ok boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select
    dr.doc_type, dr.label, dr.required, dr.has_expiry,
    d.id is not null as present,
    d.status,
    coalesce(d.expiry_date < current_date, false) as expired,
    (d.id is not null and d.status = 'verified' and not coalesce(d.expiry_date < current_date, false)) as ok
  from public.buses b
  join public.document_requirements dr
    on dr.scope = 'bus' and dr.active and private.bus_requirement_applies(dr.condition, b.bus_type)
  left join public.bus_documents d on d.bus_id = b.id and d.doc_type = dr.doc_type
  where b.id = p_bus_id
  order by dr.sort_order;
$$;

revoke execute on function private.bus_document_checks(uuid) from public, anon;
grant execute on function private.bus_document_checks(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Admin verifies / rejects a bus document
-- ---------------------------------------------------------------------
create or replace function public.admin_review_bus_document(
  p_doc_id uuid,
  p_action text,
  p_reason text default null
)
returns public.bus_documents
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc public.bus_documents;
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

  select * into v_doc from public.bus_documents where id = p_doc_id for update;
  if v_doc.id is null then
    raise exception 'Document not found';
  end if;
  if p_action = 'verify' and v_doc.expiry_date is not null and v_doc.expiry_date < current_date then
    raise exception 'This document has already expired and cannot be verified';
  end if;
  v_before := jsonb_build_object('status', v_doc.status, 'rejection_reason', v_doc.rejection_reason);

  update public.bus_documents
  set status = case p_action when 'verify' then 'verified' else 'rejected' end,
      reviewed_by = (select auth.uid()), reviewed_at = now(),
      rejection_reason = case p_action when 'reject' then v_reason else null end
  where id = p_doc_id returning * into v_doc;

  perform private.write_audit(
    'bus_document.' || p_action, 'bus_document', p_doc_id, v_before,
    jsonb_build_object('bus_id', v_doc.bus_id, 'operator_id', private.bus_operator_id(v_doc.bus_id),
                       'doc_type', v_doc.doc_type, 'status', v_doc.status, 'reason', v_reason)
  );
  return v_doc;
end;
$$;

revoke execute on function public.admin_review_bus_document(uuid, text, text) from public, anon;
grant execute on function public.admin_review_bus_document(uuid, text, text) to authenticated;
