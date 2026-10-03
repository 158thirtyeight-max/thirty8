-- =========================================================================
-- Gate C2: refund & cancellation policy management (admin-controlled)
--
--   * NO refund percentage is hardcoded anywhere. Policies are rows managed by full admins
--     (admin_save_refund_policy); there are no seeded rates.
--   * refund_policies + refund_policy_versions (every change is a new immutable version)
--   * booking_policy_snapshot: at booking creation the policy tiers in force are copied onto the
--     booking, so later policy edits never alter an existing booking
--   * refund amount = floor(eligible * refund_bps / 10000); deduction = eligible - refund (integer paise),
--     computed server-side only; an explicit admin override (reason + audit) is allowed only where the
--     applicable policy permits fixed overrides
--   * approval is the authorization step: it calculates, stores the calculation on the refund and only then
--     moves the refund to `approved` (no calculation / no applicable policy => no approval)
--   * allocation of the cancellation deduction is part of the policy: deduction_operator_share_bps goes to the
--     operator (operator_adjustments, settled in Gate D), the rest is platform cancellation income
--   * operators and customers are strictly read-only (RPCs below); every write RPC checks private.is_full_admin()
--
-- Ledger (event 3 now carries the allocation):
--   Dr booking_liability  E
--     Cr refund_payable        R   (refund to the customer)
--     Cr operator_payable      S   (operator share of the deduction)
--     Cr cancellation_income   E - R - S
--
-- Reversible: supabase/rollbacks/20261003000600_gatec2_refund_policy.down.sql
-- =========================================================================

insert into public.ledger_accounts (code, name, type, description) values
  ('cancellation_income', 'Cancellation income', 'revenue', 'Cancellation deductions retained by thirty8'),
  ('bad_debt',            'Operator recovery write-offs', 'expense', 'Operator recoveries written off by an administrator');

-- ---------------------------------------------------------------------
-- 1. policies + immutable version history
-- ---------------------------------------------------------------------
create table public.refund_policies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  category text not null check (category ~ '^[a-z][a-z0-9_]{1,40}$'),
  status text not null default 'active' check (status in ('active', 'inactive')),
  refund_bps integer not null check (refund_bps between 0 and 10000),
  deduction_bps integer generated always as (10000 - refund_bps) stored,
  deduction_operator_share_bps integer not null check (deduction_operator_share_bps between 0 and 10000),
  min_hours_before_departure numeric,
  max_hours_before_departure numeric,
  effective_from date not null default current_date,
  effective_until date,
  description text,
  allow_fixed_override boolean not null default false,
  version integer not null default 1,
  created_by uuid references public.profiles (id),
  last_modified_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint refund_policies_window_chk check (
    min_hours_before_departure is null or max_hours_before_departure is null
    or min_hours_before_departure < max_hours_before_departure),
  constraint refund_policies_dates_chk check (effective_until is null or effective_until >= effective_from)
);
create index refund_policies_category_idx on public.refund_policies (category, status);

create table public.refund_policy_versions (
  policy_id uuid not null references public.refund_policies (id) on delete cascade,
  version integer not null,
  snapshot jsonb not null,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  primary key (policy_id, version)
);

create or replace function private.refund_policy_bump()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.version := old.version + 1;
  new.updated_at := now();
  new.last_modified_by := (select auth.uid());
  return new;
end;
$$;
create trigger refund_policies_bump before update on public.refund_policies
  for each row execute function private.refund_policy_bump();

create or replace function private.refund_policy_record_version()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.refund_policy_versions (policy_id, version, snapshot, changed_by)
  values (new.id, new.version, to_jsonb(new), (select auth.uid()));
  return null;
end;
$$;
create trigger refund_policies_version after insert or update on public.refund_policies
  for each row execute function private.refund_policy_record_version();

create or replace function private.refund_versions_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'policy_version_immutable: policy history cannot be changed' using errcode = '55000';
end;
$$;
create trigger refund_policy_versions_immutable before update or delete on public.refund_policy_versions
  for each row execute function private.refund_versions_immutable();

-- ---------------------------------------------------------------------
-- 2. booking snapshot
-- ---------------------------------------------------------------------
create or replace function private.policy_tier(p public.refund_policies)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'version', p.version, 'name', p.name, 'category', p.category,
    'refund_bps', p.refund_bps, 'deduction_bps', p.deduction_bps,
    'deduction_operator_share_bps', p.deduction_operator_share_bps,
    'min_hours', p.min_hours_before_departure, 'max_hours', p.max_hours_before_departure,
    'effective_from', p.effective_from, 'effective_until', p.effective_until,
    'allow_fixed_override', p.allow_fixed_override, 'description', p.description);
