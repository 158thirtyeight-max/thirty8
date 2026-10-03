-- =========================================================================
-- Gate B: append-only double-entry financial ledger
--
--   * ledger_accounts   fixed chart of accounts (reference data, not business rates)
--   * ledger_journals   one row per business event, unique `source_event_key`
--                       => the same event can never be posted twice
--   * ledger_entries    debit/credit lines (integer paise), immutable
--
-- Rules enforced in the database:
--   - total debits = total credits per journal (checked by private.post_journal
--     AND by a deferred constraint trigger as defence in depth)
--   - journals/entries can never be updated, deleted or truncated; corrections
--     are reversal journals (admin_reverse_journal, once per journal)
--   - the only writer is private.post_journal (direct inserts are refused)
--   - clients have no write access; only platform admins can read
--
-- Event hooks wired in this gate (posting matrix in the plan, section 1.3):
--   1  payment captured           Dr razorpay_clearing   Cr booking_liability
--   3  refund approved            Dr booking_liability   Cr refund_payable
--   3b refund processed           Dr refund_payable      Cr razorpay_clearing
-- Events 2 (boarding), 4 (settlement paid), 5-7 (refund after boarding/settlement,
-- recovery) are added by Gates C / C2 / D / E.
--
-- Reversible: supabase/rollbacks/20261003000400_gateb_ledger.down.sql
-- =========================================================================

create type public.ledger_account_type as enum ('asset', 'liability', 'revenue', 'expense');

create table public.ledger_accounts (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  type public.ledger_account_type not null,
  description text,
  created_at timestamptz not null default now()
);

insert into public.ledger_accounts (code, name, type, description) values
  ('razorpay_clearing',   'Razorpay clearing',          'asset',     'Money collected by / refunded through Razorpay and not yet reconciled to the bank'),
  ('booking_liability',   'Booking liability',          'liability', 'Customer money held for tickets not yet earned by boarding'),
  ('operator_payable',    'Operator payable',           'liability', 'Operator share earned on boarding and not yet paid out (per operator)'),
  ('platform_commission', 'Platform commission',        'revenue',   'thirty8 commission recognised on boarding'),
  ('settlement_bank',     'Settlement bank',            'asset',     'Operator payouts made from the settlement bank account'),
  ('refund_payable',      'Refunds payable',            'liability', 'Approved customer refunds not yet processed by the provider'),
  ('operator_receivable', 'Operator receivable',        'asset',     'Amounts recoverable from operators after refunds on settled earnings (per operator)'),
  ('gateway_fees',        'Payment gateway fees',       'expense',   'Razorpay fees (reserved for future use)');

create table public.ledger_journals (
  id uuid primary key default gen_random_uuid(),
  source_event_key text not null unique,
  event_type text not null,
  description text,
  ref_type text,
  ref_id uuid,
  total_cents bigint not null check (total_cents > 0),
  reverses_journal_id uuid unique references public.ledger_journals (id),
  posted_by uuid,
  posted_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);
create index ledger_journals_ref_idx on public.ledger_journals (ref_type, ref_id);
create index ledger_journals_event_idx on public.ledger_journals (event_type, posted_at desc);

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references public.ledger_journals (id),
  account_id uuid not null references public.ledger_accounts (id),
  side text not null check (side in ('debit', 'credit')),
  amount_cents bigint not null check (amount_cents > 0),
  operator_id uuid references public.operators (id),
  created_at timestamptz not null default now()
);
create index ledger_entries_journal_idx on public.ledger_entries (journal_id);
create index ledger_entries_account_idx on public.ledger_entries (account_id, operator_id);
create index ledger_entries_operator_idx on public.ledger_entries (operator_id) where operator_id is not null;

-- ---------------------------------------------------------------------
-- immutability + single writer + balance (defence in depth)
-- ---------------------------------------------------------------------
create or replace function private.ledger_block_change()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'ledger_immutable: posted ledger records cannot be updated or deleted; post a reversal journal instead'
    using errcode = '55000';
end;
$$;
create trigger ledger_journals_immutable before update or delete on public.ledger_journals
  for each row execute function private.ledger_block_change();
create trigger ledger_entries_immutable before update or delete on public.ledger_entries
  for each row execute function private.ledger_block_change();
