-- =========================================================================
-- Gate D: weekly settlement engine (provider-independent, drafts only)
--
--   operator_earnings (eligible) + open operator_adjustments - recoveries  ->  one batch per operator & period
--
--   batch statuses: draft -> approved -> exported -> paid | partially_paid | failed ; side: on_hold, cancelled
--   (exported / paid / partially_paid / failed are set by the SBI export + bank-result import in Gate E; nothing here
--    can mark a batch paid)
--
--   * building is idempotent (unique operator + period) and race-safe (advisory lock + FOR UPDATE SKIP LOCKED);
--     the scheduler only ever creates DRAFTS, never approves or pays
--   * an earning joins a batch only if: eligible (boarded, captured payment, no refund/dispute/hold), operator
--     approved, no unresolved failed batch for the operator
--   * approval (full admin, checked inside the RPC) needs a verified payout profile whose bank details are unchanged
--     since verification; it re-checks refunds, then FREEZES the beneficiary (settlement_beneficiaries)
--   * open recoveries are netted at build time under a configurable cap and never push a batch below zero;
--     the rest carries forward. Adjustments (operator share of cancellation deductions) are credited.
--   * period, generated, approved, exported and bank-paid dates are separate columns
--   * a failed batch is never merged into a new one automatically: an admin cancels ("releases") it first
--
-- Reversible: supabase/rollbacks/20261003000700_gated_settlement_engine.down.sql
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. configuration (settings, not money rates)
-- ---------------------------------------------------------------------
insert into public.platform_settings (key, value) values
  ('settlement_timezone', '"Asia/Kolkata"'::jsonb),
  ('settlement_week_start_dow', '1'::jsonb),
  ('settlement_run_dow', '1'::jsonb),
  ('settlement_run_hour', '12'::jsonb),
  ('settlement_recovery_cap_bps', '10000'::jsonb),
  ('settlement_provider', '"manual_sbi"'::jsonb),
  ('settlement_maker_checker', 'true'::jsonb),
  ('razorpay_route_enabled', 'false'::jsonb)
on conflict (key) do nothing;

create or replace function private.cfg_text(p_key text, p_default text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select value #>> '{}' from public.platform_settings where key = p_key), p_default);
$$;
create or replace function private.cfg_int(p_key text, p_default integer)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::integer from public.platform_settings where key = p_key), p_default);
$$;
revoke execute on function private.cfg_text(text, text), private.cfg_int(text, integer) from public, anon, authenticated;