$$;

create table public.booking_policy_snapshot (
  booking_id uuid primary key references public.bookings (id) on delete cascade,
  captured_at timestamptz not null default now(),
  calculation_basis text not null default 'eligible_amount',
  rounding_policy text not null default 'floor',
  tiers jsonb not null default '[]'::jsonb
);

create or replace function private.snapshot_booking_policy()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.booking_policy_snapshot (booking_id, tiers)
  select new.id, coalesce(jsonb_agg(private.policy_tier(p) order by p.category, p.created_at), '[]'::jsonb)
    from public.refund_policies p
   where p.status = 'active' and (p.effective_until is null or p.effective_until >= current_date)
  on conflict (booking_id) do nothing;
  return null;
end;
$$;
create trigger bookings_policy_snapshot after insert on public.bookings
  for each row execute function private.snapshot_booking_policy();

-- ---------------------------------------------------------------------
-- 3. refunds: reason category, requested (eligible) amount, stored calculation, overrides
-- ---------------------------------------------------------------------
alter table public.refunds
  add column if not exists reason_category text,
  add column if not exists requested_cents integer,
  add column if not exists policy_id uuid references public.refund_policies (id),
  add column if not exists policy_version integer,
  add column if not exists policy_refund_bps integer,
  add column if not exists calc_source text check (calc_source in ('booking_snapshot', 'admin_selected', 'override')),
  add column if not exists calc_eligible_cents bigint,
  add column if not exists calc_deduction_cents bigint,
  add column if not exists calc_operator_share_bps integer,
  add column if not exists calc_operator_share_cents bigint,
  add column if not exists hours_before_departure numeric,
  add column if not exists calculated_at timestamptz,
  add column if not exists calculated_by uuid references public.profiles (id);

update public.refunds set requested_cents = amount_cents where requested_cents is null;

create or replace function private.refund_fill_defaults()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_booking uuid;
begin
  new.requested_cents := coalesce(new.requested_cents, new.amount_cents);
  if new.reason_category is null then
    select o.orderable_id into v_booking
      from public.payments p join public.orders o on o.id = p.order_id and o.orderable_type = 'booking'
     where p.id = new.payment_id;
    select customer_id into v_customer from public.bookings where id = v_booking;
    if new.reason like 'Payment could not be applied%' or new.reason like 'Duplicate capture%' then
      new.reason_category := 'system_failure';
    elsif new.requested_by is not null and new.requested_by is not distinct from v_customer then
      new.reason_category := 'passenger_cancellation';
    elsif v_booking is not null and exists (
            select 1 from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
             where bi.booking_id = v_booking and t.status = 'cancelled') then
      new.reason_category := 'operator_cancelled';
    else
      new.reason_category := 'admin_discretion';
    end if;
  end if;
  return new;
end;
$$;
create trigger refunds_fill_defaults before insert on public.refunds
  for each row execute function private.refund_fill_defaults();

create table public.refund_overrides (
  id uuid primary key default gen_random_uuid(),
  refund_id uuid not null unique references public.refunds (id) on delete cascade,
  policy_id uuid references public.refund_policies (id),
  original_calculated_cents bigint not null,
  final_cents bigint not null check (final_cents > 0),
  difference_cents bigint not null,
  reason text not null check (btrim(reason) <> ''),
  admin_id uuid not null,
  created_at timestamptz not null default now()
);

create table public.operator_adjustments (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id),
  kind text not null check (kind in ('cancellation_share')),
  refund_id uuid not null unique references public.refunds (id) on delete cascade,
  amount_cents bigint not null check (amount_cents > 0),
  status text not null default 'open' check (status in ('open', 'in_batch', 'settled')),
  settlement_id uuid references public.settlements (id),
  created_at timestamptz not null default now()
);
create index operator_adjustments_operator_idx on public.operator_adjustments (operator_id, status);

alter table public.refund_policies enable row level security;
alter table public.refund_policy_versions enable row level security;
alter table public.booking_policy_snapshot enable row level security;
alter table public.refund_overrides enable row level security;
alter table public.operator_adjustments enable row level security;
revoke all on public.refund_policies, public.refund_policy_versions, public.booking_policy_snapshot,
  public.refund_overrides, public.operator_adjustments from anon, authenticated;
