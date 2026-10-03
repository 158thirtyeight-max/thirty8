-- =========================================================================
-- Gate C: operator earnings
--
--   One `operator_earnings` row per confirmed booking item. Boarding decides
--   ELIGIBILITY; the weekly settlement (Gate D) decides PAYOUT. Separate states.
--
--   pending_boarding -> eligible -> in_batch -> settled          (Gate D moves in_batch/settled)
--   side states: on_hold (refund pending / commission not configured / admin hold),
--                void (cancelled before settlement), clawed_back (cancelled after settlement)
--
--   Commission: integer paise, basis = item fare, commission = floor(fare * bps / 10000),
--   the operator receives the remainder. The rate is SNAPSHOTTED on the row when first
--   resolvable (at confirmation if a rate is configured, otherwise when one is set) and is
--   immutable afterwards, so later rate changes never touch historical earnings.
--
--   Ledger: eligibility posts event 2 (Dr booking_liability / Cr operator_payable + platform_commission);
--   losing eligibility or cancelling reverses it (reversal journal). Cancelling after the earning
--   was settled posts the recovery journal (Dr operator_receivable + commission / Cr booking_liability)
--   and creates an `operator_recovery` the admin nets against future payouts (Gate D).
--   Together with the Gate B refund journals these compose the matrix events 5 and 6.
--   (Refund POLICY allocation, e.g. keeping part of the commission, is Gate C2.)
--
-- Reversible: supabase/rollbacks/20261003000500_gatec_operator_earnings.down.sql
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. commission configuration: effective window + active flag + stronger authorization
-- ---------------------------------------------------------------------
alter table public.operator_commission_config
  add column if not exists effective_to date,
  add column if not exists is_active boolean not null default true,
  add column if not exists deactivated_by uuid references public.profiles (id),
  add column if not exists deactivated_at timestamptz;

alter table public.operator_commission_config
  add constraint operator_commission_window_chk check (effective_to is null or effective_to >= effective_from);