create trigger ledger_journals_no_truncate before truncate on public.ledger_journals
  for each statement execute function private.ledger_block_change();
create trigger ledger_entries_no_truncate before truncate on public.ledger_entries
  for each statement execute function private.ledger_block_change();
create trigger ledger_accounts_immutable before delete on public.ledger_accounts
  for each row execute function private.ledger_block_change();

create or replace function private.ledger_require_writer()
returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(current_setting('thirty8.ledger_writer', true), '') <> 'on' then
    raise exception 'ledger_direct_write: ledger rows can only be created through private.post_journal'
      using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger ledger_journals_writer before insert on public.ledger_journals
  for each row execute function private.ledger_require_writer();
create trigger ledger_entries_writer before insert on public.ledger_entries
  for each row execute function private.ledger_require_writer();

create or replace function private.ledger_check_balance()
returns trigger language plpgsql set search_path = '' as $$
declare v_debit bigint; v_credit bigint; v_total bigint;
begin
  select coalesce(sum(amount_cents) filter (where side = 'debit'), 0),
         coalesce(sum(amount_cents) filter (where side = 'credit'), 0)
    into v_debit, v_credit
    from public.ledger_entries where journal_id = new.journal_id;
  select total_cents into v_total from public.ledger_journals where id = new.journal_id;
  if v_debit <> v_credit or v_debit <> v_total then
    raise exception 'ledger_unbalanced: journal % has debits % / credits % / total %', new.journal_id, v_debit, v_credit, v_total
      using errcode = '23514';
  end if;
  return null;
end;
$$;
create constraint trigger ledger_entries_balanced after insert on public.ledger_entries
  deferrable initially deferred
  for each row execute function private.ledger_check_balance();

