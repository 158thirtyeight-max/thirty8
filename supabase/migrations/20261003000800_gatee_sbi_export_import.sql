-- =========================================================================
-- Gate E: SBI bulk-payment export, bank-result (UTR) import, maker-checker, reconciliation exceptions
--
--   Settlement is MANUAL: an admin exports an immutable file, uploads it to SBI Corporate Internet Banking
--   (outside this system) and later imports the bank's result. Nothing here moves money or simulates a bank.
--
--   export   approved batch(es) -> immutable snapshot (content + SHA-256), batch becomes `exported`.
--            Re-exporting the same batches returns the same snapshot; a batch is in at most one export.
--            The column layout is a configurable template (`settlement_export_template`); SBI's exact bulk format
--            is NOT confirmed (template.confirmed = false) and must be checked against SBI's sample before live use.
--   import   preview -> validate -> confirm. A file (by hash) is applied once; matching is by batch reference,
--            amount and account; UTRs are unique; only fully matched rows change anything; everything else becomes
--            a reconciliation exception and is never forced to match.
--   paid     only from a matched bank row with a UTR (or an explicit zero-net netting settlement): earnings ->
--            settled, adjustments -> settled, recoveries reduced, ledger event 4 posted.
--   maker-checker (setting settlement_maker_checker, default on): whoever approved a batch cannot confirm its payment.
--
-- Reversible: supabase/rollbacks/20261003000800_gatee_sbi_export_import.down.sql
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. export template (setting) + validation
-- ---------------------------------------------------------------------
insert into public.platform_settings (key, value) values
  ('settlement_export_template', jsonb_build_object(
    'confirmed', false,
    'format', 'csv',
    'columns', jsonb_build_array(
      jsonb_build_object('header', 'Beneficiary Name', 'field', 'beneficiary_name'),
      jsonb_build_object('header', 'Account Number', 'field', 'account_number'),
      jsonb_build_object('header', 'IFSC', 'field', 'ifsc'),
      jsonb_build_object('header', 'Amount', 'field', 'amount'),
      jsonb_build_object('header', 'Payment Mode', 'value', 'NEFT'),
      jsonb_build_object('header', 'Narration', 'field', 'narration'),
      jsonb_build_object('header', 'Reference', 'field', 'reference'))))
on conflict (key) do nothing;