create or replace function private.commission_rate_bps(p_operator_id uuid, p_on date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select c.rate_bps
  from public.operator_commission_config c
  where (c.operator_id = p_operator_id or c.operator_id is null)
    and c.is_active
    and c.effective_from <= p_on
    and (c.effective_to is null or c.effective_to >= p_on)
  order by (c.operator_id is not null) desc, c.effective_from desc, c.created_at desc
  limit 1;
$$;
revoke execute on function private.commission_rate_bps(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. earnings + recoveries
-- ---------------------------------------------------------------------
create table public.operator_earnings (
  id uuid primary key default gen_random_uuid(),
  booking_item_id uuid not null unique references public.booking_items (id) on delete cascade,
  booking_id uuid not null references public.bookings (id) on delete cascade,
  trip_id uuid not null references public.bus_trips (id) on delete cascade,
  operator_id uuid not null references public.operators (id),
  gross_cents bigint not null check (gross_cents >= 0),
  commission_bps integer check (commission_bps between 0 and 10000),
  commission_basis text not null default 'item_fare',
  rounding_policy text not null default 'floor',
  commission_cents bigint check (commission_cents >= 0),
  operator_net_cents bigint check (operator_net_cents >= 0),
  status text not null default 'pending_boarding'
    check (status in ('pending_boarding', 'eligible', 'on_hold', 'in_batch', 'settled', 'void', 'clawed_back')),
  hold_reason text,
  eligible_at timestamptz,
  eligible_cycle integer not null default 0,
  eligible_journal_id uuid references public.ledger_journals (id),
  refund_adjustment_cents bigint not null default 0,
  settlement_id uuid references public.settlements (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_earnings_resolved_chk check (
    (commission_bps is null) = (commission_cents is null) and (commission_bps is null) = (operator_net_cents is null)),
  constraint operator_earnings_amounts_chk check (commission_cents is null or commission_cents + operator_net_cents = gross_cents)
);
create index operator_earnings_operator_status_idx on public.operator_earnings (operator_id, status);
create index operator_earnings_trip_idx on public.operator_earnings (trip_id);
create index operator_earnings_booking_idx on public.operator_earnings (booking_id);
create index operator_earnings_settlement_idx on public.operator_earnings (settlement_id) where settlement_id is not null;
create trigger set_updated_at before update on public.operator_earnings
  for each row execute function private.set_updated_at();

-- the snapshot never changes once taken
create or replace function private.earning_guard_snapshot()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.gross_cents is distinct from old.gross_cents or new.operator_id is distinct from old.operator_id
     or new.booking_item_id is distinct from old.booking_item_id or new.trip_id is distinct from old.trip_id
     or new.booking_id is distinct from old.booking_id then
    raise exception 'earning_snapshot_immutable: gross, operator and booking references cannot change';
  end if;
  if old.commission_bps is not null and (
       new.commission_bps is distinct from old.commission_bps or new.commission_cents is distinct from old.commission_cents
       or new.operator_net_cents is distinct from old.operator_net_cents
       or new.commission_basis is distinct from old.commission_basis or new.rounding_policy is distinct from old.rounding_policy) then
    raise exception 'earning_snapshot_immutable: the commission snapshot cannot change once taken';
  end if;
  return new;
end;
$$;
create trigger operator_earnings_snapshot before update on public.operator_earnings
  for each row execute function private.earning_guard_snapshot();

create table public.operator_recovery (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id),
  earning_id uuid not null unique references public.operator_earnings (id) on delete cascade,
  booking_item_id uuid not null references public.booking_items (id) on delete cascade,
  amount_cents bigint not null check (amount_cents > 0),
  recovered_cents bigint not null default 0 check (recovered_cents >= 0),
  status text not null default 'open' check (status in ('open', 'partially_recovered', 'recovered', 'written_off')),
  reason text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_recovery_recovered_chk check (recovered_cents <= amount_cents)
);
create index operator_recovery_operator_idx on public.operator_recovery (operator_id, status);
create trigger set_updated_at before update on public.operator_recovery
  for each row execute function private.set_updated_at();

alter table public.operator_earnings enable row level security;
alter table public.operator_recovery enable row level security;
revoke all on public.operator_earnings, public.operator_recovery from anon, authenticated;
grant select on public.operator_earnings, public.operator_recovery to authenticated;
create policy operator_earnings_select on public.operator_earnings
  for select to authenticated using (private.is_platform_admin() or private.is_operator_admin(operator_id));
create policy operator_recovery_select on public.operator_recovery
  for select to authenticated using (private.is_platform_admin() or private.is_operator_admin(operator_id));

-- ---------------------------------------------------------------------
-- 3. ledger helpers
-- ---------------------------------------------------------------------
-- A reversal journal for ANY journal; keyed like the admin reversal so the two can never both exist.
create or replace function private.reverse_journal_system(p_journal_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.ledger_journals;
  v_lines jsonb;
begin
  select * into v from public.ledger_journals where id = p_journal_id;
  if v.id is null then return null; end if;
  if v.reverses_journal_id is not null then return null; end if;
  if exists (select 1 from public.ledger_journals where reverses_journal_id = v.id) then return null; end if;
  select jsonb_agg(jsonb_build_object(
           'account', a.code, 'side', case e.side when 'debit' then 'credit' else 'debit' end,
           'amount_cents', e.amount_cents, 'operator_id', e.operator_id))
    into v_lines
    from public.ledger_entries e join public.ledger_accounts a on a.id = e.account_id
   where e.journal_id = v.id;
  return private.post_journal('reversal:' || v.id, 'reversal', v_lines,
           'Reversal of ' || v.source_event_key || ': ' || p_reason, v.ref_type, v.ref_id, v.id,
           jsonb_build_object('reason', p_reason, 'system', true));
end;
$$;
revoke execute on function private.reverse_journal_system(uuid, text) from public, anon, authenticated;

-- event 2: boarding made the earning eligible
create or replace function private.earning_post_eligible(p_earning public.operator_earnings, p_cycle integer)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_lines jsonb;
begin
  if p_earning.gross_cents <= 0 then return null; end if;
  v_lines := jsonb_build_array(jsonb_build_object('account', 'booking_liability', 'side', 'debit', 'amount_cents', p_earning.gross_cents));
  if p_earning.operator_net_cents > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'operator_payable', 'side', 'credit',
      'amount_cents', p_earning.operator_net_cents, 'operator_id', p_earning.operator_id));
  end if;
  if p_earning.commission_cents > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'platform_commission', 'side', 'credit',
      'amount_cents', p_earning.commission_cents));
  end if;
  return private.post_journal('earning:' || p_earning.id || ':eligible:' || p_cycle, 'earning_eligible', v_lines,
           'Earning eligible after boarding', 'operator_earning', p_earning.id);