grant select on public.refund_policies, public.refund_policy_versions, public.booking_policy_snapshot,
  public.refund_overrides, public.operator_adjustments to authenticated;
create policy refund_policies_admin_select on public.refund_policies for select to authenticated using (private.is_platform_admin());
create policy refund_policy_versions_admin_select on public.refund_policy_versions for select to authenticated using (private.is_platform_admin());
create policy booking_policy_snapshot_admin_select on public.booking_policy_snapshot for select to authenticated using (private.is_platform_admin());
create policy refund_overrides_admin_select on public.refund_overrides for select to authenticated using (private.is_platform_admin());
create policy operator_adjustments_select on public.operator_adjustments for select to authenticated
  using (private.is_platform_admin() or private.is_operator_admin(operator_id));

create or replace function private.refund_operator(p_refund_id uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select t.operator_id
    from public.refunds r
    join public.payments p on p.id = r.payment_id
    join public.orders o on o.id = p.order_id and o.orderable_type = 'booking'
    join public.booking_items bi on bi.booking_id = o.orderable_id
    join public.bus_trips t on t.id = bi.trip_id
   where r.id = p_refund_id order by t.departure_at limit 1;
$$;
revoke execute on function private.refund_operator(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. calculation (server-side only)
-- ---------------------------------------------------------------------
create or replace function private.pick_policy(p_tiers jsonb, p_category text, p_hours numeric, p_on date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select t
  from (
    select t,
           case when t ->> 'category' = p_category then 0 else 1 end as cat_rank,
           coalesce((t ->> 'max_hours')::numeric, 1e9) - coalesce((t ->> 'min_hours')::numeric, -1e9) as span
    from jsonb_array_elements(coalesce(p_tiers, '[]'::jsonb)) t
    where (t ->> 'category' = p_category or t ->> 'category' = 'default')
      and (t ->> 'effective_from')::date <= p_on
      and (t ->> 'effective_until' is null or (t ->> 'effective_until')::date >= p_on)
      and (t ->> 'min_hours' is null or (p_hours is not null and p_hours >= (t ->> 'min_hours')::numeric))
      and (t ->> 'max_hours' is null or (p_hours is not null and p_hours < (t ->> 'max_hours')::numeric))
  ) x
  order by cat_rank, span, t ->> 'id'
  limit 1;
$$;

create or replace function private.compute_refund(p_refund_id uuid, p_policy_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v public.refunds;
  v_pay public.payments;
  v_order public.orders;
  v_dep timestamptz;
  v_hours numeric;
  v_tiers jsonb;
  v_pol jsonb;
  v_src text;
  v_op uuid;
  v_e bigint;
  v_r bigint;
  v_d bigint;
  v_s bigint;
  v_live public.refund_policies;
begin
  select * into v from public.refunds where id = p_refund_id;
  if v.id is null then raise exception 'Refund not found'; end if;
  select * into v_pay from public.payments where id = v.payment_id;
  select * into v_order from public.orders where id = v_pay.order_id;
  v_e := coalesce(v.requested_cents, v.amount_cents);

  if v_order.orderable_type = 'booking' then
    select min(t.departure_at), (array_agg(t.operator_id order by t.departure_at))[1] into v_dep, v_op
      from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
     where bi.booking_id = v_order.orderable_id;
    if v_dep is not null then v_hours := extract(epoch from (v_dep - v.created_at)) / 3600.0; end if;
    select tiers into v_tiers from public.booking_policy_snapshot where booking_id = v_order.orderable_id;
  end if;

  if p_policy_id is not null then
    select * into v_live from public.refund_policies where id = p_policy_id;
    if v_live.id is null or v_live.status <> 'active'
       or v_live.effective_from > v.created_at::date
       or (v_live.effective_until is not null and v_live.effective_until < v.created_at::date) then
      raise exception 'policy_not_available: the chosen policy is inactive or not in effect';
    end if;
    v_pol := private.policy_tier(v_live);
    v_src := 'admin_selected';
  elsif v_tiers is not null then
    v_pol := private.pick_policy(v_tiers, v.reason_category, v_hours, v.created_at::date);
    v_src := 'booking_snapshot';
  end if;

  if v_pol is null then
    return jsonb_build_object('error', 'no_applicable_policy', 'eligible_cents', v_e,
      'reason_category', v.reason_category, 'hours_before_departure', v_hours, 'operator_id', v_op);
  end if;

  v_r := floor(v_e::numeric * (v_pol ->> 'refund_bps')::int / 10000)::bigint;
  v_d := v_e - v_r;
  v_s := floor(v_d::numeric * (v_pol ->> 'deduction_operator_share_bps')::int / 10000)::bigint;
  return jsonb_build_object(
    'policy_id', v_pol ->> 'id', 'policy_version', (v_pol ->> 'version')::int, 'policy_name', v_pol ->> 'name',
    'refund_bps', (v_pol ->> 'refund_bps')::int, 'source', v_src,
    'allow_fixed_override', (v_pol ->> 'allow_fixed_override')::boolean,
    'eligible_cents', v_e, 'refund_cents', v_r, 'deduction_cents', v_d,
    'operator_share_bps', (v_pol ->> 'deduction_operator_share_bps')::int, 'operator_share_cents', v_s,
    'platform_retained_cents', v_d - v_s,
    'reason_category', v.reason_category, 'hours_before_departure', v_hours, 'operator_id', v_op);
end;
$$;
revoke execute on function private.compute_refund(uuid, uuid), private.pick_policy(jsonb, text, numeric, date) from public, anon, authenticated;

-- preview for any platform admin (support can review; only a full admin can act)
create or replace function public.admin_preview_refund(p_refund_id uuid, p_policy_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'not_authorized' using errcode = '42501'; end if;
  return private.compute_refund(p_refund_id, p_policy_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. policy administration (full admin, audited, no overlapping active tiers)
-- ---------------------------------------------------------------------
create or replace function private.assert_no_policy_overlap(p public.refund_policies)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p.status <> 'active' then return; end if;
  if exists (
    select 1 from public.refund_policies o
    where o.id <> p.id and o.status = 'active' and o.category = p.category
      and coalesce(o.min_hours_before_departure, -1e9) < coalesce(p.max_hours_before_departure, 1e9)
      and coalesce(p.min_hours_before_departure, -1e9) < coalesce(o.max_hours_before_departure, 1e9)
      and o.effective_from <= coalesce(p.effective_until, 'infinity'::date)
      and p.effective_from <= coalesce(o.effective_until, 'infinity'::date)) then
    raise exception 'policy_overlap: another active % policy already covers this window and date range', p.category;
  end if;
end;
$$;
revoke execute on function private.assert_no_policy_overlap(public.refund_policies) from public, anon, authenticated;

create or replace function public.admin_save_refund_policy(
  p_name text,
  p_category text,
  p_refund_bps integer,
  p_deduction_operator_share_bps integer,
  p_min_hours numeric,
  p_max_hours numeric,
  p_effective_from date,
  p_effective_until date,
  p_description text,
  p_allow_fixed_override boolean,
  p_status text,
  p_policy_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.refund_policies;
  v_before jsonb;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required to change refund policies' using errcode = '42501'; end if;
  if p_refund_bps is null or p_refund_bps < 0 or p_refund_bps > 10000 then raise exception 'Refund percentage must be between 0 and 10000 basis points'; end if;

  if p_policy_id is null then
    insert into public.refund_policies (name, category, status, refund_bps, deduction_operator_share_bps,
        min_hours_before_departure, max_hours_before_departure, effective_from, effective_until, description,
        allow_fixed_override, created_by, last_modified_by)
    values (btrim(p_name), p_category, p_status, p_refund_bps, p_deduction_operator_share_bps, p_min_hours, p_max_hours,
        coalesce(p_effective_from, current_date), p_effective_until, p_description,
        coalesce(p_allow_fixed_override, false), (select auth.uid()), (select auth.uid()))
    returning * into v;
    perform private.assert_no_policy_overlap(v);
    perform private.write_audit('refund_policy.create', 'refund_policy', v.id, null, to_jsonb(v));
  else
    select * into v from public.refund_policies where id = p_policy_id for update;
    if v.id is null then raise exception 'Policy not found'; end if;
    v_before := to_jsonb(v);
    update public.refund_policies
       set name = btrim(p_name), category = p_category, status = p_status, refund_bps = p_refund_bps,
           deduction_operator_share_bps = p_deduction_operator_share_bps,
           min_hours_before_departure = p_min_hours, max_hours_before_departure = p_max_hours,
           effective_from = coalesce(p_effective_from, current_date), effective_until = p_effective_until,
           description = p_description, allow_fixed_override = coalesce(p_allow_fixed_override, false)
     where id = p_policy_id returning * into v;
    perform private.assert_no_policy_overlap(v);
    perform private.write_audit('refund_policy.update', 'refund_policy', v.id, v_before, to_jsonb(v));
  end if;
  return v.id;
end;
$$;

create or replace function public.admin_set_refund_policy_status(p_policy_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v public.refund_policies; v_before jsonb;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required to change refund policies' using errcode = '42501'; end if;
  if p_status not in ('active', 'inactive') then raise exception 'Invalid status'; end if;
  select * into v from public.refund_policies where id = p_policy_id for update;
  if v.id is null then raise exception 'Policy not found'; end if;
  if v.status = p_status then return; end if;
  v_before := to_jsonb(v);
  update public.refund_policies set status = p_status where id = v.id returning * into v;
  perform private.assert_no_policy_overlap(v);
  perform private.write_audit('refund_policy.status', 'refund_policy', v.id, v_before, to_jsonb(v));
end;
$$;

-- ---------------------------------------------------------------------
-- 6. refund authorization: calculate -> approve (with optional override)
-- ---------------------------------------------------------------------
drop function if exists public.admin_approve_refund(uuid);

create or replace function public.admin_approve_refund(p_refund_id uuid, p_policy_id uuid default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.refunds;
  c jsonb;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;
  if v.status <> 'requested' then raise exception 'refund_not_requested: status is %', v.status; end if;

  if v.calc_source = 'override' then
    -- an authorized exception was already recorded (admin_override_refund): keep that amount
    update public.refunds set status = 'approved', approved_by = (select auth.uid()), approved_at = now() where id = v.id;
  else
    c := private.compute_refund(v.id, p_policy_id);
    if c ->> 'error' is not null then
      raise exception 'no_applicable_policy: no active policy covers this refund (category %, % hours before departure). Choose a policy or authorize an override.',
        c ->> 'reason_category', coalesce(c ->> 'hours_before_departure', 'n/a');
    end if;
    if (c ->> 'refund_cents')::bigint <= 0 then
      raise exception 'zero_refund: the applicable policy refunds 0 percent; reject this request instead';
    end if;
    update public.refunds
       set amount_cents = (c ->> 'refund_cents')::int, status = 'approved', approved_by = (select auth.uid()), approved_at = now(),
           policy_id = (c ->> 'policy_id')::uuid, policy_version = (c ->> 'policy_version')::int,
           policy_refund_bps = (c ->> 'refund_bps')::int, calc_source = c ->> 'source',
           calc_eligible_cents = (c ->> 'eligible_cents')::bigint, calc_deduction_cents = (c ->> 'deduction_cents')::bigint,
           calc_operator_share_bps = (c ->> 'operator_share_bps')::int, calc_operator_share_cents = (c ->> 'operator_share_cents')::bigint,
           hours_before_departure = (c ->> 'hours_before_departure')::numeric,
           calculated_at = now(), calculated_by = (select auth.uid())
     where id = v.id;
  end if;

  select * into v from public.refunds where id = p_refund_id;
  -- the operator's share of the cancellation deduction is owed to them (settled in Gate D)
  if v.calc_operator_share_cents > 0 then
    insert into public.operator_adjustments (operator_id, kind, refund_id, amount_cents)
    values (private.refund_operator(v.id), 'cancellation_share', v.id, v.calc_operator_share_cents)
    on conflict (refund_id) do nothing;
  end if;
  perform private.write_audit('refund.approve', 'refund', v.id,
    jsonb_build_object('status', 'requested'),
    jsonb_build_object('status', 'approved', 'amount_cents', v.amount_cents, 'policy_id', v.policy_id,
      'policy_version', v.policy_version, 'refund_bps', v.policy_refund_bps, 'source', v.calc_source,
      'eligible_cents', v.calc_eligible_cents, 'deduction_cents', v.calc_deduction_cents));
end;
$$;

create or replace function public.admin_override_refund(
  p_refund_id uuid, p_final_cents integer, p_reason text, p_policy_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.refunds;
  c jsonb;
  v_d bigint;
  v_s bigint;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required for a refund override'; end if;
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;
  if v.status <> 'requested' then raise exception 'refund_not_requested: status is %', v.status; end if;
  if exists (select 1 from public.refund_overrides where refund_id = v.id) then raise exception 'This refund already has an override'; end if;

  c := private.compute_refund(v.id, p_policy_id);
  if c ->> 'error' is not null then
    raise exception 'no_applicable_policy: choose the policy this exception is made under';
  end if;
  if not (c ->> 'allow_fixed_override')::boolean then
    raise exception 'override_not_permitted: the applicable policy "%" does not allow fixed-amount overrides', c ->> 'policy_name';
  end if;
  if p_final_cents is null or p_final_cents <= 0 or p_final_cents > (c ->> 'eligible_cents')::bigint then
    raise exception 'The override must be positive and not exceed the eligible amount (% paise)', c ->> 'eligible_cents';
  end if;

  v_d := (c ->> 'eligible_cents')::bigint - p_final_cents;
  v_s := floor(v_d::numeric * (c ->> 'operator_share_bps')::int / 10000)::bigint;
  insert into public.refund_overrides (refund_id, policy_id, original_calculated_cents, final_cents, difference_cents, reason, admin_id)
  values (v.id, (c ->> 'policy_id')::uuid, (c ->> 'refund_cents')::bigint, p_final_cents,
          p_final_cents - (c ->> 'refund_cents')::bigint, btrim(p_reason), (select auth.uid()));
  update public.refunds
     set amount_cents = p_final_cents, policy_id = (c ->> 'policy_id')::uuid, policy_version = (c ->> 'policy_version')::int,
         policy_refund_bps = (c ->> 'refund_bps')::int, calc_source = 'override',
         calc_eligible_cents = (c ->> 'eligible_cents')::bigint, calc_deduction_cents = v_d,
         calc_operator_share_bps = (c ->> 'operator_share_bps')::int, calc_operator_share_cents = v_s,
         hours_before_departure = (c ->> 'hours_before_departure')::numeric,
         calculated_at = now(), calculated_by = (select auth.uid())
   where id = v.id;
  perform private.write_audit('refund.override', 'refund', v.id, jsonb_build_object('calculated_cents', (c ->> 'refund_cents')::bigint),
    jsonb_build_object('final_cents', p_final_cents, 'difference_cents', p_final_cents - (c ->> 'refund_cents')::bigint,
                       'reason', btrim(p_reason), 'policy_id', c ->> 'policy_id'));
  return jsonb_build_object('calculated_cents', (c ->> 'refund_cents')::bigint, 'final_cents', p_final_cents,
                            'difference_cents', p_final_cents - (c ->> 'refund_cents')::bigint);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. ledger: approval carries the allocation (event 3)
-- ---------------------------------------------------------------------
create or replace function private.ledger_post_refund_approved(p_refund_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v public.refunds;
  v_e bigint; v_s bigint; v_i bigint;
  v_op uuid;
  v_lines jsonb;
begin
  select * into v from public.refunds where id = p_refund_id;
  if v.id is null or v.amount_cents <= 0 then return null; end if;

  if v.calc_eligible_cents is null then
    -- legacy / uncalculated refund: the refund amount is the whole liability release
    return private.post_journal(
      'refund:' || v.id || ':approved', 'refund_approved',
      jsonb_build_array(
        jsonb_build_object('account', 'booking_liability', 'side', 'debit', 'amount_cents', v.amount_cents),
        jsonb_build_object('account', 'refund_payable', 'side', 'credit', 'amount_cents', v.amount_cents)),
      'Refund approved', 'refund', v.id);
  end if;

  v_e := v.calc_eligible_cents;
  v_s := coalesce(v.calc_operator_share_cents, 0);
  v_i := v_e - v.amount_cents - v_s;
  v_op := private.refund_operator(v.id);

  v_lines := jsonb_build_array(
    jsonb_build_object('account', 'booking_liability', 'side', 'debit', 'amount_cents', v_e),
    jsonb_build_object('account', 'refund_payable', 'side', 'credit', 'amount_cents', v.amount_cents));
  if v_s > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'operator_payable', 'side', 'credit', 'amount_cents', v_s, 'operator_id', v_op));
  end if;
  if v_i > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account', 'cancellation_income', 'side', 'credit', 'amount_cents', v_i));
  end if;
  return private.post_journal('refund:' || v.id || ':approved', 'refund_approved', v_lines,
           'Refund approved (policy ' || coalesce(v.policy_id::text, 'n/a') || ')', 'refund', v.id);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. operator recoveries (admin-only changes, audited, ledger-backed)
-- ---------------------------------------------------------------------
create or replace function public.admin_update_recovery(p_recovery_id uuid, p_action text, p_amount_cents bigint default null, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.operator_recovery;
  v_remaining bigint;
  v_new bigint;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A reason is required'; end if;
  select * into v from public.operator_recovery where id = p_recovery_id for update;
  if v.id is null then raise exception 'Recovery not found'; end if;
  if v.status in ('recovered', 'written_off') then raise exception 'recovery_closed: status is %', v.status; end if;
  v_remaining := v.amount_cents - v.recovered_cents;

  if p_action = 'record_recovery' then
    if p_amount_cents is null or p_amount_cents <= 0 or p_amount_cents > v_remaining then
      raise exception 'The recovered amount must be between 1 and the outstanding % paise', v_remaining;
    end if;
    v_new := v.recovered_cents + p_amount_cents;
    perform private.post_journal('recovery:' || v.id || ':recorded:' || v_new, 'recovery_recorded',
      jsonb_build_array(
        jsonb_build_object('account', 'settlement_bank', 'side', 'debit', 'amount_cents', p_amount_cents),
        jsonb_build_object('account', 'operator_receivable', 'side', 'credit', 'amount_cents', p_amount_cents, 'operator_id', v.operator_id)),
      'Operator recovery received: ' || btrim(p_reason), 'operator_recovery', v.id);
    update public.operator_recovery
       set recovered_cents = v_new, status = case when v_new = amount_cents then 'recovered' else 'partially_recovered' end
     where id = v.id;
  elsif p_action = 'write_off' then
    perform private.post_journal('recovery:' || v.id || ':writeoff', 'recovery_writeoff',
      jsonb_build_array(
        jsonb_build_object('account', 'bad_debt', 'side', 'debit', 'amount_cents', v_remaining),
        jsonb_build_object('account', 'operator_receivable', 'side', 'credit', 'amount_cents', v_remaining, 'operator_id', v.operator_id)),
      'Operator recovery written off: ' || btrim(p_reason), 'operator_recovery', v.id);
    update public.operator_recovery set status = 'written_off' where id = v.id;
  else
    raise exception 'Unknown action % (use record_recovery or write_off)', p_action;
  end if;
  perform private.write_audit('recovery.' || p_action, 'operator_recovery', v.id,
    jsonb_build_object('recovered_cents', v.recovered_cents, 'status', v.status),
    jsonb_build_object('amount_cents', p_amount_cents, 'reason', btrim(p_reason)));
end;
$$;

-- ---------------------------------------------------------------------
-- 9. read-only views of the data for operators / customers / admin
-- ---------------------------------------------------------------------
create or replace function public.get_operator_refund_adjustments(p_operator_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  perform private.finance_access(p_operator_id);
  select coalesce(jsonb_agg(row_to_json(x) order by x.processed_at desc nulls last, x.ticket_reference), '[]'::jsonb) into v
  from (
    select b.booking_reference as ticket_reference, e.booking_item_id,
           e.gross_cents as original_amount_cents,
           case when r.id is null then null else floor(r.amount_cents::numeric * e.gross_cents / nullif(coalesce(r.calc_eligible_cents, r.requested_cents, e.gross_cents), 0))::bigint end as refund_amount_cents,
           case when r.id is null then null else e.gross_cents - floor(r.amount_cents::numeric * e.gross_cents / nullif(coalesce(r.calc_eligible_cents, r.requested_cents, e.gross_cents), 0))::bigint end as cancellation_deduction_cents,
           coalesce(e.commission_cents, 0) as commission_adjustment_cents,
           case when r.id is null then null else
             floor((e.gross_cents - floor(r.amount_cents::numeric * e.gross_cents / nullif(coalesce(r.calc_eligible_cents, r.requested_cents, e.gross_cents), 0)))::numeric
                   * coalesce(r.calc_operator_share_bps, 0) / 10000)::bigint - coalesce(e.operator_net_cents, 0) end as net_impact_cents,
           r.status as refund_status, r.processed_at, e.status as earning_status
    from public.operator_earnings e
    join public.bookings b on b.id = e.booking_id
    join public.bus_trips t on t.id = e.trip_id
    left join lateral (
      select rf.* from public.refunds rf
      join public.payments p on p.id = rf.payment_id
      join public.orders o on o.id = p.order_id and o.orderable_type = 'booking' and o.orderable_id = e.booking_id
      where rf.status <> 'rejected' order by rf.created_at desc limit 1) r on true
    where e.operator_id = p_operator_id and e.status in ('void', 'clawed_back')
      and (p_from is null or t.travel_date >= p_from) and (p_to is null or t.travel_date <= p_to)
  ) x;
  return v;
end;
$$;

create or replace function public.list_operator_recoveries(p_operator_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  perform private.finance_access(p_operator_id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'amount_cents', r.amount_cents, 'recovered_cents', r.recovered_cents,
           'outstanding_cents', r.amount_cents - r.recovered_cents, 'status', r.status, 'reason', r.reason,
           'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb) into v
  from public.operator_recovery r where r.operator_id = p_operator_id;
  return v;
end;
$$;

-- what a customer may see about their own booking's cancellation terms and refunds
create or replace function public.get_booking_cancellation_policy(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  if not exists (select 1 from public.bookings b where b.id = p_booking_id
                  and (b.customer_id = (select auth.uid()) or private.is_platform_admin())) then
    raise exception 'Booking not found';
  end if;
  select jsonb_build_object('captured_at', s.captured_at,
    'tiers', coalesce((select jsonb_agg(jsonb_build_object(
        'name', t ->> 'name', 'category', t ->> 'category', 'refund_bps', (t ->> 'refund_bps')::int,
        'min_hours', t ->> 'min_hours', 'max_hours', t ->> 'max_hours', 'description', t ->> 'description'))
      from jsonb_array_elements(s.tiers) t), '[]'::jsonb)) into v
  from public.booking_policy_snapshot s where s.booking_id = p_booking_id;
  return coalesce(v, jsonb_build_object('captured_at', null, 'tiers', '[]'::jsonb));
end;
$$;

create or replace function public.get_my_refund_status(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.bookings b where b.id = p_booking_id and b.customer_id = (select auth.uid())) then
    raise exception 'Booking not found';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'status', r.status, 'requested_cents', r.requested_cents, 'refund_cents', r.amount_cents,
             'deduction_cents', r.calc_deduction_cents, 'requested_at', r.created_at, 'processed_at', r.processed_at,
             'rejection_reason', r.rejection_reason) order by r.created_at desc)
    from public.refunds r join public.payments p on p.id = r.payment_id join public.orders o on o.id = p.order_id
    where o.orderable_type = 'booking' and o.orderable_id = p_booking_id), '[]'::jsonb);
end;
$$;

create or replace function public.admin_refund_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'not_authorized' using errcode = '42501'; end if;
  return (select jsonb_build_object(
    'total_requests', count(*),
    'pending_approval', count(*) filter (where status = 'requested'),
    'approved_not_executed', count(*) filter (where status = 'approved'),
    'processing_with_razorpay', count(*) filter (where status = 'submitted_to_provider'),
    'refunded', count(*) filter (where status = 'processed'),
    'failed', count(*) filter (where status = 'failed'),
    'rejected', count(*) filter (where status = 'rejected'),
    'total_refunded_cents', coalesce(sum(amount_cents) filter (where status = 'processed'), 0),
    'total_deductions_cents', coalesce(sum(calc_deduction_cents) filter (where status in ('approved', 'submitted_to_provider', 'processed')), 0),
    'outstanding_recovery_cents', coalesce((select sum(amount_cents - recovered_cents) from public.operator_recovery
                                             where status in ('open', 'partially_recovered')), 0)
  ) from public.refunds);
end;
$$;

revoke execute on function
  public.admin_preview_refund(uuid, uuid),
  public.admin_save_refund_policy(text, text, integer, integer, numeric, numeric, date, date, text, boolean, text, uuid),
  public.admin_set_refund_policy_status(uuid, text),
  public.admin_approve_refund(uuid, uuid), public.admin_override_refund(uuid, integer, text, uuid),
  public.admin_update_recovery(uuid, text, bigint, text),
  public.get_operator_refund_adjustments(uuid, date, date), public.list_operator_recoveries(uuid),
  public.get_booking_cancellation_policy(uuid), public.get_my_refund_status(uuid), public.admin_refund_dashboard()
  from public, anon;
grant execute on function
  public.admin_preview_refund(uuid, uuid),
  public.admin_save_refund_policy(text, text, integer, integer, numeric, numeric, date, date, text, boolean, text, uuid),
  public.admin_set_refund_policy_status(uuid, text),
  public.admin_approve_refund(uuid, uuid), public.admin_override_refund(uuid, integer, text, uuid),
  public.admin_update_recovery(uuid, text, bigint, text),
  public.get_operator_refund_adjustments(uuid, date, date), public.list_operator_recoveries(uuid),
  public.get_booking_cancellation_policy(uuid), public.get_my_refund_status(uuid), public.admin_refund_dashboard()
  to authenticated;