create or replace function private.validate_export_template(p_template jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare c jsonb;
begin
  if jsonb_typeof(p_template -> 'columns') <> 'array' or jsonb_array_length(p_template -> 'columns') = 0 then
    raise exception 'The export template needs at least one column';
  end if;
  for c in select * from jsonb_array_elements(p_template -> 'columns') loop
    if nullif(btrim(c ->> 'header'), '') is null then raise exception 'Every export column needs a header'; end if;
    if (c ->> 'field') is null and (c ->> 'value') is null then raise exception 'Column "%" needs a field or a fixed value', c ->> 'header'; end if;
    if (c ->> 'field') is not null and (c ->> 'field') not in
       ('beneficiary_name', 'account_number', 'ifsc', 'bank_name', 'branch_name', 'amount', 'amount_paise', 'narration', 'reference') then
      raise exception 'Unknown export field %', c ->> 'field';
    end if;
  end loop;
end;
$$;

do $patch$
declare
  v_def text;
  v_a constant text := $q$elsif p_key = 'settlement_provider' then$q$;
begin
  v_def := pg_get_functiondef('public.admin_set_platform_setting(text, jsonb)'::regprocedure);
  if position(v_a in v_def) = 0 then raise exception 'Gate E: admin_set_platform_setting text drifted'; end if;
  execute replace(v_def, v_a, $q$elsif p_key = 'settlement_export_template' then
      perform private.validate_export_template(p_value);
    $q$ || v_a);
end
$patch$;

create or replace function private.csv_cell(p_value text)
returns text language sql immutable set search_path = '' as $$
  select case when p_value is null then ''
              when p_value ~ '[",\r\n]' then '"' || replace(p_value, '"', '""') || '"'
              else p_value end;
$$;

-- ---------------------------------------------------------------------
-- 2. tables
-- ---------------------------------------------------------------------
create table public.settlement_exports (
  id uuid primary key default gen_random_uuid(),
  file_name text not null,
  content text not null,
  sha256 text not null,
  row_count integer not null,
  total_cents bigint not null,
  template jsonb not null,
  template_confirmed boolean not null default false,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create table public.settlement_export_rows (
  export_id uuid not null references public.settlement_exports (id),
  settlement_id uuid not null unique references public.settlements (id),
  line_no integer not null,
  amount_cents bigint not null,
  primary key (export_id, line_no)
);
alter table public.settlements add column if not exists export_id uuid references public.settlement_exports (id);

create or replace function private.export_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'export_immutable: an exported settlement file cannot be changed' using errcode = '55000';
end;
$$;
create trigger settlement_exports_immutable before update or delete on public.settlement_exports
  for each row execute function private.export_immutable();
create trigger settlement_export_rows_immutable before update or delete on public.settlement_export_rows
  for each row execute function private.export_immutable();

create table public.settlement_payments (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.settlements (id),
  provider text not null check (provider in ('manual_sbi', 'internal', 'razorpay_route', 'razorpayx')),
  amount_cents bigint not null check (amount_cents >= 0),
  status text not null check (status in ('paid', 'failed')),
  utr text,
  bank_paid_on date,
  import_row_id uuid,
  idempotency_key text not null unique,
  retry_count integer not null default 0,
  failure_reason text,
  provider_response jsonb,
  confirmed_by uuid references public.profiles (id),
  confirmed_at timestamptz not null default now()
);
create unique index settlement_payments_utr_idx on public.settlement_payments (utr) where utr is not null and status = 'paid';
create index settlement_payments_settlement_idx on public.settlement_payments (settlement_id);

create table public.bank_result_imports (
  id uuid primary key default gen_random_uuid(),
  file_name text,
  file_hash text not null,
  status text not null default 'previewed' check (status in ('previewed', 'confirmed')),
  row_count integer not null default 0,
  summary jsonb not null default '{}'::jsonb,
  uploaded_by uuid references public.profiles (id),
  uploaded_at timestamptz not null default now(),
  confirmed_by uuid references public.profiles (id),
  confirmed_at timestamptz
);
create unique index bank_result_imports_confirmed_hash_idx on public.bank_result_imports (file_hash) where status = 'confirmed';
create table public.bank_result_rows (
  id uuid primary key default gen_random_uuid(),
  import_id uuid not null references public.bank_result_imports (id) on delete cascade,
  line_no integer not null,
  raw jsonb not null,
  batch_reference text,
  account_digits text,
  amount_cents bigint,
  utr text,
  bank_status text check (bank_status in ('success', 'failed')),
  failure_reason text,
  paid_on date,
  match_status text not null check (match_status in ('matched', 'unmatched', 'amount_mismatch', 'account_mismatch', 'duplicate_utr',
    'duplicate_row', 'already_paid', 'batch_not_exported', 'missing_utr', 'invalid_row')),
  settlement_id uuid references public.settlements (id),
  applied boolean not null default false
);
create index bank_result_rows_import_idx on public.bank_result_rows (import_id, line_no);

create table public.reconciliation_runs (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'internal',
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  found_count integer not null default 0,
  summary jsonb not null default '{}'::jsonb,
  started_by uuid references public.profiles (id)
);

alter table public.settlement_exports enable row level security;
alter table public.settlement_export_rows enable row level security;
alter table public.settlement_payments enable row level security;
alter table public.bank_result_imports enable row level security;
alter table public.bank_result_rows enable row level security;
alter table public.reconciliation_runs enable row level security;
revoke all on public.settlement_exports, public.settlement_export_rows, public.settlement_payments,
  public.bank_result_imports, public.bank_result_rows, public.reconciliation_runs from anon, authenticated;
-- file contents hold full account numbers: no client reads of exports; admins read metadata through RPCs
grant select on public.settlement_payments, public.bank_result_imports, public.bank_result_rows, public.reconciliation_runs to authenticated;
create policy settlement_payments_select on public.settlement_payments for select to authenticated
  using (private.is_platform_admin() or exists (select 1 from public.settlements s where s.id = settlement_id and private.is_operator_admin(s.operator_id)));
create policy bank_result_imports_admin_select on public.bank_result_imports for select to authenticated using (private.is_platform_admin());
create policy bank_result_rows_admin_select on public.bank_result_rows for select to authenticated using (private.is_platform_admin());
create policy reconciliation_runs_admin_select on public.reconciliation_runs for select to authenticated using (private.is_platform_admin());

-- ---------------------------------------------------------------------
-- 3. export
-- ---------------------------------------------------------------------
create or replace function public.admin_export_settlement_file(p_settlement_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
  s public.settlements;
  b public.settlement_beneficiaries;
  v_tpl jsonb;
  v_cols jsonb;
  c jsonb;
  v_lines text := '';
  v_cells text[];
  v_val text;
  v_content text;
  v_hash text;
  v_export uuid := gen_random_uuid();
  v_name text;
  v_total bigint := 0;
  v_n integer := 0;
  v_existing uuid;
  v_tz text := private.cfg_text('settlement_timezone', 'Asia/Kolkata');
  v_block text;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required to export payments' using errcode = '42501'; end if;
  if p_settlement_ids is null or array_length(p_settlement_ids, 1) is null then raise exception 'Select at least one settlement'; end if;
  select array_agg(distinct x order by x) into v_ids from unnest(p_settlement_ids) x;

  perform 1 from public.settlements where id = any (v_ids) order by id for update;
  if (select count(*) from public.settlements where id = any (v_ids)) <> array_length(v_ids, 1) then raise exception 'Settlement not found'; end if;

  -- idempotent: the same batches, already exported together, return the same immutable file
  select (array_agg(export_id))[1] into v_existing from public.settlements where id = any (v_ids) and status = 'exported';
  if v_existing is not null then
    if (select count(*) from public.settlements where id = any (v_ids) and export_id = v_existing and status = 'exported') = array_length(v_ids, 1)
       and (select count(*) from public.settlement_export_rows where export_id = v_existing) = array_length(v_ids, 1) then
      perform private.write_audit('settlement_export.reopen', 'settlement_export', v_existing, null, jsonb_build_object('settlements', v_ids));
      return (select jsonb_build_object('export_id', e.id, 'file_name', e.file_name, 'sha256', e.sha256, 'row_count', e.row_count,
                'total_cents', e.total_cents, 'template_confirmed', e.template_confirmed, 'content', e.content, 'already_exported', true)
              from public.settlement_exports e where e.id = v_existing);
    end if;
    raise exception 'already_exported: one or more of these settlements are already in another export file';
  end if;

  v_tpl := private.cfg_template();
  perform private.validate_export_template(v_tpl);
  v_cols := v_tpl -> 'columns';

  for c in select * from jsonb_array_elements(v_cols) loop
    v_cells := coalesce(v_cells, '{}'::text[]) || private.csv_cell(c ->> 'header');
  end loop;
  v_lines := array_to_string(v_cells, ',') || E'\n';

  for s in select * from public.settlements where id = any (v_ids) order by reference loop
    if s.status <> 'approved' then raise exception 'settlement_not_approved: % is %', s.reference, s.status; end if;
    if s.net_payable_cents <= 0 then raise exception 'zero_net_batch: % has nothing to pay; settle it with admin_settle_zero_batch', s.reference; end if;
    select * into b from public.settlement_beneficiaries where settlement_id = s.id;
    if b.settlement_id is null then raise exception 'beneficiary_not_frozen: % has no frozen beneficiary', s.reference; end if;
    v_block := private.payout_block_reason(s.operator_id);
    if v_block in ('operator_not_active', 'payout_on_hold') then raise exception '%: % cannot be exported', v_block, s.reference; end if;
    if exists (
      select 1 from public.operator_earnings e
      join public.orders o on o.orderable_type = 'booking' and o.orderable_id = e.booking_id
      join public.payments p on p.order_id = o.id
      join public.refunds r on r.payment_id = p.id and r.status in ('requested', 'approved', 'submitted_to_provider')
     where e.settlement_id = s.id) then
      raise exception 'refund_pending_in_batch: % has an unresolved refund', s.reference;
    end if;

    v_n := v_n + 1;
    v_total := v_total + s.net_payable_cents;
    v_cells := '{}'::text[];
    for c in select * from jsonb_array_elements(v_cols) loop
      v_val := case
        when c ->> 'value' is not null then c ->> 'value'
        when c ->> 'field' = 'beneficiary_name' then b.account_holder_name
        when c ->> 'field' = 'account_number' then b.account_number
        when c ->> 'field' = 'ifsc' then b.ifsc
        when c ->> 'field' = 'bank_name' then b.bank_name
        when c ->> 'field' = 'branch_name' then b.branch_name
        when c ->> 'field' = 'amount' then to_char(s.net_payable_cents / 100.0, 'FM999999990.00')
        when c ->> 'field' = 'amount_paise' then s.net_payable_cents::text
        when c ->> 'field' in ('narration', 'reference') then s.reference
        end;
      v_cells := v_cells || private.csv_cell(v_val);
    end loop;
    v_lines := v_lines || array_to_string(v_cells, ',') || E'\n';
  end loop;

  v_content := v_lines;
  v_hash := encode(extensions.digest(convert_to(v_content, 'UTF8'), 'sha256'), 'hex');
  v_name := 'thirty8-settlement-' || to_char(now() at time zone v_tz, 'YYYYMMDD-HH24MISS') || '-' || left(v_hash, 8) || '.csv';

  insert into public.settlement_exports (id, file_name, content, sha256, row_count, total_cents, template, template_confirmed, created_by)
  values (v_export, v_name, v_content, v_hash, v_n, v_total, v_tpl, coalesce((v_tpl ->> 'confirmed')::boolean, false), (select auth.uid()));
  insert into public.settlement_export_rows (export_id, settlement_id, line_no, amount_cents)
  select v_export, s2.id, row_number() over (order by s2.reference), s2.net_payable_cents from public.settlements s2 where s2.id = any (v_ids);
  update public.settlements set status = 'exported', exported_at = now(), export_id = v_export where id = any (v_ids);

  perform private.write_audit('settlement_export.create', 'settlement_export', v_export, null,
    jsonb_build_object('settlements', v_ids, 'rows', v_n, 'total_cents', v_total, 'sha256', v_hash,
                       'template_confirmed', coalesce((v_tpl ->> 'confirmed')::boolean, false)));
  return jsonb_build_object('export_id', v_export, 'file_name', v_name, 'sha256', v_hash, 'row_count', v_n, 'total_cents', v_total,
    'template_confirmed', coalesce((v_tpl ->> 'confirmed')::boolean, false), 'content', v_content, 'already_exported', false);
end;
$$;

create or replace function private.cfg_template()
returns jsonb language sql stable security definer set search_path = '' as $$
  select value from public.platform_settings where key = 'settlement_export_template';
$$;
revoke execute on function private.cfg_template() from public, anon, authenticated;

create or replace function public.admin_get_settlement_export(p_export_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare e public.settlement_exports;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into e from public.settlement_exports where id = p_export_id;
  if e.id is null then raise exception 'Export not found'; end if;
  perform private.write_audit('settlement_export.download', 'settlement_export', e.id, null, jsonb_build_object('sha256', e.sha256));
  return jsonb_build_object('export_id', e.id, 'file_name', e.file_name, 'sha256', e.sha256, 'row_count', e.row_count,
    'total_cents', e.total_cents, 'template_confirmed', e.template_confirmed, 'content', e.content,
    'settlements', (select jsonb_agg(jsonb_build_object('settlement_id', r.settlement_id, 'reference', s.reference, 'amount_cents', r.amount_cents) order by r.line_no)
                      from public.settlement_export_rows r join public.settlements s on s.id = r.settlement_id where r.export_id = e.id));
end;
$$;

create or replace function public.admin_list_settlement_exports()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'not_authorized' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('export_id', e.id, 'file_name', e.file_name, 'sha256', e.sha256, 'row_count', e.row_count,
            'total_cents', e.total_cents, 'template_confirmed', e.template_confirmed, 'created_at', e.created_at) order by e.created_at desc)
          from public.settlement_exports e), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. marking a batch paid / failed (the only writers of those states)
-- ---------------------------------------------------------------------
create or replace function private.settlement_mark_paid(
  p_settlement_id uuid, p_provider text, p_utr text, p_paid_on date, p_import_row uuid, p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.settlements;
  v_pay uuid;
  v_lines jsonb;
  v_debit bigint;
  r record;
begin
  select * into s from public.settlements where id = p_settlement_id for update;
  if s.id is null then raise exception 'Settlement not found'; end if;
  if not (s.status = 'exported' or (p_provider = 'internal' and s.status = 'approved')) then
    raise exception 'settlement_not_payable: % is %', s.reference, s.status;
  end if;

  insert into public.settlement_payments (settlement_id, provider, amount_cents, status, utr, bank_paid_on, import_row_id, idempotency_key, confirmed_by)
  values (s.id, p_provider, s.net_payable_cents, 'paid', p_utr, p_paid_on, p_import_row, 'paid:' || s.id, p_actor)
  returning id into v_pay;

  update public.operator_earnings set status = 'settled' where settlement_id = s.id and status = 'in_batch';
  update public.operator_adjustments set status = 'settled' where settlement_id = s.id and status = 'in_batch';
  for r in select recovery_id, -net_cents as taken from public.settlement_items where settlement_id = s.id and kind = 'recovery_netting' loop
    update public.operator_recovery
       set recovered_cents = recovered_cents + r.taken,
           status = case when recovered_cents + r.taken >= amount_cents then 'recovered' else 'partially_recovered' end
     where id = r.recovery_id;
  end loop;

  -- event 4 (+ recovery netting): the operator payable is discharged by the bank payout and by the netted recovery
  v_debit := s.net_payable_cents + s.recovery_netted_cents;
  if v_debit > 0 then
    v_lines := jsonb_build_array(jsonb_build_object('account', 'operator_payable', 'side', 'debit', 'amount_cents', v_debit, 'operator_id', s.operator_id));
    if s.net_payable_cents > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'settlement_bank', 'side', 'credit', 'amount_cents', s.net_payable_cents));
    end if;
    if s.recovery_netted_cents > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'operator_receivable', 'side', 'credit', 'amount_cents', s.recovery_netted_cents, 'operator_id', s.operator_id));
    end if;
    perform private.post_journal('settlement_payment:' || v_pay || ':paid', 'settlement_paid', v_lines,
      'Settlement ' || s.reference || ' paid', 'settlement', s.id);
  end if;

  update public.settlements
     set status = 'paid', paid_cents = net_payable_cents, txn_reference = p_utr,
         method = case p_provider when 'manual_sbi' then 'sbi_bulk_payment' else p_provider end,
         completed_at = now(), bank_paid_at = coalesce(p_paid_on::timestamptz, now()), initiated_at = coalesce(initiated_at, exported_at, now()),
         failure_reason = null
   where id = s.id;
  perform private.write_audit('settlement.paid', 'settlement', s.id, jsonb_build_object('status', s.status),
    jsonb_build_object('status', 'paid', 'utr', p_utr, 'net_payable_cents', s.net_payable_cents, 'netted_cents', s.recovery_netted_cents));
  return v_pay;