end;
$$;
revoke execute on function private.earning_post_eligible(public.operator_earnings, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. lifecycle
-- ---------------------------------------------------------------------
-- Create the earning for a confirmed item (idempotent) and evaluate it.
create or replace function private.earning_ensure(p_item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.booking_items;
  v_op uuid;
begin
  select * into v_item from public.booking_items where id = p_item;
  if v_item.id is null or v_item.status not in ('confirmed', 'completed') then return; end if;
  select operator_id into v_op from public.bus_trips where id = v_item.trip_id;
  if v_op is null then return; end if;
  insert into public.operator_earnings (booking_item_id, booking_id, trip_id, operator_id, gross_cents)
  values (v_item.id, v_item.booking_id, v_item.trip_id, v_op, v_item.fare_cents)
  on conflict (booking_item_id) do nothing;
  perform private.earning_reevaluate(p_item);
end;
$$;

-- The single place that decides an earning's state from the facts:
-- boarded? commission resolvable? refund pending? admin hold? (never touches in_batch / settled / void / clawed_back)
create or replace function private.earning_reevaluate(p_item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.operator_earnings;
  v_boarded boolean;
  v_refund boolean;
  v_bps integer;
  v_comm bigint;
  v_should boolean;
  v_status text;
  v_reason text;
  v_cycle integer;
  v_journal uuid;
begin
  select * into e from public.operator_earnings where booking_item_id = p_item for update;
  if e.id is null then return; end if;
  if e.status in ('in_batch', 'settled', 'void', 'clawed_back') then return; end if;

  -- snapshot the commission the first time a rate is available
  if e.commission_bps is null then
    v_bps := private.commission_rate_bps(e.operator_id, current_date);
    if v_bps is not null then
      v_comm := floor(e.gross_cents::numeric * v_bps / 10000);
      update public.operator_earnings
         set commission_bps = v_bps, commission_cents = v_comm, operator_net_cents = e.gross_cents - v_comm
       where id = e.id
      returning * into e;
    end if;
  end if;

  v_boarded := exists (select 1 from public.passenger_boarding where booking_item_id = p_item and status = 'boarded');
  v_refund := exists (
    select 1 from public.refunds r
    join public.payments p on p.id = r.payment_id
    join public.orders o on o.id = p.order_id
    where o.orderable_type = 'booking' and o.orderable_id = e.booking_id
      and r.status in ('requested', 'approved', 'submitted_to_provider'));
  v_should := v_boarded and e.commission_bps is not null;

  -- ledger: event 2 follows eligibility (a new cycle every time boarding is corrected and redone)
  if v_should and e.eligible_at is null then
    v_cycle := e.eligible_cycle + 1;
    v_journal := private.earning_post_eligible(e, v_cycle);
    update public.operator_earnings
       set eligible_at = now(), eligible_cycle = v_cycle, eligible_journal_id = v_journal
     where id = e.id returning * into e;
  elsif not v_should and e.eligible_at is not null then
    if e.eligible_journal_id is not null then
      perform private.reverse_journal_system(e.eligible_journal_id, 'boarding no longer valid');
    end if;
    update public.operator_earnings set eligible_at = null, eligible_journal_id = null where id = e.id returning * into e;
  end if;

  if e.status = 'on_hold' and e.hold_reason = 'admin_hold' then
    return;   -- an administrator's hold is only lifted by an administrator
  end if;
  if v_refund then v_status := 'on_hold'; v_reason := 'refund_pending';
  elsif v_should then v_status := 'eligible'; v_reason := null;
  elsif v_boarded then v_status := 'on_hold'; v_reason := 'commission_not_configured';
  else v_status := 'pending_boarding'; v_reason := null;
  end if;
  if v_status is distinct from e.status or v_reason is distinct from e.hold_reason then
    update public.operator_earnings set status = v_status, hold_reason = v_reason where id = e.id;
  end if;
end;
$$;

-- A cancelled item: void the earning (reversing event 2) or, if it was already settled, claw it back.
create or replace function private.earning_on_cancelled(p_item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.operator_earnings;
  v_lines jsonb;
begin
  select * into e from public.operator_earnings where booking_item_id = p_item for update;
  if e.id is null or e.status in ('void', 'clawed_back') then return; end if;

  if e.status = 'in_batch' then
    raise exception 'earning_in_settlement_batch: this ticket is in a settlement batch; release the batch before cancelling it';
  end if;

  if e.status = 'settled' then
    -- the operator was already paid: they owe the net amount back; commission is reversed
    v_lines := jsonb_build_array(jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', e.gross_cents));
    if e.operator_net_cents > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'operator_receivable', 'side', 'debit',
        'amount_cents', e.operator_net_cents, 'operator_id', e.operator_id));
    end if;
    if e.commission_cents > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'platform_commission', 'side', 'debit', 'amount_cents', e.commission_cents));
    end if;
    if e.gross_cents > 0 then
      perform private.post_journal('earning:' || e.id || ':clawback', 'earning_clawback', v_lines,
        'Cancelled after settlement: recoverable from operator', 'operator_earning', e.id);
    end if;
    if e.operator_net_cents > 0 then
      insert into public.operator_recovery (operator_id, earning_id, booking_item_id, amount_cents, reason)
      values (e.operator_id, e.id, e.booking_item_id, e.operator_net_cents, 'Ticket cancelled/refunded after the earning was settled')
      on conflict (earning_id) do nothing;
    end if;
    update public.operator_earnings set status = 'clawed_back', hold_reason = null, refund_adjustment_cents = coalesce(e.operator_net_cents, e.gross_cents)
     where id = e.id;
    perform private.write_audit('earning.clawback', 'operator_earning', e.id, null,
      jsonb_build_object('recoverable_cents', e.operator_net_cents));
    return;
  end if;

  if e.eligible_journal_id is not null then
    perform private.reverse_journal_system(e.eligible_journal_id, 'ticket cancelled');
  end if;
  update public.operator_earnings
     set status = 'void', hold_reason = null, eligible_at = null, eligible_journal_id = null,
         refund_adjustment_cents = coalesce(e.operator_net_cents, e.gross_cents)
   where id = e.id;
end;
$$;

revoke execute on function private.earning_ensure(uuid), private.earning_reevaluate(uuid), private.earning_on_cancelled(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. triggers
-- ---------------------------------------------------------------------
create or replace function private.earning_item_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('confirmed', 'completed') then
    perform private.earning_ensure(new.id);
  elsif new.status = 'cancelled' and tg_op = 'UPDATE' then
    if old.status is distinct from new.status then
      perform private.earning_on_cancelled(new.id);
    end if;
  end if;
  return null;
end;
$$;
create trigger booking_items_earning after insert or update of status on public.booking_items
  for each row execute function private.earning_item_trigger();

create or replace function private.earning_boarding_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
declare e public.operator_earnings; v_was boolean; v_is boolean;
begin
  v_was := false;
  if tg_op = 'UPDATE' then v_was := old.status = 'boarded'; end if;
  v_is := new.status = 'boarded';
  if v_was = v_is then return null; end if;

  if v_was and not v_is then
    select * into e from public.operator_earnings where booking_item_id = new.booking_item_id;
    if e.id is not null and e.status in ('in_batch', 'settled', 'clawed_back') then
      raise exception 'earning_already_batched: this boarding is part of a settlement; ask a platform admin to handle the correction';
    end if;
  end if;
  perform private.earning_ensure(new.booking_item_id);
  perform private.earning_reevaluate(new.booking_item_id);
  return null;
end;
$$;
create trigger passenger_boarding_earning after insert or update of status on public.passenger_boarding
  for each row execute function private.earning_boarding_trigger();

-- a live refund request holds the earning; rejecting / failing it releases the hold
create or replace function private.earning_refund_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if tg_op = 'UPDATE' then
    if old.status is not distinct from new.status then return null; end if;
  end if;
  for r in
    select bi.id from public.payments p
    join public.orders o on o.id = p.order_id and o.orderable_type = 'booking'
    join public.booking_items bi on bi.booking_id = o.orderable_id
    where p.id = new.payment_id
  loop
    perform private.earning_reevaluate(r.id);
  end loop;
  return null;
end;
$$;
create trigger refunds_earning after insert or update of status on public.refunds
  for each row execute function private.earning_refund_trigger();

-- ---------------------------------------------------------------------
-- 6. commission administration (full admin only, audited, no overlapping rates)
-- ---------------------------------------------------------------------
create or replace function private.earnings_resolve_unresolved(p_operator_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare r record; n integer := 0;
begin
  for r in
    select booking_item_id from public.operator_earnings
     where commission_bps is null and status in ('pending_boarding', 'on_hold', 'eligible')
       and (p_operator_id is null or operator_id = p_operator_id)
  loop
    perform private.earning_reevaluate(r.booking_item_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.earnings_resolve_unresolved(uuid) from public, anon, authenticated;

create or replace function public.admin_set_commission(p_operator_id uuid, p_rate_bps integer, p_effective_from date default current_date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_from date := coalesce(p_effective_from, current_date);
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required to change commission' using errcode = '42501'; end if;
  if p_rate_bps is null or p_rate_bps < 0 or p_rate_bps > 10000 then raise exception 'Commission must be between 0 and 10000 basis points'; end if;
  if p_operator_id is not null and not exists (select 1 from public.operators where id = p_operator_id) then
    raise exception 'Operator not found';
  end if;

  -- a rate with the same start date is replaced; an earlier open-ended rate is closed the day before
  update public.operator_commission_config
     set is_active = false, deactivated_by = (select auth.uid()), deactivated_at = now()
   where operator_id is not distinct from p_operator_id and is_active and effective_from = v_from;
  update public.operator_commission_config
     set effective_to = v_from - 1
   where operator_id is not distinct from p_operator_id and is_active and effective_to is null and effective_from < v_from;

  insert into public.operator_commission_config (operator_id, rate_bps, effective_from, created_by)
  values (p_operator_id, p_rate_bps, v_from, (select auth.uid())) returning id into v_id;
  perform private.write_audit('commission.set', 'operator', p_operator_id, null,
    jsonb_build_object('rate_bps', p_rate_bps, 'effective_from', v_from, 'config_id', v_id));
  perform private.earnings_resolve_unresolved(p_operator_id);
  return v_id;
end;
$$;

create or replace function public.admin_deactivate_commission(p_config_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v public.operator_commission_config;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required to change commission' using errcode = '42501'; end if;
  select * into v from public.operator_commission_config where id = p_config_id for update;
  if v.id is null then raise exception 'Commission setting not found'; end if;
  if not v.is_active then return; end if;
  update public.operator_commission_config
     set is_active = false, deactivated_by = (select auth.uid()), deactivated_at = now()
   where id = v.id;
  perform private.write_audit('commission.deactivate', 'operator', v.operator_id,
    jsonb_build_object('rate_bps', v.rate_bps, 'effective_from', v.effective_from), null);
end;
$$;
revoke execute on function public.admin_set_commission(uuid, integer, date), public.admin_deactivate_commission(uuid) from public, anon;
grant execute on function public.admin_set_commission(uuid, integer, date), public.admin_deactivate_commission(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. read model for the operator / admin (same figures as private.trip_financials)
-- ---------------------------------------------------------------------
create or replace function public.get_operator_earnings_breakdown(
  p_operator_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  perform private.finance_access(p_operator_id);
  select jsonb_build_object(
    'operator_id', p_operator_id,
    'gross_cents',            coalesce(sum(e.gross_cents) filter (where e.status not in ('void', 'clawed_back')), 0),
    'commission_cents',       coalesce(sum(e.commission_cents) filter (where e.status not in ('void', 'clawed_back')), 0),
    'net_cents',              coalesce(sum(e.operator_net_cents) filter (where e.status not in ('void', 'clawed_back')), 0),
    'pending_boarding_cents', coalesce(sum(coalesce(e.operator_net_cents, e.gross_cents)) filter (where e.status = 'pending_boarding'), 0),
    'eligible_cents',         coalesce(sum(e.operator_net_cents) filter (where e.status = 'eligible'), 0),
    'on_hold_cents',          coalesce(sum(coalesce(e.operator_net_cents, e.gross_cents)) filter (where e.status = 'on_hold'), 0),
    'processing_cents',       coalesce(sum(e.operator_net_cents) filter (where e.status = 'in_batch'), 0),
    'settled_cents',          coalesce(sum(e.operator_net_cents) filter (where e.status = 'settled'), 0),
    'refund_adjustment_cents', coalesce(sum(e.refund_adjustment_cents) filter (where e.status in ('void', 'clawed_back')), 0),
    'commission_unresolved_count', count(*) filter (where e.commission_bps is null and e.status not in ('void', 'clawed_back')),
    'tickets', count(*) filter (where e.status not in ('void', 'clawed_back')),
    'recovery_open_cents', coalesce((select sum(r.amount_cents - r.recovered_cents) from public.operator_recovery r
                                      where r.operator_id = p_operator_id and r.status in ('open', 'partially_recovered')), 0)
  ) into v
  from public.operator_earnings e
  join public.bus_trips t on t.id = e.trip_id
  where e.operator_id = p_operator_id
    and (p_from is null or t.travel_date >= p_from)
    and (p_to is null or t.travel_date <= p_to);
  return v;
end;
$$;
revoke execute on function public.get_operator_earnings_breakdown(uuid, date, date) from public, anon;
grant execute on function public.get_operator_earnings_breakdown(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 8. keep the shared trip calculation on the same numbers (floor + the snapshot)
-- ---------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_a constant text := $q$round(i.fare_cents * r.bps / 10000.0)$q$;
  v_b constant text := $q$sale.booking_item_id is null and r.bps is not null), 0)::bigint as comm_est$q$;
  v_c constant text := $q$left join sale on sale.booking_item_id = i.id$q$;
begin
  v_def := pg_get_functiondef('private.trip_financials(uuid[])'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_a, ''))) <> length(v_a)
     or (length(v_def) - length(replace(v_def, v_b, ''))) <> length(v_b)
     or (length(v_def) - length(replace(v_def, v_c, ''))) <> length(v_c) then
    raise exception 'Gate C: private.trip_financials text does not match the expected patch points';
  end if;
  v_def := replace(v_def, v_a, $q$coalesce(oe.commission_cents, floor(i.fare_cents * r.bps / 10000.0))$q$);
  v_def := replace(v_def, v_b, $q$sale.booking_item_id is null and (r.bps is not null or oe.commission_cents is not null)), 0)::bigint as comm_est$q$);
  v_def := replace(v_def, v_c, $q$left join sale on sale.booking_item_id = i.id
    left join public.operator_earnings oe on oe.booking_item_id = i.id$q$);
  execute v_def;
end
$patch$;

-- ---------------------------------------------------------------------
-- 9. backfill for confirmed items that predate earnings (idempotent)
-- ---------------------------------------------------------------------
create or replace function private.earnings_backfill()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare r record; n integer := 0;
begin
  for r in
    select bi.id from public.booking_items bi
    where bi.status in ('confirmed', 'completed')
      and not exists (select 1 from public.operator_earnings e where e.booking_item_id = bi.id)
  loop
    perform private.earning_ensure(r.id);
    n := n + 1;
  end loop;
  -- items already committed to an existing (manual) settlement keep that state
  update public.operator_earnings e
     set status = case when s.status = 'paid' then 'settled' else 'in_batch' end, settlement_id = s.id, hold_reason = null
    from public.settlement_items si
    join public.settlements s on s.id = si.settlement_id
   where si.booking_item_id = e.booking_item_id and si.kind = 'sale'
     and e.status in ('pending_boarding', 'eligible', 'on_hold');
  return n;
end;
$$;
revoke execute on function private.earnings_backfill() from public, anon, authenticated;

select private.earnings_backfill();
