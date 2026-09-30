-- =========================================================================
-- Operator bank/payout details and payment mandate (Phase 3)
-- =========================================================================

-- ---------------------------------------------------------------------
-- Requirements can now belong to a step of the onboarding flow so each
-- step only lists its own documents (kyc = step 2, bank = step 3,
-- mandate = step 4). Existing rows default to 'kyc'.
-- ---------------------------------------------------------------------
alter table public.document_requirements
  add column step text not null default 'kyc' check (step in ('kyc', 'bank', 'mandate'));

insert into public.document_requirements (scope, doc_type, label, required, condition, has_expiry, sort_order, step) values
  ('operator', 'cancelled_cheque', 'Cancelled cheque', true, '{}', false, 50, 'bank'),
  ('operator', 'bank_additional', 'Additional bank document', false, '{}', false, 60, 'bank'),
  ('operator', 'payment_mandate', 'Signed & stamped payment mandate', true, '{}', false, 70, 'mandate');

-- ---------------------------------------------------------------------
-- Bank & payout details (one row per operator)
-- ---------------------------------------------------------------------
create table public.operator_bank_details (
  operator_id uuid primary key references public.operators (id) on delete cascade,
  account_holder_name text,
  bank_name text,
  branch_name text,
  bank_address text,
  account_number text,
  ifsc text,
  micr text,
  account_type text check (account_type in ('savings', 'current', 'other')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_bank_account_number_chk check (account_number is null or account_number ~ '^[0-9]{9,18}$'),
  constraint operator_bank_ifsc_chk check (ifsc is null or ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  constraint operator_bank_micr_chk check (micr is null or micr ~ '^[0-9]{9}$')
);

create trigger set_updated_at
  before update on public.operator_bank_details
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------
-- Payment mandate: the signed/stamped form uploaded by the operator.
-- One current row per operator; replacing the file resets verification.
-- ---------------------------------------------------------------------
create table public.operator_payment_mandates (
  operator_id uuid primary key references public.operators (id) on delete cascade,
  file_path text not null,
  file_name text,
  template_version text,
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  version integer not null default 1,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index operator_payment_mandates_reviewed_by_idx
  on public.operator_payment_mandates (reviewed_by) where reviewed_by is not null;

create trigger set_updated_at
  before update on public.operator_payment_mandates
  for each row execute function private.set_updated_at();

create or replace function private.protect_mandate_review()
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
    raise exception 'Only platform admins can change mandate verification';
  end if;
  return new;
end;
$$;

create trigger protect_mandate_review
  before insert or update on public.operator_payment_mandates
  for each row execute function private.protect_mandate_review();

-- ---------------------------------------------------------------------
-- RLS (same model as the Phase 2 tables)
-- ---------------------------------------------------------------------
alter table public.operator_bank_details enable row level security;
alter table public.operator_payment_mandates enable row level security;

create policy operator_bank_select on public.operator_bank_details
  for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy operator_bank_insert on public.operator_bank_details
  for insert to authenticated
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_bank_update on public.operator_bank_details
  for update to authenticated
  using (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id))
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_bank_admin_all on public.operator_bank_details
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy operator_mandates_select on public.operator_payment_mandates
  for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy operator_mandates_insert on public.operator_payment_mandates
  for insert to authenticated
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_mandates_update on public.operator_payment_mandates
  for update to authenticated
  using (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id))
  with check (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_mandates_delete on public.operator_payment_mandates
  for delete to authenticated
  using (private.is_operator_admin(operator_id) and private.operator_is_editable(operator_id));
create policy operator_mandates_admin_all on public.operator_payment_mandates
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- The mandate file is stored in the existing private `operator-documents`
-- bucket (path <operator_id>/payment_mandate_<epoch_ms>.<ext>); its storage
-- policies from Phase 2 already scope access to the operator folder.

-- ---------------------------------------------------------------------
-- Completeness: now covers bank details, bank documents and the mandate.
-- Replaces the Phase 2 definition (same signature).
-- ---------------------------------------------------------------------
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
  v_bank public.operator_bank_details;
  v_mandate public.operator_payment_mandates;
  v_items jsonb := '[]'::jsonb;
  v_req record;
  v_ok boolean;
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
  select * into v_bank from public.operator_bank_details where operator_id = p_operator_id;
  select * into v_mandate from public.operator_payment_mandates where operator_id = p_operator_id;

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

  -- Step 3: bank & payout
  v_items := private.completeness_item(v_items, 'bank_holder', 'Account holder name', 'bank', coalesce(btrim(v_bank.account_holder_name), '') <> '');
  v_items := private.completeness_item(v_items, 'bank_name', 'Bank name', 'bank', coalesce(btrim(v_bank.bank_name), '') <> '');
  v_items := private.completeness_item(v_items, 'bank_branch', 'Branch name', 'bank', coalesce(btrim(v_bank.branch_name), '') <> '');
  v_items := private.completeness_item(v_items, 'bank_account', 'Account number', 'bank', v_bank.account_number is not null);
  v_items := private.completeness_item(v_items, 'bank_ifsc', 'IFSC', 'bank', v_bank.ifsc is not null);
  v_items := private.completeness_item(v_items, 'bank_account_type', 'Account type', 'bank', v_bank.account_type is not null);

  -- Required documents come from the admin-configurable table. The mandate
  -- requirement is satisfied by the mandate row, all others by operator_documents.
  for v_req in
    select dr.doc_type, dr.label, dr.step
    from public.document_requirements dr
    where dr.scope = 'operator'
      and dr.active
      and dr.required
      and private.requirement_applies(dr.condition, v_op.business_type, v_kyc.gst_registered)
    order by dr.sort_order
  loop
    if v_req.doc_type = 'payment_mandate' then
      v_ok := v_mandate.operator_id is not null and v_mandate.status <> 'rejected';
    else
      v_ok := exists (
        select 1 from public.operator_documents d
        where d.operator_id = p_operator_id and d.doc_type = v_req.doc_type and d.status <> 'rejected'
      );
    end if;
    v_items := private.completeness_item(
      v_items,
      'doc:' || v_req.doc_type,
      v_req.label,
      case v_req.step when 'bank' then 'bank' when 'mandate' then 'mandate' else 'documents' end,
      v_ok
    );
  end loop;

  return private.summarize_completeness(v_items);
end;
$$;

revoke execute on function public.operator_completeness(uuid) from public, anon;
grant execute on function public.operator_completeness(uuid) to authenticated;