end;
$$;

create or replace function private.settlement_mark_failed(p_settlement_id uuid, p_reason text, p_import_row uuid, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare s public.settlements;
begin
  select * into s from public.settlements where id = p_settlement_id for update;
  if s.status <> 'exported' then raise exception 'settlement_not_payable: % is %', s.reference, s.status; end if;
  insert into public.settlement_payments (settlement_id, provider, amount_cents, status, import_row_id, idempotency_key, failure_reason, confirmed_by)
  values (s.id, 'manual_sbi', s.net_payable_cents, 'failed', p_import_row, 'failed:' || coalesce(p_import_row::text, s.id::text), p_reason, p_actor)
  on conflict (idempotency_key) do nothing;
  update public.settlements set status = 'failed', failure_reason = p_reason, completed_at = null where id = s.id;
  perform private.write_audit('settlement.failed', 'settlement', s.id, jsonb_build_object('status', s.status),
    jsonb_build_object('status', 'failed', 'reason', p_reason));
end;
$$;
revoke execute on function private.settlement_mark_paid(uuid, text, text, date, uuid, uuid), private.settlement_mark_failed(uuid, text, uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. bank result import: preview -> confirm
-- ---------------------------------------------------------------------
create or replace function public.admin_preview_bank_result(p_file_name text, p_rows jsonb, p_file_text text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_import uuid;
  v_existing public.bank_result_imports;
  e jsonb;
  v_i integer := 0;
  v_ref text; v_acct text; v_cents bigint; v_utr text; v_bs text; v_fail text; v_paid date;
  v_match text; s public.settlements; b public.settlement_beneficiaries;
  v_seen_utr text[] := '{}'; v_seen_ref text[] := '{}';
  v_row uuid;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'The bank result has no rows'; end if;
  v_hash := encode(extensions.digest(convert_to(coalesce(p_file_text, p_rows::text), 'UTF8'), 'sha256'), 'hex');

  select * into v_existing from public.bank_result_imports where file_hash = v_hash and status = 'confirmed';
  if v_existing.id is not null then
    return jsonb_build_object('import_id', v_existing.id, 'status', 'confirmed', 'already_imported', true, 'summary', v_existing.summary);
  end if;
  delete from public.bank_result_imports where file_hash = v_hash and status = 'previewed';   -- a re-preview starts fresh

  insert into public.bank_result_imports (file_name, file_hash, row_count, uploaded_by)
  values (p_file_name, v_hash, jsonb_array_length(p_rows), (select auth.uid())) returning id into v_import;

  for e in select * from jsonb_array_elements(p_rows) loop
    v_i := v_i + 1;
    v_match := null; s := null; b := null; v_cents := null; v_paid := null; v_bs := null;
    v_ref := nullif(upper(btrim(e ->> 'reference')), '');
    v_acct := nullif(regexp_replace(coalesce(e ->> 'account', ''), '[^0-9]', '', 'g'), '');
    v_utr := nullif(btrim(e ->> 'utr'), '');
    v_fail := nullif(btrim(e ->> 'failure_reason'), '');
    begin
      v_cents := case when e ->> 'amount_cents' is not null then (e ->> 'amount_cents')::bigint
                      when e ->> 'amount' is not null then round((e ->> 'amount')::numeric * 100)::bigint end;
      v_paid := nullif(e ->> 'paid_on', '')::date;
    exception when others then v_match := 'invalid_row'; end;
    v_bs := case lower(btrim(coalesce(e ->> 'status', '')))
              when 'success' then 'success' when 'paid' then 'success' when 'processed' then 'success' when 'credited' then 'success'
              when 'failed' then 'failed' when 'rejected' then 'failed' when 'returned' then 'failed' when 'failure' then 'failed'
              else null end;
    if v_bs is null or v_ref is null then v_match := coalesce(v_match, 'invalid_row'); end if;

    if v_match is null then
      select * into s from public.settlements where reference = v_ref;
      if s.id is null then v_match := 'unmatched';
      elsif s.status = 'paid' then v_match := 'already_paid';
      elsif s.status <> 'exported' then v_match := 'batch_not_exported';
      elsif v_bs = 'success' and v_utr is null then v_match := 'missing_utr';
      elsif v_bs = 'success' and (v_utr = any (v_seen_utr) or exists (select 1 from public.settlement_payments where utr = v_utr and status = 'paid')) then v_match := 'duplicate_utr';
      elsif v_bs = 'success' and v_ref = any (v_seen_ref) then v_match := 'duplicate_row';
      elsif v_bs = 'success' and v_cents is distinct from s.net_payable_cents then v_match := 'amount_mismatch';
      else
        select * into b from public.settlement_beneficiaries where settlement_id = s.id;
        if v_acct is not null and (b.settlement_id is null or length(v_acct) < 4 or right(b.account_number, length(v_acct)) <> v_acct) then
          v_match := 'account_mismatch';
        else
          v_match := 'matched';
        end if;
      end if;
    end if;

    if v_match = 'matched' and v_bs = 'success' then v_seen_utr := v_seen_utr || v_utr; v_seen_ref := v_seen_ref || v_ref; end if;
    insert into public.bank_result_rows (import_id, line_no, raw, batch_reference, account_digits, amount_cents, utr, bank_status, failure_reason, paid_on, match_status, settlement_id)
    values (v_import, v_i, e, v_ref, v_acct, v_cents, v_utr, v_bs, v_fail, v_paid, v_match, s.id);
  end loop;

  update public.bank_result_imports
     set summary = (select coalesce(jsonb_object_agg(match_status, n), '{}'::jsonb) from (select match_status, count(*) n from public.bank_result_rows where import_id = v_import group by 1) q)
   where id = v_import;
  perform private.write_audit('bank_import.preview', 'bank_import', v_import, null, jsonb_build_object('file', p_file_name, 'sha256', v_hash, 'rows', v_i));
  return jsonb_build_object('import_id', v_import, 'status', 'previewed', 'already_imported', false,
    'summary', (select summary from public.bank_result_imports where id = v_import),
    'rows', (select jsonb_agg(jsonb_build_object('line_no', line_no, 'reference', batch_reference, 'amount_cents', amount_cents, 'utr', utr,
              'bank_status', bank_status, 'match_status', match_status) order by line_no) from public.bank_result_rows where import_id = v_import));
end;
$$;

create or replace function public.admin_confirm_bank_result(p_import_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  i public.bank_result_imports;
  r public.bank_result_rows;
  s public.settlements;
  v_mc boolean := coalesce(private.cfg_text('settlement_maker_checker', 'true')::boolean, true);
  v_paid integer := 0; v_failed integer := 0; v_exc integer := 0;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into i from public.bank_result_imports where id = p_import_id for update;
  if i.id is null then raise exception 'Import not found'; end if;
  if i.status = 'confirmed' then
    return jsonb_build_object('import_id', i.id, 'status', 'confirmed', 'already_confirmed', true, 'summary', i.summary);
  end if;

  -- maker-checker first, so a violation applies nothing at all
  if v_mc then
    for r in select * from public.bank_result_rows where import_id = i.id and match_status = 'matched' order by line_no loop
      select * into s from public.settlements where id = r.settlement_id;
      if s.approved_by = (select auth.uid()) then
        raise exception 'maker_checker_violation: you approved % and cannot confirm its payment; ask another full admin', s.reference;
      end if;
    end loop;
  end if;

  for r in select * from public.bank_result_rows where import_id = i.id order by line_no for update loop
    if r.match_status = 'matched' and r.bank_status = 'success' then
      perform private.settlement_mark_paid(r.settlement_id, 'manual_sbi', r.utr, r.paid_on, r.id, (select auth.uid()));
      update public.bank_result_rows set applied = true where id = r.id;
      v_paid := v_paid + 1;
    elsif r.match_status = 'matched' and r.bank_status = 'failed' then
      perform private.settlement_mark_failed(r.settlement_id, coalesce(r.failure_reason, 'Rejected by the bank'), r.id, (select auth.uid()));
      update public.bank_result_rows set applied = true where id = r.id;
      v_failed := v_failed + 1;
    else
      perform private.raise_exception_record('bank_row_' || r.match_status, 'critical', 'bank_import_row', i.id || ':' || r.line_no,
        jsonb_build_object('import_id', i.id, 'line_no', r.line_no, 'reference', r.batch_reference, 'amount_cents', r.amount_cents, 'utr', r.utr));
      v_exc := v_exc + 1;
    end if;
  end loop;

  update public.bank_result_imports set status = 'confirmed', confirmed_by = (select auth.uid()), confirmed_at = now() where id = i.id;
  perform private.write_audit('bank_import.confirm', 'bank_import', i.id, null,
    jsonb_build_object('paid', v_paid, 'failed', v_failed, 'exceptions', v_exc));
  return jsonb_build_object('import_id', i.id, 'status', 'confirmed', 'paid', v_paid, 'failed', v_failed, 'exceptions', v_exc);
end;
$$;

-- a batch whose recoveries consumed the whole payable has no bank line: settle the netting explicitly
create or replace function public.admin_settle_zero_batch(p_settlement_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare s public.settlements; v_mc boolean := coalesce(private.cfg_text('settlement_maker_checker', 'true')::boolean, true);
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required'; end if;
  select * into s from public.settlements where id = p_settlement_id for update;
  if s.id is null then raise exception 'Settlement not found'; end if;
  if s.status <> 'approved' or s.net_payable_cents <> 0 then raise exception 'not_a_zero_net_batch: status %, net % paise', s.status, s.net_payable_cents; end if;
  if v_mc and s.approved_by = (select auth.uid()) then
    raise exception 'maker_checker_violation: you approved % and cannot settle it; ask another full admin', s.reference;
  end if;
  perform private.settlement_mark_paid(s.id, 'internal', 'NETTING-' || s.reference, current_date, null, (select auth.uid()));
  perform private.write_audit('settlement.zero_net', 'settlement', s.id, null, jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('id', s.id, 'status', 'paid');
end;
$$;

-- ---------------------------------------------------------------------
-- 6. reconciliation (internal detectors; provider comparison is Gate G). Exceptions are raised, never corrected.
-- ---------------------------------------------------------------------
create or replace function private.run_reconciliation(p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run uuid;
  r record;
  n_unconfirmed integer; n_overdue integer := 0; n_unbalanced integer := 0; n_hash integer := 0; n_payable integer := 0; n_paid integer := 0;
begin
  insert into public.reconciliation_runs (started_by) values (p_by) returning id into v_run;
  n_unconfirmed := private.detect_captured_unconfirmed();

  for r in select id, reference, exported_at from public.settlements where status = 'exported' and exported_at < now() - interval '3 days' loop
    perform private.raise_exception_record('settlement_awaiting_bank_result', 'warning', 'settlement', r.id::text,
      jsonb_build_object('reference', r.reference, 'exported_at', r.exported_at));
    n_overdue := n_overdue + 1;
  end loop;

  for r in
    select e.journal_id, sum(e.amount_cents) filter (where e.side = 'debit') d, sum(e.amount_cents) filter (where e.side = 'credit') c
      from public.ledger_entries e group by e.journal_id
     having coalesce(sum(e.amount_cents) filter (where e.side = 'debit'), 0) <> coalesce(sum(e.amount_cents) filter (where e.side = 'credit'), 0)
  loop
    perform private.raise_exception_record('ledger_unbalanced', 'critical', 'ledger_journal', r.journal_id::text, jsonb_build_object('debits', r.d, 'credits', r.c));
    n_unbalanced := n_unbalanced + 1;
  end loop;

  for r in select x.id, x.file_name from public.settlement_exports x
            where x.sha256 <> encode(extensions.digest(convert_to(x.content, 'UTF8'), 'sha256'), 'hex') loop
    perform private.raise_exception_record('export_hash_mismatch', 'critical', 'settlement_export', r.id::text, jsonb_build_object('file', r.file_name));
    n_hash := n_hash + 1;
  end loop;

  -- what the ledger says we owe each operator must equal what the sub-ledgers say
  for r in
    with led as (
      select e.operator_id, sum(case when e.side = 'credit' then e.amount_cents else -e.amount_cents end) as balance
        from public.ledger_entries e join public.ledger_accounts a on a.id = e.account_id
       where a.code = 'operator_payable' and e.operator_id is not null group by e.operator_id),
    exp as (
      select operator_id, sum(v) as expected from (
        select operator_id, operator_net_cents as v from public.operator_earnings
         where eligible_journal_id is not null and status in ('eligible', 'on_hold', 'in_batch')
        union all select operator_id, amount_cents from public.operator_adjustments where status in ('open', 'in_batch')) u group by operator_id)
    select coalesce(l.operator_id, x.operator_id) as operator_id, coalesce(l.balance, 0) as ledger, coalesce(x.expected, 0) as expected
      from led l full join exp x on x.operator_id = l.operator_id
     where coalesce(l.balance, 0) <> coalesce(x.expected, 0)
  loop
    perform private.raise_exception_record('operator_payable_mismatch', 'critical', 'operator', r.operator_id::text,
      jsonb_build_object('ledger_cents', r.ledger, 'expected_cents', r.expected));
    n_payable := n_payable + 1;
  end loop;

  for r in
    select s.id, s.reference, s.net_payable_cents from public.settlements s
     where s.status = 'paid' and not exists (
       select 1 from public.settlement_payments p where p.settlement_id = s.id and p.status = 'paid' and p.amount_cents = s.net_payable_cents)
  loop
    perform private.raise_exception_record('settlement_payment_mismatch', 'critical', 'settlement', r.id::text,
      jsonb_build_object('reference', r.reference, 'net_payable_cents', r.net_payable_cents));
    n_paid := n_paid + 1;
  end loop;

  update public.reconciliation_runs
     set finished_at = now(),
         found_count = n_unconfirmed + n_overdue + n_unbalanced + n_hash + n_payable + n_paid,
         summary = jsonb_build_object('captured_unconfirmed', n_unconfirmed, 'bank_result_overdue', n_overdue, 'ledger_unbalanced', n_unbalanced,
                                      'export_hash_mismatch', n_hash, 'operator_payable_mismatch', n_payable, 'settlement_payment_mismatch', n_paid)
   where id = v_run;
  return (select jsonb_build_object('run_id', id, 'found', found_count, 'summary', summary) from public.reconciliation_runs where id = v_run);
end;
$$;
revoke execute on function private.run_reconciliation(uuid) from public, anon, authenticated;

create or replace function private.cron_reconciliation()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.run_reconciliation(null);
end;
$$;
revoke execute on function private.cron_reconciliation() from public, anon, authenticated;
select cron.schedule('daily-reconciliation', '30 21 * * *', $$select private.cron_reconciliation();$$);

create or replace function public.admin_run_reconciliation()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  return private.run_reconciliation((select auth.uid()));
end;
$$;

-- an exception is resolved or ignored by a person, with a reason; the underlying records are never edited
create or replace function public.admin_resolve_exception(p_exception_id uuid, p_status text, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare x public.reconciliation_exceptions;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if p_status not in ('resolved', 'ignored') then raise exception 'Status must be resolved or ignored'; end if;
  if nullif(btrim(p_note), '') is null then raise exception 'A resolution note is required'; end if;
  select * into x from public.reconciliation_exceptions where id = p_exception_id for update;
  if x.id is null then raise exception 'Exception not found'; end if;
  if x.status <> 'open' then raise exception 'exception_closed: status is %', x.status; end if;
  update public.reconciliation_exceptions
     set status = p_status, resolved_by = (select auth.uid()), resolved_at = now(), resolution_note = btrim(p_note) where id = x.id;
  perform private.write_audit('reconciliation.' || p_status, 'reconciliation_exception', x.id,
    jsonb_build_object('kind', x.kind, 'entity_id', x.entity_id), jsonb_build_object('note', btrim(p_note)));
end;
$$;

revoke execute on function
  public.admin_export_settlement_file(uuid[]), public.admin_get_settlement_export(uuid), public.admin_list_settlement_exports(),
  public.admin_preview_bank_result(text, jsonb, text), public.admin_confirm_bank_result(uuid), public.admin_settle_zero_batch(uuid, text),
  public.admin_run_reconciliation(), public.admin_resolve_exception(uuid, text, text)
  from public, anon;
grant execute on function
  public.admin_export_settlement_file(uuid[]), public.admin_get_settlement_export(uuid), public.admin_list_settlement_exports(),
  public.admin_preview_bank_result(text, jsonb, text), public.admin_confirm_bank_result(uuid), public.admin_settle_zero_batch(uuid, text),
  public.admin_run_reconciliation(), public.admin_resolve_exception(uuid, text, text)
  to authenticated;