-- ---------------------------------------------------------------------
-- the only writer
--   p_lines: [{"account":"<code>","side":"debit|credit","amount_cents":123,"operator_id":"<uuid>"?}, ...]
--   Idempotent on p_key: re-posting the same event returns the existing journal id;
--   re-posting it with a different total is a bug and raises.
-- ---------------------------------------------------------------------
create or replace function private.post_journal(
  p_key text,
  p_event_type text,
  p_lines jsonb,
  p_description text default null,
  p_ref_type text default null,
  p_ref_id uuid default null,
  p_reverses uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.ledger_journals;
  v_id uuid;
  v_line jsonb;
  v_debit bigint := 0;
  v_credit bigint := 0;
  v_account uuid;
  v_amount bigint;
begin
  if nullif(btrim(p_key), '') is null then raise exception 'ledger: source_event_key is required'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'ledger: a journal needs at least two lines';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_amount := (v_line ->> 'amount_cents')::bigint;
    if v_amount is null or v_amount <= 0 then
      raise exception 'ledger: line amounts must be positive integer paise (got %)', v_line ->> 'amount_cents';
    end if;
    if v_line ->> 'side' = 'debit' then v_debit := v_debit + v_amount;
    elsif v_line ->> 'side' = 'credit' then v_credit := v_credit + v_amount;
    else raise exception 'ledger: side must be debit or credit (got %)', v_line ->> 'side';
    end if;
  end loop;
  if v_debit <> v_credit then
    raise exception 'ledger_unbalanced: debits % <> credits % for %', v_debit, v_credit, p_key using errcode = '23514';
  end if;

  select * into v_existing from public.ledger_journals where source_event_key = p_key;
  if v_existing.id is not null then
    if v_existing.total_cents <> v_debit then
      raise exception 'ledger_key_conflict: % was already posted with total %, now %', p_key, v_existing.total_cents, v_debit;
    end if;
    return v_existing.id;
  end if;

  perform set_config('thirty8.ledger_writer', 'on', true);
  begin
    insert into public.ledger_journals (source_event_key, event_type, description, ref_type, ref_id, total_cents,
                                         reverses_journal_id, posted_by, metadata)
    values (p_key, p_event_type, p_description, p_ref_type, p_ref_id, v_debit, p_reverses, (select auth.uid()), p_metadata)
    on conflict (source_event_key) do nothing
    returning id into v_id;
    if v_id is null then   -- a concurrent worker posted it first
      perform set_config('thirty8.ledger_writer', 'off', true);
      select id into v_id from public.ledger_journals where source_event_key = p_key;
      return v_id;
    end if;

    for v_line in select * from jsonb_array_elements(p_lines) loop
      select id into v_account from public.ledger_accounts where code = v_line ->> 'account';
      if v_account is null then raise exception 'ledger: unknown account %', v_line ->> 'account'; end if;
      insert into public.ledger_entries (journal_id, account_id, side, amount_cents, operator_id)
      values (v_id, v_account, v_line ->> 'side', (v_line ->> 'amount_cents')::bigint, nullif(v_line ->> 'operator_id', '')::uuid);
    end loop;
  exception when others then
    perform set_config('thirty8.ledger_writer', 'off', true);
    raise;
  end;
  perform set_config('thirty8.ledger_writer', 'off', true);
  return v_id;
end;
$$;
revoke execute on function private.post_journal(text, text, jsonb, text, text, uuid, uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- event hooks (database triggers: cover every code path, not just today's functions)
-- ---------------------------------------------------------------------
create or replace function private.ledger_post_payment_captured(p_payment_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v public.payments;
begin
  select * into v from public.payments where id = p_payment_id;
  if v.id is null or v.amount_cents <= 0 then return null; end if;
  return private.post_journal(
    'payment:' || v.id || ':captured', 'payment_captured',
    jsonb_build_array(
      jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', v.amount_cents),
      jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', v.amount_cents)),
    'Payment captured ' || coalesce(v.razorpay_payment_id, v.id::text), 'payment', v.id);
end;
$$;

create or replace function private.ledger_post_refund_approved(p_refund_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v public.refunds;
begin
  select * into v from public.refunds where id = p_refund_id;
  if v.id is null or v.amount_cents <= 0 then return null; end if;
  return private.post_journal(
    'refund:' || v.id || ':approved', 'refund_approved',
    jsonb_build_array(
      jsonb_build_object('account', 'booking_liability', 'side', 'debit', 'amount_cents', v.amount_cents),
      jsonb_build_object('account', 'refund_payable', 'side', 'credit', 'amount_cents', v.amount_cents)),
    'Refund approved', 'refund', v.id);
end;
$$;

create or replace function private.ledger_post_refund_processed(p_refund_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v public.refunds;
begin
  select * into v from public.refunds where id = p_refund_id;
  if v.id is null or v.amount_cents <= 0 then return null; end if;
  perform private.ledger_post_refund_approved(p_refund_id);   -- idempotent: obligation exists before it is settled
  return private.post_journal(
    'refund:' || v.id || ':processed', 'refund_processed',
    jsonb_build_array(
      jsonb_build_object('account', 'refund_payable', 'side', 'debit', 'amount_cents', v.amount_cents),
      jsonb_build_object('account', 'razorpay_clearing', 'side', 'credit', 'amount_cents', v.amount_cents)),
    'Refund processed by provider', 'refund', v.id);
end;
$$;
revoke execute on function private.ledger_post_payment_captured(uuid), private.ledger_post_refund_approved(uuid),
  private.ledger_post_refund_processed(uuid) from public, anon, authenticated;

create or replace function private.ledger_payment_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('captured', 'duplicate_captured')
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform private.ledger_post_payment_captured(new.id);
  end if;
  return null;
end;
$$;
create trigger payments_ledger after insert or update of status on public.payments
  for each row execute function private.ledger_payment_trigger();

create or replace function private.ledger_refund_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or old.status is distinct from new.status then
    if new.status = 'approved' then
      perform private.ledger_post_refund_approved(new.id);
    elsif new.status = 'processed' then
      perform private.ledger_post_refund_processed(new.id);
    end if;
  end if;
  return null;
end;
$$;
create trigger refunds_ledger after insert or update of status on public.refunds
  for each row execute function private.ledger_refund_trigger();

-- ---------------------------------------------------------------------
-- backfill: post journals for payments/refunds that predate the ledger
-- (idempotent: keyed by event, so running it twice posts nothing new)
-- ---------------------------------------------------------------------
create or replace function private.ledger_backfill()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare r record; n integer := 0; v_before bigint;
begin
  select count(*) into v_before from public.ledger_journals;
  for r in select id from public.payments where status in ('captured', 'duplicate_captured', 'refunded') order by created_at loop
    perform private.ledger_post_payment_captured(r.id);
  end loop;
  for r in select id, status from public.refunds where status in ('approved', 'submitted_to_provider', 'processed') order by created_at loop
    if r.status = 'processed' then perform private.ledger_post_refund_processed(r.id);
    else perform private.ledger_post_refund_approved(r.id); end if;
  end loop;
  select count(*) - v_before into n from public.ledger_journals;
  return n;
end;
$$;
revoke execute on function private.ledger_backfill() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- corrections: reversal journals (admin only, once per journal)
-- ---------------------------------------------------------------------
create or replace function public.admin_reverse_journal(p_journal_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.ledger_journals;
  v_lines jsonb;
  v_id uuid;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required to reverse a journal'; end if;
  select * into v from public.ledger_journals where id = p_journal_id for update;
  if v.id is null then raise exception 'Journal not found'; end if;
  if v.reverses_journal_id is not null then raise exception 'ledger: a reversal journal cannot itself be reversed'; end if;
  if exists (select 1 from public.ledger_journals where reverses_journal_id = v.id) then
    raise exception 'ledger: journal % is already reversed', v.id;
  end if;

  select jsonb_agg(jsonb_build_object(
           'account', a.code,
           'side', case e.side when 'debit' then 'credit' else 'debit' end,
           'amount_cents', e.amount_cents,
           'operator_id', e.operator_id))
    into v_lines
    from public.ledger_entries e join public.ledger_accounts a on a.id = e.account_id
   where e.journal_id = v.id;

  v_id := private.post_journal('reversal:' || v.id, 'reversal', v_lines,
            'Reversal of ' || v.source_event_key || ': ' || btrim(p_reason), v.ref_type, v.ref_id, v.id,
            jsonb_build_object('reason', btrim(p_reason)));
  perform private.write_audit('ledger.reverse', 'ledger_journal', v.id, null,
    jsonb_build_object('reversal_journal_id', v_id, 'reason', btrim(p_reason), 'total_cents', v.total_cents));
  return v_id;
end;
$$;
revoke execute on function public.admin_reverse_journal(uuid, text) from public, anon;
grant execute on function public.admin_reverse_journal(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- RLS + reporting (admin read only; no client writes at all)
-- ---------------------------------------------------------------------
alter table public.ledger_accounts enable row level security;
alter table public.ledger_journals enable row level security;
alter table public.ledger_entries enable row level security;
revoke all on public.ledger_accounts, public.ledger_journals, public.ledger_entries from anon, authenticated;
grant select on public.ledger_accounts, public.ledger_journals, public.ledger_entries to authenticated;
create policy ledger_accounts_admin_select on public.ledger_accounts for select to authenticated using (private.is_platform_admin());
create policy ledger_journals_admin_select on public.ledger_journals for select to authenticated using (private.is_platform_admin());
create policy ledger_entries_admin_select on public.ledger_entries for select to authenticated using (private.is_platform_admin());

-- balance per account (and operator), natural-sign: assets/expenses = debits - credits, others = credits - debits
create view public.ledger_account_balances with (security_invoker = true) as
select a.code as account_code, a.name as account_name, a.type as account_type, e.operator_id,
       coalesce(sum(e.amount_cents) filter (where e.side = 'debit'), 0)::bigint as debit_cents,
       coalesce(sum(e.amount_cents) filter (where e.side = 'credit'), 0)::bigint as credit_cents,
       (case when a.type in ('asset', 'expense')
             then coalesce(sum(e.amount_cents) filter (where e.side = 'debit'), 0) - coalesce(sum(e.amount_cents) filter (where e.side = 'credit'), 0)
             else coalesce(sum(e.amount_cents) filter (where e.side = 'credit'), 0) - coalesce(sum(e.amount_cents) filter (where e.side = 'debit'), 0)
        end)::bigint as balance_cents
from public.ledger_accounts a
left join public.ledger_entries e on e.account_id = a.id
group by a.code, a.name, a.type, e.operator_id;
grant select on public.ledger_account_balances to authenticated;

-- backfill any existing money records (no-op on an empty database)
select private.ledger_backfill();