-- settlement / provider settings are money-moving configuration: full admin only, validated
create or replace function public.admin_set_platform_setting(p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_n numeric;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  if p_key not in (select key from public.platform_settings) then raise exception 'Unknown setting %', p_key; end if;

  if p_key like 'settlement\_%' or p_key like 'razorpay\_%' then
    if not private.is_full_admin() then raise exception 'not_authorized: full admin required for settlement settings' using errcode = '42501'; end if;
    if p_key in ('settlement_week_start_dow', 'settlement_run_dow') then
      v_n := (p_value #>> '{}')::numeric;
      if v_n is null or v_n < 1 or v_n > 7 or v_n <> floor(v_n) then raise exception 'Day of week must be 1 (Monday) to 7 (Sunday)'; end if;
    elsif p_key = 'settlement_run_hour' then
      v_n := (p_value #>> '{}')::numeric;
      if v_n is null or v_n < 0 or v_n > 23 or v_n <> floor(v_n) then raise exception 'Hour must be 0 to 23'; end if;
    elsif p_key = 'settlement_recovery_cap_bps' then
      v_n := (p_value #>> '{}')::numeric;
      if v_n is null or v_n < 0 or v_n > 10000 or v_n <> floor(v_n) then raise exception 'Recovery cap must be 0 to 10000 basis points'; end if;
    elsif p_key = 'settlement_timezone' then
      if not exists (select 1 from pg_timezone_names where name = p_value #>> '{}') then raise exception 'Unknown time zone'; end if;
    elsif p_key = 'settlement_provider' then
      if (p_value #>> '{}') not in ('manual_sbi', 'razorpay_route', 'razorpayx') then raise exception 'Unknown settlement provider'; end if;
      if (p_value #>> '{}') <> 'manual_sbi' then
        raise exception 'provider_not_configured: only manual_sbi can be selected until the provider is configured and verified';
      end if;
    elsif p_key in ('settlement_maker_checker', 'razorpay_route_enabled') then
      if jsonb_typeof(p_value) <> 'boolean' then raise exception 'Must be true or false'; end if;
      if p_key = 'razorpay_route_enabled' and (p_value #>> '{}')::boolean then
        raise exception 'provider_not_configured: Razorpay Route cannot be enabled until credentials and approval are verified';
      end if;
    end if;
  end if;

  update public.platform_settings set value = p_value, updated_by = (select auth.uid()), updated_at = now() where key = p_key;
  perform private.write_audit('platform_setting.set', 'platform_setting', null, null, jsonb_build_object('key', p_key, 'value', p_value));
end;
$$;

-- ---------------------------------------------------------------------
-- 2. operator payout profile (bank details stay in operator_bank_details; this is the verification state)
-- ---------------------------------------------------------------------
create table public.operator_payment_profiles (
  operator_id uuid primary key references public.operators (id) on delete cascade,
  payout_method text not null default 'manual_sbi' check (payout_method in ('manual_sbi', 'razorpay_route', 'razorpayx')),
  verification_status text not null default 'unverified' check (verification_status in ('unverified', 'verified', 'failed')),
  verified_hash text,
  verified_by uuid references public.profiles (id),
  verified_at timestamptz,
  verification_note text,
  payout_hold boolean not null default false,
  restriction_reason text,
  razorpay_account_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger set_updated_at before update on public.operator_payment_profiles
  for each row execute function private.set_updated_at();
alter table public.operator_payment_profiles enable row level security;
revoke all on public.operator_payment_profiles from anon, authenticated;
grant select on public.operator_payment_profiles to authenticated;
create policy operator_payment_profiles_select on public.operator_payment_profiles
  for select to authenticated using (private.is_platform_admin() or private.is_operator_admin(operator_id));

create or replace function private.bank_details_hash(p_operator_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select md5(coalesce(account_holder_name, '') || '|' || coalesce(account_number, '') || '|' || coalesce(ifsc, ''))
    from public.operator_bank_details where operator_id = p_operator_id;
$$;
revoke execute on function private.bank_details_hash(uuid) from public, anon, authenticated;

-- why an operator cannot be paid right now (null = payable)
create or replace function private.payout_block_reason(p_operator_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare p public.operator_payment_profiles; v_status text;
begin
  select status into v_status from public.operators where id = p_operator_id;
  if v_status is distinct from 'approved' then return 'operator_not_active'; end if;
  select * into p from public.operator_payment_profiles where operator_id = p_operator_id;
  if p.operator_id is null then return 'payment_profile_missing'; end if;
  if p.verification_status <> 'verified' then return 'payment_profile_not_verified'; end if;
  if p.payout_hold then return 'payout_on_hold'; end if;
  if p.verified_hash is distinct from private.bank_details_hash(p_operator_id) then return 'bank_details_changed_reverify'; end if;
  return null;
end;
$$;
revoke execute on function private.payout_block_reason(uuid) from public, anon, authenticated;

create or replace function public.admin_set_payment_profile_status(p_operator_id uuid, p_status text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare b public.operator_bank_details; v_before text;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if p_status not in ('verified', 'failed', 'unverified') then raise exception 'Invalid status'; end if;
  if not exists (select 1 from public.operators where id = p_operator_id) then raise exception 'Operator not found'; end if;
  if p_status in ('failed', 'unverified') and nullif(btrim(p_note), '') is null then raise exception 'A note is required'; end if;
  select * into b from public.operator_bank_details where operator_id = p_operator_id;
  if p_status = 'verified' and (b.operator_id is null or b.account_holder_name is null or b.account_number is null or b.ifsc is null) then
    raise exception 'bank_details_incomplete: holder name, account number and IFSC are required before verification';
  end if;
  insert into public.operator_payment_profiles (operator_id) values (p_operator_id) on conflict do nothing;
  select verification_status into v_before from public.operator_payment_profiles where operator_id = p_operator_id;
  update public.operator_payment_profiles
     set verification_status = p_status,
         verified_hash = case when p_status = 'verified' then private.bank_details_hash(p_operator_id) else null end,
         verified_by = case when p_status = 'verified' then (select auth.uid()) else null end,
         verified_at = case when p_status = 'verified' then now() else null end,
         verification_note = nullif(btrim(p_note), '')
   where operator_id = p_operator_id;
  perform private.write_audit('payment_profile.' || p_status, 'operator', p_operator_id,
    jsonb_build_object('status', v_before), jsonb_build_object('status', p_status, 'note', nullif(btrim(p_note), '')));
end;
$$;

create or replace function public.admin_set_payout_hold(p_operator_id uuid, p_hold boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if p_hold and nullif(btrim(p_reason), '') is null then raise exception 'A reason is required to hold payouts'; end if;
  insert into public.operator_payment_profiles (operator_id) values (p_operator_id) on conflict do nothing;
  update public.operator_payment_profiles
     set payout_hold = p_hold, restriction_reason = case when p_hold then btrim(p_reason) else null end
   where operator_id = p_operator_id;
  perform private.write_audit('payout_hold.' || case when p_hold then 'set' else 'clear' end, 'operator', p_operator_id, null,
    jsonb_build_object('reason', p_reason));
end;
$$;

-- masked view for the operator's admin (never the full account number)
create or replace function public.get_my_payment_profile(p_operator_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare p public.operator_payment_profiles; b public.operator_bank_details; v_block text;
begin
  perform private.finance_access(p_operator_id);
  select * into p from public.operator_payment_profiles where operator_id = p_operator_id;
  select * into b from public.operator_bank_details where operator_id = p_operator_id;
  v_block := private.payout_block_reason(p_operator_id);
  return jsonb_build_object(
    'payout_method', coalesce(p.payout_method, 'manual_sbi'),
    'verification_status', coalesce(p.verification_status, 'unverified'),
    'verified_at', p.verified_at,
    'settlement_eligible', v_block is null,
    'block_reason', v_block,
    'required_action', case v_block
      when 'payment_profile_missing' then 'Your bank details are awaiting verification by thirty8.'
      when 'payment_profile_not_verified' then coalesce(nullif(p.verification_note, ''), 'Your bank details are awaiting verification by thirty8.')
      when 'bank_details_changed_reverify' then 'Your bank details changed after verification. thirty8 must verify them again before the next payout.'
      when 'payout_on_hold' then 'Payouts are on hold. Please contact thirty8.'
      when 'operator_not_active' then 'Your operator account is not active.'
      else null end,
    'bank_name', b.bank_name,
    'account_holder', b.account_holder_name,
    'account_masked', case when b.account_number is null then null else repeat('X', greatest(length(b.account_number) - 4, 0)) || right(b.account_number, 4) end,
    'ifsc_masked', case when b.ifsc is null then null else left(b.ifsc, 4) || '*******' end);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. batch structure
-- ---------------------------------------------------------------------
alter table public.settlements drop constraint settlements_status_check;
alter table public.settlements
  add constraint settlements_status_check check (status in
    ('pending', 'processing', 'paid', 'failed', 'reversed', 'draft', 'approved', 'exported', 'partially_paid', 'on_hold', 'cancelled'));
alter table public.settlements alter column status set default 'draft';
alter table public.settlements
  add column if not exists generated_at timestamptz not null default now(),
  add column if not exists approved_by uuid references public.profiles (id),
  add column if not exists approved_at timestamptz,
  add column if not exists exported_at timestamptz,
  add column if not exists bank_paid_at timestamptz,
  add column if not exists status_before_hold text,
  add column if not exists hold_reason text,
  add column if not exists held_by uuid references public.profiles (id),
  add column if not exists held_at timestamptz,
  add column if not exists adjustment_credits_cents bigint not null default 0,
  add column if not exists recovery_netted_cents bigint not null default 0,
  add column if not exists cancelled_by uuid references public.profiles (id),
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancel_reason text;
create unique index settlements_operator_period_idx on public.settlements (operator_id, period_start, period_end) where status <> 'cancelled';

drop policy settlements_select on public.settlements;
create policy settlements_select on public.settlements
  for select to authenticated
  using (private.is_platform_admin() or (private.is_operator_admin(operator_id) and status <> 'draft'));

alter table public.settlement_items alter column booking_item_id drop not null;
alter table public.settlement_items
  add column if not exists earning_id uuid references public.operator_earnings (id),
  add column if not exists adjustment_id uuid references public.operator_adjustments (id),
  add column if not exists recovery_id uuid references public.operator_recovery (id),
  add column if not exists net_cents bigint;
update public.settlement_items
   set net_cents = case kind when 'sale' then fare_cents - commission_cents else -(fare_cents - commission_cents) end
 where net_cents is null;
alter table public.settlement_items alter column net_cents set not null;
alter table public.settlement_items drop constraint settlement_items_kind_check;
alter table public.settlement_items
  add constraint settlement_items_kind_check check (kind in ('sale', 'refund_adjustment', 'operator_adjustment', 'recovery_netting')),
  add constraint settlement_items_ref_chk check (
    (kind in ('sale', 'refund_adjustment') and booking_item_id is not null)
    or (kind = 'operator_adjustment' and adjustment_id is not null)
    or (kind = 'recovery_netting' and recovery_id is not null));
create unique index settlement_items_one_adjustment_credit_idx on public.settlement_items (adjustment_id) where kind = 'operator_adjustment';
create unique index settlement_items_recovery_per_batch_idx on public.settlement_items (settlement_id, recovery_id) where kind = 'recovery_netting';
create index settlement_items_earning_idx on public.settlement_items (earning_id) where earning_id is not null;

-- the beneficiary is frozen at approval; clients never read this table (admins get a masked RPC)
create table public.settlement_beneficiaries (
  settlement_id uuid primary key references public.settlements (id) on delete cascade,
  account_holder_name text not null,
  bank_name text,
  branch_name text,
  account_number text not null,
  ifsc text not null,
  account_type text,
  snapshot_hash text not null,
  frozen_at timestamptz not null default now(),
  frozen_by uuid references public.profiles (id)
);
alter table public.settlement_beneficiaries enable row level security;
revoke all on public.settlement_beneficiaries from anon, authenticated;

create table public.settlement_runs (
  id uuid primary key default gen_random_uuid(),
  period_start date not null,
  period_end date not null unique,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'completed', 'failed')),
  built_count integer not null default 0,
  summary jsonb not null default '{}'::jsonb,
  error text
);
alter table public.settlement_runs enable row level security;
revoke all on public.settlement_runs from anon, authenticated;
grant select on public.settlement_runs to authenticated;
create policy settlement_runs_admin_select on public.settlement_runs for select to authenticated using (private.is_platform_admin());

-- recovery already committed to a not-yet-final batch
create or replace function private.recovery_reserved(p_recovery_id uuid)
returns bigint language sql stable security definer set search_path = '' as $$
  select coalesce(sum(-si.net_cents), 0)::bigint
    from public.settlement_items si join public.settlements s on s.id = si.settlement_id
   where si.recovery_id = p_recovery_id and si.kind = 'recovery_netting'
     and s.status in ('draft', 'approved', 'exported', 'on_hold', 'partially_paid');
$$;
revoke execute on function private.recovery_reserved(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. build
-- ---------------------------------------------------------------------
create or replace function private.settlement_period(p_on timestamptz default now())
returns table (period_start date, period_end date)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text := private.cfg_text('settlement_timezone', 'Asia/Kolkata');
  v_wdow integer := private.cfg_int('settlement_week_start_dow', 1);
  v_today date := (p_on at time zone v_tz)::date;
  v_wk date;
begin
  v_wk := v_today - ((extract(isodow from v_today)::int - v_wdow + 7) % 7);
  period_end := v_wk - 1;
  period_start := period_end - 6;
  return next;
end;
$$;
revoke execute on function private.settlement_period(timestamptz) from public, anon, authenticated;

create or replace function private.build_operator_settlement(p_operator_id uuid, p_start date, p_end date, p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text := private.cfg_text('settlement_timezone', 'Asia/Kolkata');
  v_cutoff timestamptz := ((p_end + 1)::timestamp at time zone private.cfg_text('settlement_timezone', 'Asia/Kolkata'));
  v_cap integer := private.cfg_int('settlement_recovery_cap_bps', 10000);
  v_id uuid := gen_random_uuid();
  v_ref text;
  v_ids uuid[];
  v_adj uuid[];
  v_gross bigint := 0; v_comm bigint := 0; v_net bigint := 0;
  v_credits bigint := 0; v_pre bigint; v_room bigint; v_take bigint; v_avail bigint; v_netting bigint := 0;
  r record;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('settle:' || p_operator_id::text, 0)) then
    return jsonb_build_object('operator_id', p_operator_id, 'result', 'skipped', 'reason', 'locked_by_another_worker');
  end if;
  if exists (select 1 from public.settlements where operator_id = p_operator_id and period_start = p_start and period_end = p_end and status <> 'cancelled') then
    return jsonb_build_object('operator_id', p_operator_id, 'result', 'exists');
  end if;
  if (select status from public.operators where id = p_operator_id) is distinct from 'approved' then
    return jsonb_build_object('operator_id', p_operator_id, 'result', 'skipped', 'reason', 'operator_not_active');
  end if;
  if exists (select 1 from public.settlements where operator_id = p_operator_id and status = 'failed') then
    return jsonb_build_object('operator_id', p_operator_id, 'result', 'skipped', 'reason', 'prior_failed_batch_unresolved');
  end if;

  -- lock what we are about to commit; rows another worker holds are skipped, never double-settled
  select array_agg(x.id), coalesce(sum(x.gross_cents), 0), coalesce(sum(x.commission_cents), 0), coalesce(sum(x.operator_net_cents), 0)
    into v_ids, v_gross, v_comm, v_net
    from (
      select e.id, e.gross_cents, e.commission_cents, e.operator_net_cents
        from public.operator_earnings e
       where e.operator_id = p_operator_id and e.status = 'eligible' and e.eligible_at < v_cutoff
         and e.commission_bps is not null
         and exists (select 1 from public.orders o join public.payments p on p.order_id = o.id
                      where o.orderable_type = 'booking' and o.orderable_id = e.booking_id and p.status = 'captured')
       order by e.id for update of e skip locked) x;

  select array_agg(x.id), coalesce(sum(x.amount_cents), 0)
    into v_adj, v_credits
    from (select a.id, a.amount_cents from public.operator_adjustments a
           where a.operator_id = p_operator_id and a.status = 'open' and a.created_at < v_cutoff
           order by a.id for update of a skip locked) x;

  if v_ids is null and v_adj is null then
    return jsonb_build_object('operator_id', p_operator_id, 'result', 'skipped', 'reason', 'nothing_to_settle');
  end if;

  v_pre := v_net + v_credits;
  v_room := floor(v_pre::numeric * v_cap / 10000)::bigint;

  v_ref := 'ST-' || upper(substr(replace(v_id::text, '-', ''), 1, 8));
  insert into public.settlements (id, reference, operator_id, period_start, period_end, status, created_by, generated_at)
  values (v_id, v_ref, p_operator_id, p_start, p_end, 'draft', p_by, now());

  if v_ids is not null then
    insert into public.settlement_items (settlement_id, booking_item_id, earning_id, kind, fare_cents, commission_cents, net_cents)
    select v_id, e.booking_item_id, e.id, 'sale', e.gross_cents, e.commission_cents, e.operator_net_cents
      from public.operator_earnings e where e.id = any (v_ids);
    update public.operator_earnings set status = 'in_batch', settlement_id = v_id, hold_reason = null where id = any (v_ids);
  end if;
  if v_adj is not null then
    insert into public.settlement_items (settlement_id, adjustment_id, kind, fare_cents, commission_cents, net_cents)
    select v_id, a.id, 'operator_adjustment', 0, 0, a.amount_cents from public.operator_adjustments a where a.id = any (v_adj);
    update public.operator_adjustments set status = 'in_batch', settlement_id = v_id where id = any (v_adj);
  end if;

  -- net open recoveries (oldest first) within the cap; never below zero, the rest carries forward
  for r in
    select rc.id, rc.amount_cents, rc.recovered_cents from public.operator_recovery rc
     where rc.operator_id = p_operator_id and rc.status in ('open', 'partially_recovered')
     order by rc.created_at, rc.id for update of rc
  loop
    exit when v_room <= 0;
    v_avail := r.amount_cents - r.recovered_cents - private.recovery_reserved(r.id);
    continue when v_avail <= 0;
    v_take := least(v_avail, v_room);
    insert into public.settlement_items (settlement_id, recovery_id, kind, fare_cents, commission_cents, net_cents)
    values (v_id, r.id, 'recovery_netting', 0, 0, -v_take);
    v_netting := v_netting + v_take;
    v_room := v_room - v_take;
  end loop;

  update public.settlements
     set gross_cents = v_gross, commission_cents = v_comm, refunds_cents = 0,
         adjustment_credits_cents = v_credits, recovery_netted_cents = v_netting,
         other_deductions_cents = v_netting - v_credits,
         net_payable_cents = v_pre - v_netting
   where id = v_id;
  perform private.write_audit('settlement.build', 'settlement', v_id, null,
    jsonb_build_object('reference', v_ref, 'operator_id', p_operator_id, 'period_start', p_start, 'period_end', p_end,
      'earnings', coalesce(array_length(v_ids, 1), 0), 'adjustments', coalesce(array_length(v_adj, 1), 0),
      'gross_cents', v_gross, 'commission_cents', v_comm, 'credits_cents', v_credits, 'recovery_netted_cents', v_netting,
      'net_payable_cents', v_pre - v_netting));
  return jsonb_build_object('operator_id', p_operator_id, 'result', 'built', 'settlement_id', v_id, 'reference', v_ref,
                            'net_payable_cents', v_pre - v_netting);
end;
$$;
revoke execute on function private.build_operator_settlement(uuid, date, date, uuid) from public, anon, authenticated;

create or replace function private.build_settlements(p_start date, p_end date, p_operator_id uuid, p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare r record; v_res jsonb; v_built int := 0; v_list jsonb := '[]'::jsonb;
begin
  for r in
    select operator_id from (
      select e.operator_id from public.operator_earnings e where e.status = 'eligible'
      union select a.operator_id from public.operator_adjustments a where a.status = 'open') ops
    where p_operator_id is null or operator_id = p_operator_id
    order by operator_id
  loop
    v_res := private.build_operator_settlement(r.operator_id, p_start, p_end, p_by);
    if v_res ->> 'result' = 'built' then v_built := v_built + 1; end if;
    v_list := v_list || jsonb_build_array(v_res);
  end loop;
  return jsonb_build_object('period_start', p_start, 'period_end', p_end, 'built', v_built, 'operators', v_list);
end;
$$;
revoke execute on function private.build_settlements(date, date, uuid, uuid) from public, anon, authenticated;

create or replace function public.admin_build_weekly_settlement(p_period_end date default null, p_operator_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_start date; v_end date;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if p_period_end is null then
    select period_start, period_end into v_start, v_end from private.settlement_period();
  else
    v_end := p_period_end; v_start := p_period_end - 6;
  end if;
  return private.build_settlements(v_start, v_end, p_operator_id, (select auth.uid()));
end;
$$;

-- the scheduler: builds DRAFTS once per closed period, at the configured weekday/hour (idempotent, catches up)
create or replace function private.cron_build_weekly_settlement()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text := private.cfg_text('settlement_timezone', 'Asia/Kolkata');
  v_wdow integer := private.cfg_int('settlement_week_start_dow', 1);
  v_rdow integer := private.cfg_int('settlement_run_dow', 1);
  v_rhour integer := private.cfg_int('settlement_run_hour', 12);
  v_today date := (now() at time zone v_tz)::date;
  v_wk date;
  v_run_date date;
  v_due timestamptz;
  v_start date; v_end date;
  v_run uuid;
  v_sum jsonb;
begin
  v_wk := v_today - ((extract(isodow from v_today)::int - v_wdow + 7) % 7);
  v_run_date := v_wk + ((v_rdow - v_wdow + 7) % 7);
  v_due := (v_run_date + make_interval(hours => v_rhour)) at time zone v_tz;
  if now() < v_due then return; end if;
  v_end := v_wk - 1; v_start := v_end - 6;

  insert into public.settlement_runs (period_start, period_end) values (v_start, v_end)
  on conflict (period_end) do nothing returning id into v_run;
  if v_run is null then return; end if;
  begin
    v_sum := private.build_settlements(v_start, v_end, null, null);
    update public.settlement_runs set status = 'completed', finished_at = now(), built_count = (v_sum ->> 'built')::int, summary = v_sum where id = v_run;
  exception when others then
    update public.settlement_runs set status = 'failed', finished_at = now(), error = left(sqlerrm, 500) where id = v_run;
  end;
end;
$$;
revoke execute on function private.cron_build_weekly_settlement() from public, anon, authenticated;
select cron.schedule('build-weekly-settlements', '10 * * * *', $$select private.cron_build_weekly_settlement();$$);

-- ---------------------------------------------------------------------
-- 5. approve / hold / cancel
-- ---------------------------------------------------------------------
create or replace function public.admin_approve_settlement(p_settlement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.settlements;
  b public.operator_bank_details;
  v_block text;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required to approve settlements' using errcode = '42501'; end if;
  select * into s from public.settlements where id = p_settlement_id for update;
  if s.id is null then raise exception 'Settlement not found'; end if;
  if s.status <> 'draft' then raise exception 'settlement_not_draft: status is %', s.status; end if;

  v_block := private.payout_block_reason(s.operator_id);
  if v_block is not null then raise exception '%: this operator cannot be paid yet', v_block; end if;

  if exists (
    select 1 from public.operator_earnings e
    join public.orders o on o.orderable_type = 'booking' and o.orderable_id = e.booking_id
    join public.payments p on p.order_id = o.id
    join public.refunds r on r.payment_id = p.id and r.status in ('requested', 'approved', 'submitted_to_provider')
   where e.settlement_id = s.id) then
    raise exception 'refund_pending_in_batch: a ticket in this batch has an unresolved refund; resolve it or cancel the batch';
  end if;
  if s.net_payable_cents < 0 then raise exception 'negative_settlement'; end if;

  select * into b from public.operator_bank_details where operator_id = s.operator_id;
  insert into public.settlement_beneficiaries (settlement_id, account_holder_name, bank_name, branch_name, account_number, ifsc, account_type, snapshot_hash, frozen_by)
  values (s.id, b.account_holder_name, b.bank_name, b.branch_name, b.account_number, b.ifsc, b.account_type,
          private.bank_details_hash(s.operator_id), (select auth.uid()));

  update public.settlements set status = 'approved', approved_by = (select auth.uid()), approved_at = now() where id = s.id;
  perform private.write_audit('settlement.approve', 'settlement', s.id, jsonb_build_object('status', 'draft'),
    jsonb_build_object('status', 'approved', 'net_payable_cents', s.net_payable_cents, 'operator_id', s.operator_id));
  return jsonb_build_object('id', s.id, 'status', 'approved', 'net_payable_cents', s.net_payable_cents);
end;
$$;

create or replace function public.admin_hold_settlement(p_settlement_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare s public.settlements;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required to hold a settlement'; end if;
  select * into s from public.settlements where id = p_settlement_id for update;
  if s.id is null then raise exception 'Settlement not found'; end if;
  if s.status not in ('draft', 'approved') then raise exception 'settlement_not_holdable: status is % (an exported file cannot be recalled here)', s.status; end if;
  update public.settlements
     set status = 'on_hold', status_before_hold = s.status, hold_reason = btrim(p_reason), held_by = (select auth.uid()), held_at = now()
   where id = s.id;
  perform private.write_audit('settlement.hold', 'settlement', s.id, jsonb_build_object('status', s.status), jsonb_build_object('reason', btrim(p_reason)));
end;
$$;

create or replace function public.admin_release_settlement_hold(p_settlement_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare s public.settlements;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into s from public.settlements where id = p_settlement_id for update;
  if s.id is null then raise exception 'Settlement not found'; end if;
  if s.status <> 'on_hold' then raise exception 'settlement_not_on_hold'; end if;
  -- an approved batch released from hold goes back to draft: approval is re-checked (profile, refunds, bank details)
  update public.settlements
     set status = 'draft', status_before_hold = null, hold_reason = null, approved_by = null, approved_at = null
   where id = s.id;
  delete from public.settlement_beneficiaries where settlement_id = s.id;
  perform private.write_audit('settlement.release_hold', 'settlement', s.id, jsonb_build_object('status', 'on_hold'), jsonb_build_object('status', 'draft'));
end;
$$;

-- cancel a batch that has not been exported (or release a failed one): its earnings, adjustments and
-- recovery reservations return to the pool; the batch rows are removed (the audit log keeps the contents)
create or replace function public.admin_cancel_settlement(p_settlement_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.settlement_beneficiaries;
  b public.settlements;
  v_items jsonb;
  r record;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required'; end if;
  select * into b from public.settlements where id = p_settlement_id for update;
  if b.id is null then raise exception 'Settlement not found'; end if;
  if b.status not in ('draft', 'approved', 'on_hold', 'failed') then
    raise exception 'settlement_not_cancellable: status is % (exported or paid batches cannot be cancelled here)', b.status;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'booking_item_id', booking_item_id, 'adjustment_id', adjustment_id,
                                                'recovery_id', recovery_id, 'net_cents', net_cents)), '[]'::jsonb)
    into v_items from public.settlement_items where settlement_id = b.id;

  update public.operator_earnings set status = 'eligible', settlement_id = null where settlement_id = b.id and status = 'in_batch';
  update public.operator_adjustments set status = 'open', settlement_id = null where settlement_id = b.id and status = 'in_batch';
  delete from public.settlement_items where settlement_id = b.id;
  delete from public.settlement_beneficiaries where settlement_id = b.id;
  update public.settlements
     set status = 'cancelled', cancelled_by = (select auth.uid()), cancelled_at = now(), cancel_reason = btrim(p_reason)
   where id = b.id;
  -- earnings are eligible again: re-apply any hold that appeared while they were in the batch (e.g. a refund)
  for r in select booking_item_id from public.operator_earnings where operator_id = b.operator_id and status = 'eligible' loop
    perform private.earning_reevaluate(r.booking_item_id);
  end loop;
  perform private.write_audit('settlement.cancel', 'settlement', b.id, jsonb_build_object('status', b.status),
    jsonb_build_object('reason', btrim(p_reason), 'items', v_items, 'net_payable_cents', b.net_payable_cents));
  return jsonb_build_object('id', b.id, 'status', 'cancelled');
end;
$$;

-- administrator hold on a single earning (lifted only by an administrator)
create or replace function public.admin_hold_earning(p_earning_id uuid, p_hold boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare e public.operator_earnings;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into e from public.operator_earnings where id = p_earning_id for update;
  if e.id is null then raise exception 'Earning not found'; end if;
  if p_hold then
    if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required to hold an earning'; end if;
    if e.status not in ('pending_boarding', 'eligible', 'on_hold') then raise exception 'earning_not_holdable: status is %', e.status; end if;
    update public.operator_earnings set status = 'on_hold', hold_reason = 'admin_hold' where id = e.id;
  else
    if e.status <> 'on_hold' or e.hold_reason is distinct from 'admin_hold' then raise exception 'earning_not_admin_held'; end if;
    update public.operator_earnings set status = 'pending_boarding', hold_reason = null where id = e.id;
    perform private.earning_reevaluate(e.booking_item_id);
  end if;
  perform private.write_audit('earning.' || case when p_hold then 'hold' else 'release' end, 'operator_earning', e.id, null,
    jsonb_build_object('reason', p_reason));
end;
$$;

create or replace function public.admin_get_settlement_beneficiary(p_settlement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v public.settlement_beneficiaries;
begin
  if not private.is_platform_admin() then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into v from public.settlement_beneficiaries where settlement_id = p_settlement_id;
  if v.settlement_id is null then return null; end if;
  return jsonb_build_object('account_holder_name', v.account_holder_name, 'bank_name', v.bank_name, 'branch_name', v.branch_name,
    'account_masked', repeat('X', greatest(length(v.account_number) - 4, 0)) || right(v.account_number, 4),
    'ifsc', v.ifsc, 'frozen_at', v.frozen_at);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. legacy RPCs: the old manual flow could double-settle; route it through the engine
-- ---------------------------------------------------------------------
create or replace function public.admin_create_settlement(p_operator_id uuid, p_period_start date, p_period_end date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if p_period_end < p_period_start then raise exception 'Invalid period'; end if;
  v := private.build_operator_settlement(p_operator_id, p_period_start, p_period_end, (select auth.uid()));
  if v ->> 'result' <> 'built' then raise exception 'nothing_built: % %', v ->> 'result', coalesce(v ->> 'reason', ''); end if;
  return public.get_settlement_detail((v ->> 'settlement_id')::uuid);
end;
$$;

create or replace function public.admin_update_settlement(
  p_settlement_id uuid, p_status text, p_paid_cents bigint default null,
  p_method text default null, p_txn_reference text default null, p_failure_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can record settlement payments'; end if;
  raise exception 'manual_status_updates_disabled: a settlement is approved, exported to the bank file and marked paid only from the imported bank result (UTR)';
end;
$$;

-- ---------------------------------------------------------------------
-- 7. operators never see drafts
-- ---------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_a constant text := $q$where operator_id = p_operator_id and (p_status is null or status = p_status)$q$;
  v_b constant text := $q$perform private.finance_access(s.operator_id);$q$;
begin
  v_def := pg_get_functiondef('public.list_operator_settlements(uuid, text, integer, integer)'::regprocedure);
  if position(v_a in v_def) = 0 then raise exception 'Gate D: list_operator_settlements text drifted'; end if;
  execute replace(v_def, v_a, v_a || $q$ and (status <> 'draft' or private.is_platform_admin())$q$);
  v_def := pg_get_functiondef('public.get_settlement_detail(uuid)'::regprocedure);
  if position(v_b in v_def) = 0 then raise exception 'Gate D: get_settlement_detail text drifted'; end if;
  execute replace(v_def, v_b, v_b || $q$
  if s.status = 'draft' and not private.is_platform_admin() then raise exception 'Settlement not found'; end if;$q$);
end
$patch$;

revoke execute on function
  public.admin_set_payment_profile_status(uuid, text, text), public.admin_set_payout_hold(uuid, boolean, text),
  public.get_my_payment_profile(uuid), public.admin_build_weekly_settlement(date, uuid),
  public.admin_approve_settlement(uuid), public.admin_hold_settlement(uuid, text), public.admin_release_settlement_hold(uuid),
  public.admin_cancel_settlement(uuid, text), public.admin_hold_earning(uuid, boolean, text),
  public.admin_get_settlement_beneficiary(uuid), public.admin_create_settlement(uuid, date, date),
  public.admin_update_settlement(uuid, text, bigint, text, text, text), public.admin_set_platform_setting(text, jsonb)
  from public, anon;
grant execute on function
  public.admin_set_payment_profile_status(uuid, text, text), public.admin_set_payout_hold(uuid, boolean, text),
  public.get_my_payment_profile(uuid), public.admin_build_weekly_settlement(date, uuid),
  public.admin_approve_settlement(uuid), public.admin_hold_settlement(uuid, text), public.admin_release_settlement_hold(uuid),
  public.admin_cancel_settlement(uuid, text), public.admin_hold_earning(uuid, boolean, text),
  public.admin_get_settlement_beneficiary(uuid), public.admin_create_settlement(uuid, date, date),
  public.admin_update_settlement(uuid, text, bigint, text, text, text), public.admin_set_platform_setting(text, jsonb)
  to authenticated;
