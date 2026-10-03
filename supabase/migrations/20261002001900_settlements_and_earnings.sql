-- =========================================================================
-- Operator settlements + earnings reads (Bus).
--
-- ONE calculation (private.trip_financials) feeds the trip dashboard, the Earnings tab, the
-- Home summary and settlement creation, so the screens can never disagree. Money comes only
-- from authoritative records: booking_items (sales), payments (collected), refunds (initiated
-- = pending, completed = processed), settlement_items/settlements (what was committed/paid).
--
--   gross              confirmed + completed ticket value
--   collected          captured payments (refunded ones included) allocated to the trip
--   refunds            initiated (pending) and completed (processed) are kept apart
--   commission         settled snapshot where an item was settled, otherwise rate x fare (estimate)
--   net payable        gross - commission                       (cancelled items are not in gross)
--   paid               settlement payments allocated to the trip's items (can go negative-free:
--                      a clawback of a cancelled-after-settlement item is a negative adjustment)
--   remaining          net payable - paid
--
-- Operators can only READ. Settlement status/paid amounts are written by platform admins
-- (or a payout service using the same RPC); no operator path can mark a payout paid.
-- Commission rate has no default: until an admin configures one, commission is reported as
-- "not configured" and settlements cannot be created.
-- =========================================================================

create table public.operator_commission_config (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid references public.operators (id) on delete cascade, -- null = platform default
  rate_bps integer not null check (rate_bps between 0 and 10000),
  effective_from date not null default current_date,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);
create index operator_commission_config_lookup_idx on public.operator_commission_config (operator_id, effective_from desc);
alter table public.operator_commission_config enable row level security;
create policy commission_config_select on public.operator_commission_config
  for select to authenticated
  using (private.is_platform_admin() or (operator_id is not null and private.is_operator_admin(operator_id)));
revoke all on public.operator_commission_config from anon, authenticated;
grant select on public.operator_commission_config to authenticated;

create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  operator_id uuid not null references public.operators (id),
  period_start date not null,
  period_end date not null,
  gross_cents bigint not null default 0,
  refunds_cents bigint not null default 0,
  commission_cents bigint not null default 0,
  other_deductions_cents bigint not null default 0,
  net_payable_cents bigint not null default 0,
  paid_cents bigint not null default 0,
  status text not null default 'pending' check (status in ('pending', 'processing', 'paid', 'failed', 'reversed')),
  method text,
  txn_reference text,
  failure_reason text,
  initiated_at timestamptz,
  completed_at timestamptz,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint settlements_net_chk check (net_payable_cents = gross_cents - refunds_cents - commission_cents - other_deductions_cents),
  constraint settlements_paid_chk check (paid_cents >= 0 and paid_cents <= greatest(net_payable_cents, 0)),
  constraint settlements_paid_status_chk check (status <> 'paid' or (txn_reference is not null and completed_at is not null and paid_cents = net_payable_cents))
);
create index settlements_operator_idx on public.settlements (operator_id, created_at desc);
create trigger set_updated_at before update on public.settlements for each row execute function private.set_updated_at();

create table public.settlement_items (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.settlements (id) on delete cascade,
  booking_item_id uuid not null references public.booking_items (id),
  kind text not null check (kind in ('sale', 'refund_adjustment')),
  fare_cents bigint not null check (fare_cents >= 0),
  commission_cents bigint not null check (commission_cents >= 0),
  created_at timestamptz not null default now()
);
-- an item is sold once and adjusted at most once: never double-settled
create unique index settlement_items_one_sale_idx on public.settlement_items (booking_item_id) where kind = 'sale';
create unique index settlement_items_one_adjustment_idx on public.settlement_items (booking_item_id) where kind = 'refund_adjustment';
create index settlement_items_settlement_idx on public.settlement_items (settlement_id);

alter table public.settlements enable row level security;
alter table public.settlement_items enable row level security;
create policy settlements_select on public.settlements
  for select to authenticated using (private.is_platform_admin() or private.is_operator_admin(operator_id));
create policy settlement_items_select on public.settlement_items
  for select to authenticated using (exists (
    select 1 from public.settlements s where s.id = settlement_id
      and (private.is_platform_admin() or private.is_operator_admin(s.operator_id))));
revoke all on public.settlements, public.settlement_items from anon, authenticated;
grant select on public.settlements, public.settlement_items to authenticated;

-- ---------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------
create or replace function private.commission_rate_bps(p_operator_id uuid, p_on date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select c.rate_bps
  from public.operator_commission_config c
  where (c.operator_id = p_operator_id or c.operator_id is null) and c.effective_from <= p_on
  order by (c.operator_id is not null) desc, c.effective_from desc, c.created_at desc
  limit 1;
$$;
revoke execute on function private.commission_rate_bps(uuid, date) from public, anon, authenticated;

create or replace function private.finance_access(p_operator_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (private.is_operator_admin(p_operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized to view financial information';
  end if;
end;
$$;
revoke execute on function private.finance_access(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- THE financial calculation, per trip
-- ---------------------------------------------------------------------
create or replace function private.trip_financials(p_trip_ids uuid[])
returns table (
  trip_id uuid,
  gross_cents bigint,
  sold_tickets integer,
  completed_bookings integer,
  cancelled_bookings integer,
  cancelled_value_cents bigint,
  collected_cents bigint,
  pending_payments_cents bigint,
  failed_payments_cents bigint,
  refunds_initiated_cents bigint,
  refunds_completed_cents bigint,
  commission_cents bigint,
  commission_estimated_cents bigint,
  commission_configured boolean,
  refund_deductions_cents bigint,
  other_deductions_cents bigint,
  net_payable_cents bigint,
  paid_cents bigint,
  remaining_cents bigint,
  discrepancy_cents bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  with t as (
    select bt.id, bt.operator_id, bt.travel_date from public.bus_trips bt where bt.id = any (p_trip_ids)
  ),
  rate as (select t.id as trip_id, private.commission_rate_bps(t.operator_id, t.travel_date) as bps from t),
  items as (
    select bi.id, bi.trip_id, bi.booking_id, bi.fare_cents, bi.status from public.booking_items bi where bi.trip_id = any (p_trip_ids)
  ),
  booking_total as (
    select bi.booking_id, sum(bi.fare_cents) as total
    from public.booking_items bi where bi.booking_id in (select booking_id from items) group by bi.booking_id
  ),
  share as (
    select i.booking_id, i.trip_id, sum(i.fare_cents)::numeric / nullif(bt.total, 0) as sh
    from items i join booking_total bt on bt.booking_id = i.booking_id group by i.booking_id, i.trip_id, bt.total
  ),
  pay as (
    select o.orderable_id as booking_id,
      coalesce(sum(p.amount_cents) filter (where p.status in ('captured', 'refunded')), 0) as collected,
      coalesce(sum(p.amount_cents) filter (where p.status = 'failed'), 0) as failed
    from public.orders o join public.payments p on p.order_id = o.id
    where o.orderable_type = 'booking' and o.orderable_id in (select booking_id from items)
    group by o.orderable_id
  ),
  ref as (
    select o.orderable_id as booking_id,
      coalesce(sum(r.amount_cents) filter (where r.status = 'pending'), 0) as r_init,
      coalesce(sum(r.amount_cents) filter (where r.status = 'processed'), 0) as r_done
    from public.orders o join public.payments p on p.order_id = o.id join public.refunds r on r.payment_id = p.id
    where o.orderable_type = 'booking' and o.orderable_id in (select booking_id from items)
    group by o.orderable_id
  ),
  pend as (
    select o.orderable_id as booking_id, sum(o.amount_cents) as amt
    from public.orders o join public.bookings b on b.id = o.orderable_id
    where o.orderable_type = 'booking' and o.status = 'created' and b.status = 'payment_pending'
      and o.orderable_id in (select booking_id from items)
    group by o.orderable_id
  ),
  alloc as (
    select s.trip_id,
      coalesce(sum(round(coalesce(p.collected, 0) * s.sh)), 0)::bigint as collected,
      coalesce(sum(round(coalesce(p.failed, 0) * s.sh)), 0)::bigint as failed,
      coalesce(sum(round(coalesce(r.r_init, 0) * s.sh)), 0)::bigint as r_init,
      coalesce(sum(round(coalesce(r.r_done, 0) * s.sh)), 0)::bigint as r_done,
      coalesce(sum(round(coalesce(pe.amt, 0) * s.sh)), 0)::bigint as pending
    from share s
    left join pay p on p.booking_id = s.booking_id
    left join ref r on r.booking_id = s.booking_id
    left join pend pe on pe.booking_id = s.booking_id
    group by s.trip_id
  ),
  sale as (
    select si.booking_item_id, si.fare_cents, si.commission_cents from public.settlement_items si where si.kind = 'sale'
  ),
  agg as (
    select i.trip_id,
      coalesce(sum(i.fare_cents) filter (where i.status in ('confirmed', 'completed')), 0)::bigint as gross,
      (count(*) filter (where i.status in ('confirmed', 'completed')))::int as sold,
      (count(distinct i.booking_id) filter (where i.status in ('confirmed', 'completed')))::int as bk_ok,
      (count(distinct i.booking_id) filter (where i.status = 'cancelled'))::int as bk_cancel,
      coalesce(sum(i.fare_cents) filter (where i.status = 'cancelled' and coalesce(p.collected, 0) > 0), 0)::bigint as cancelled_value,
      coalesce(sum(round(i.fare_cents * r.bps / 10000.0)) filter (
        where i.status in ('confirmed', 'completed') and sale.booking_item_id is null and r.bps is not null), 0)::bigint as comm_est,
      coalesce(sum(sale.commission_cents) filter (
        where i.status in ('confirmed', 'completed') and sale.booking_item_id is not null), 0)::bigint as comm_settled,
      coalesce(sum(sale.fare_cents - sale.commission_cents) filter (
        where i.status = 'cancelled' and sale.booking_item_id is not null), 0)::bigint as refund_ded,
      bool_or(r.bps is not null) as configured
    from items i
    left join pay p on p.booking_id = i.booking_id
    left join sale on sale.booking_item_id = i.id
    join rate r on r.trip_id = i.trip_id
    group by i.trip_id
  ),
  paid as (
    select bi.trip_id,
      coalesce(sum(case when s.net_payable_cents = 0 then 0
        else round(s.paid_cents::numeric * (case si.kind when 'sale' then 1 else -1 end * (si.fare_cents - si.commission_cents)) / s.net_payable_cents) end), 0)::bigint as paid
    from public.settlement_items si
    join public.settlements s on s.id = si.settlement_id
    join public.booking_items bi on bi.id = si.booking_item_id
    where bi.trip_id = any (p_trip_ids)
    group by bi.trip_id
  )
  select
    t.id,
    coalesce(a.gross, 0),
    coalesce(a.sold, 0),
    coalesce(a.bk_ok, 0),
    coalesce(a.bk_cancel, 0),
    coalesce(a.cancelled_value, 0),
    coalesce(al.collected, 0),
    coalesce(al.pending, 0),
    coalesce(al.failed, 0),
    coalesce(al.r_init, 0),
    coalesce(al.r_done, 0),
    coalesce(a.comm_est, 0) + coalesce(a.comm_settled, 0),
    coalesce(a.comm_est, 0),
    coalesce(a.configured, false),
    coalesce(a.refund_ded, 0),
    0::bigint,
    coalesce(a.gross, 0) - (coalesce(a.comm_est, 0) + coalesce(a.comm_settled, 0)),
    coalesce(pd.paid, 0),
    coalesce(a.gross, 0) - (coalesce(a.comm_est, 0) + coalesce(a.comm_settled, 0)) - coalesce(pd.paid, 0),
    coalesce(al.collected, 0) - coalesce(a.gross, 0) - coalesce(a.cancelled_value, 0)
  from t
  left join agg a on a.trip_id = t.id
  left join alloc al on al.trip_id = t.id
  left join paid pd on pd.trip_id = t.id;
$$;
revoke execute on function private.trip_financials(uuid[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- reads (operator admin or platform admin)
-- ---------------------------------------------------------------------
create or replace function public.get_trip_financials(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  f record;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  perform private.finance_access(v_trip.operator_id);
  select * into f from private.trip_financials(array[p_trip_id]);
  return to_jsonb(f) || jsonb_build_object(
    'as_of', now(),
    'commission_is_estimate', f.commission_estimated_cents > 0 or not f.commission_configured);
end;
$$;

create or replace function public.get_operator_earnings_summary(
  p_operator_id uuid, p_from date, p_to date, p_service text default 'bus')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
  s record;
  v_settle jsonb;
begin
  perform private.finance_access(p_operator_id);
  if p_service <> 'bus' then
    return jsonb_build_object('supported', false, 'service', p_service);
  end if;
  select coalesce(array_agg(t.id), '{}') into v_ids from public.bus_trips t
    where t.operator_id = p_operator_id and t.travel_date between p_from and p_to;

  select
    coalesce(sum(gross_cents), 0) as gross, coalesce(sum(sold_tickets), 0) as tickets,
    coalesce(sum(completed_bookings), 0) as bk_ok, coalesce(sum(cancelled_bookings), 0) as bk_cancel,
    coalesce(sum(cancelled_value_cents), 0) as cancelled_value, coalesce(sum(collected_cents), 0) as collected,
    coalesce(sum(pending_payments_cents), 0) as pending_pay, coalesce(sum(failed_payments_cents), 0) as failed_pay,
    coalesce(sum(refunds_initiated_cents), 0) as r_init, coalesce(sum(refunds_completed_cents), 0) as r_done,
    coalesce(sum(commission_cents), 0) as commission, coalesce(sum(commission_estimated_cents), 0) as comm_est,
    coalesce(sum(refund_deductions_cents), 0) as refund_ded, coalesce(sum(net_payable_cents), 0) as net,
    coalesce(sum(paid_cents), 0) as paid, coalesce(sum(remaining_cents), 0) as remaining,
    coalesce(sum(discrepancy_cents), 0) as discrepancy, coalesce(bool_or(commission_configured), false) as configured
  into s from private.trip_financials(v_ids);

  select jsonb_object_agg(st, jsonb_build_object('count', cnt, 'net_cents', net, 'paid_cents', paid, 'outstanding_cents', net - paid))
  into v_settle
  from (
    select x.st, count(se.id) as cnt, coalesce(sum(se.net_payable_cents), 0) as net, coalesce(sum(se.paid_cents), 0) as paid
    from (values ('paid'), ('processing'), ('pending'), ('failed'), ('reversed')) x(st)
    left join public.settlements se on se.status = x.st and se.operator_id = p_operator_id
      and se.created_at::date between p_from and p_to
    group by x.st
  ) q;

  return jsonb_build_object(
    'supported', true, 'service', 'bus', 'from', p_from, 'to', p_to, 'as_of', now(),
    'gross_sales_cents', s.gross,
    'tickets_sold', s.tickets,
    'completed_bookings', s.bk_ok,
    'cancelled_bookings', s.bk_cancel,
    'cancelled_value_cents', s.cancelled_value,
    'collected_cents', s.collected,
    'pending_payments_cents', s.pending_pay,
    'failed_payments_cents', s.failed_pay,
    'refunds_initiated_cents', s.r_init,
    'refunds_completed_cents', s.r_done,
    'platform_fees_cents', s.commission,
    'platform_fees_estimated_cents', s.comm_est,
    'commission_configured', s.configured,
    'refund_deductions_cents', s.refund_ded,
    'net_booking_value_cents', s.gross,
    'net_payable_cents', s.net,
    'paid_to_operator_cents', s.paid,
    'pending_settlement_cents', s.remaining,
    'discrepancy_cents', s.discrepancy,
    'settlements_by_status', v_settle
  );
end;
$$;

create or replace function public.get_operator_revenue_trend(
  p_operator_id uuid, p_from date, p_to date, p_bucket text default 'day', p_service text default 'bus')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
  v_rows jsonb;
begin
  perform private.finance_access(p_operator_id);
  if p_bucket not in ('day', 'week') then raise exception 'Unknown bucket %', p_bucket; end if;
  if p_service <> 'bus' then return jsonb_build_object('supported', false, 'points', '[]'::jsonb); end if;
  select coalesce(array_agg(t.id), '{}') into v_ids from public.bus_trips t
    where t.operator_id = p_operator_id and t.travel_date between p_from and p_to;

  select coalesce(jsonb_agg(jsonb_build_object(
      'bucket', b.bucket, 'gross_cents', b.gross, 'refunds_completed_cents', b.refunds,
      'commission_cents', b.commission, 'net_payable_cents', b.net, 'tickets', b.tickets) order by b.bucket), '[]'::jsonb)
  into v_rows
  from (
    select date_trunc(p_bucket, t.travel_date)::date as bucket,
      sum(f.gross_cents) as gross, sum(f.refunds_completed_cents) as refunds,
      sum(f.commission_cents) as commission, sum(f.net_payable_cents) as net, sum(f.sold_tickets) as tickets
    from private.trip_financials(v_ids) f join public.bus_trips t on t.id = f.trip_id
    group by 1
  ) b;
  return jsonb_build_object('supported', true, 'bucket', p_bucket, 'points', v_rows);
end;
$$;

create or replace function public.list_operator_earnings_by_trip(
  p_operator_id uuid, p_from date, p_to date, p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
  v_rows jsonb;
begin
  perform private.finance_access(p_operator_id);
  select coalesce(array_agg(x.id), '{}') into v_ids from (
    select t.id from public.bus_trips t where t.operator_id = p_operator_id and t.travel_date between p_from and p_to
    order by t.departure_at desc limit greatest(least(p_limit, 200), 1) offset greatest(p_offset, 0)) x;

  select coalesce(jsonb_agg(jsonb_build_object(
      'trip_id', t.id, 'travel_date', t.travel_date, 'departure_at', t.departure_at, 'status', t.status,
      'bus_registration', b.registration_number, 'source_name', src.name, 'destination_name', dst.name,
      'gross_cents', f.gross_cents, 'sold_tickets', f.sold_tickets, 'refunds_completed_cents', f.refunds_completed_cents,
      'commission_cents', f.commission_cents, 'net_payable_cents', f.net_payable_cents,
      'paid_cents', f.paid_cents, 'remaining_cents', f.remaining_cents) order by t.departure_at desc), '[]'::jsonb)
  into v_rows
  from private.trip_financials(v_ids) f
  join public.bus_trips t on t.id = f.trip_id
  join public.buses b on b.id = t.bus_id
  join public.bus_routes r on r.id = t.route_id
  left join public.locations src on src.id = r.source_city_id
  left join public.locations dst on dst.id = r.destination_city_id;
  return jsonb_build_object('trips', v_rows);
end;
$$;

create or replace function public.list_operator_settlements(
  p_operator_id uuid, p_status text default null, p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rows jsonb;
begin
  perform private.finance_access(p_operator_id);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'reference', s.reference, 'status', s.status, 'net_payable_cents', s.net_payable_cents,
      'paid_cents', s.paid_cents, 'outstanding_cents', greatest(s.net_payable_cents - s.paid_cents, 0),
      'period_start', s.period_start, 'period_end', s.period_end, 'initiated_at', s.initiated_at,
      'completed_at', s.completed_at, 'method', s.method, 'txn_reference', s.txn_reference,
      'created_at', s.created_at) order by s.created_at desc), '[]'::jsonb)
  into v_rows
  from (select * from public.settlements where operator_id = p_operator_id and (p_status is null or status = p_status)
        order by created_at desc limit greatest(least(p_limit, 200), 1) offset greatest(p_offset, 0)) s;
  return jsonb_build_object('settlements', v_rows);
end;
$$;

create or replace function public.get_settlement_detail(p_settlement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s public.settlements;
  v_sales int; v_adj int; v_trips int;
begin
  select * into s from public.settlements where id = p_settlement_id;
  if s.id is null then raise exception 'Settlement not found'; end if;
  perform private.finance_access(s.operator_id);
  select count(*) filter (where kind = 'sale'), count(*) filter (where kind = 'refund_adjustment'),
         (select count(distinct bi.trip_id) from public.settlement_items x join public.booking_items bi on bi.id = x.booking_item_id where x.settlement_id = s.id)
    into v_sales, v_adj, v_trips from public.settlement_items where settlement_id = s.id;
  return jsonb_build_object(
    'id', s.id, 'reference', s.reference, 'status', s.status, 'method', s.method, 'txn_reference', s.txn_reference,
    'failure_reason', s.failure_reason, 'period_start', s.period_start, 'period_end', s.period_end,
    'initiated_at', s.initiated_at, 'completed_at', s.completed_at, 'created_at', s.created_at,
    'gross_cents', s.gross_cents, 'refunds_cents', s.refunds_cents, 'commission_cents', s.commission_cents,
    'other_deductions_cents', s.other_deductions_cents, 'net_payable_cents', s.net_payable_cents,
    'paid_cents', s.paid_cents, 'outstanding_cents', greatest(s.net_payable_cents - s.paid_cents, 0),
    'sale_items', v_sales, 'adjustment_items', v_adj, 'trips', v_trips);
end;
$$;

create or replace function public.get_operator_home_summary(p_operator_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_is_admin boolean;
  v_today jsonb;
  v_upcoming jsonb;
  v_today_trips int; v_active int; v_tickets int;
  v_sales bigint := null; v_pending bigint := null;
  v_ids uuid[];
  v_day date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not (private.is_operator_staff(p_operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  v_is_admin := private.is_operator_admin(p_operator_id) or private.is_platform_admin();

  select coalesce(jsonb_agg(x.j order by x.dep), '[]'::jsonb), count(*)::int, coalesce(sum(x.sold), 0)::int
  into v_today, v_today_trips, v_tickets
  from (
    select t.departure_at as dep,
      (select count(*) from public.trip_seats ts where ts.trip_id = t.id and ts.status in ('booked', 'boarded')) as sold,
      jsonb_build_object(
        'id', t.id, 'status', t.status, 'departure_at', t.departure_at, 'arrival_at', t.arrival_at,
        'bus_registration', b.registration_number, 'source_name', src.name, 'destination_name', dst.name,
        'sold_seats', (select count(*) from public.trip_seats ts where ts.trip_id = t.id and ts.status in ('booked', 'boarded')),
        'total_seats', (select count(*) from public.trip_seats ts where ts.trip_id = t.id)) as j
    from public.bus_trips t
    join public.buses b on b.id = t.bus_id
    join public.bus_routes r on r.id = t.route_id
    left join public.locations src on src.id = r.source_city_id
    left join public.locations dst on dst.id = r.destination_city_id
    where t.operator_id = p_operator_id and t.travel_date = v_day and t.status <> 'cancelled'
  ) x;

  select count(*)::int into v_active from public.bus_trips where operator_id = p_operator_id and status in ('boarding', 'departed');

  select coalesce(jsonb_agg(x.j order by x.dep), '[]'::jsonb) into v_upcoming
  from (
    select t.departure_at as dep, jsonb_build_object(
      'id', t.id, 'status', t.status, 'departure_at', t.departure_at, 'arrival_at', t.arrival_at,
      'bus_registration', b.registration_number, 'source_name', src.name, 'destination_name', dst.name,
      'sold_seats', (select count(*) from public.trip_seats ts where ts.trip_id = t.id and ts.status in ('booked', 'boarded')),
      'total_seats', (select count(*) from public.trip_seats ts where ts.trip_id = t.id)) as j
    from public.bus_trips t
    join public.buses b on b.id = t.bus_id
    join public.bus_routes r on r.id = t.route_id
    left join public.locations src on src.id = r.source_city_id
    left join public.locations dst on dst.id = r.destination_city_id
    where t.operator_id = p_operator_id and t.status = 'scheduled' and t.departure_at > now()
    order by t.departure_at limit 3
  ) x;

  if v_is_admin then
    select coalesce(array_agg(t.id), '{}') into v_ids from public.bus_trips t where t.operator_id = p_operator_id and t.travel_date = v_day;
    select coalesce(sum(gross_cents), 0) into v_sales from private.trip_financials(v_ids);
    select coalesce(array_agg(t.id), '{}') into v_ids from public.bus_trips t where t.operator_id = p_operator_id and t.status = 'arrived';
    select coalesce(sum(greatest(remaining_cents, 0)), 0) into v_pending from private.trip_financials(v_ids);
  end if;

  return jsonb_build_object(
    'as_of', now(), 'financials_visible', v_is_admin,
    'todays_trips', v_today_trips, 'active_trips', v_active, 'tickets_sold_today', v_tickets,
    'todays_ticket_sales_cents', v_sales, 'pending_payout_cents', v_pending,
    'today', v_today, 'upcoming', v_upcoming);
end;
$$;

-- ---------------------------------------------------------------------
-- admin: commission + settlements (operators have NO write path)
-- ---------------------------------------------------------------------
create or replace function public.admin_set_commission(p_operator_id uuid, p_rate_bps integer, p_effective_from date default current_date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  insert into public.operator_commission_config (operator_id, rate_bps, effective_from, created_by)
  values (p_operator_id, p_rate_bps, coalesce(p_effective_from, current_date), (select auth.uid())) returning id into v_id;
  perform private.write_audit('commission.set', 'operator', p_operator_id, null,
    jsonb_build_object('rate_bps', p_rate_bps, 'effective_from', p_effective_from));
  return v_id;
end;
$$;

create or replace function public.admin_create_settlement(p_operator_id uuid, p_period_start date, p_period_end date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := gen_random_uuid();
  v_ref text;
  v_gross bigint; v_adj_fare bigint; v_comm bigint; v_n_sale int; v_n_adj int;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  if p_period_end < p_period_start then raise exception 'Invalid period'; end if;
  perform 1 from public.operators where id = p_operator_id for update;   -- one settlement run per operator at a time

  if exists (
    select 1 from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
    where t.operator_id = p_operator_id and t.status = 'arrived' and t.travel_date between p_period_start and p_period_end
      and bi.status in ('confirmed', 'completed')
      and private.commission_rate_bps(t.operator_id, t.travel_date) is null) then
    raise exception 'commission_not_configured: set a commission rate before creating settlements';
  end if;

  v_ref := 'ST-' || upper(substr(replace(v_id::text, '-', ''), 1, 8));
  insert into public.settlements (id, reference, operator_id, period_start, period_end, created_by)
  values (v_id, v_ref, p_operator_id, p_period_start, p_period_end, (select auth.uid()));

  -- sales of finished trips that were never settled, with the commission frozen now
  insert into public.settlement_items (settlement_id, booking_item_id, kind, fare_cents, commission_cents)
  select v_id, bi.id, 'sale', bi.fare_cents,
         round(bi.fare_cents * private.commission_rate_bps(t.operator_id, t.travel_date) / 10000.0)::bigint
  from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
  where t.operator_id = p_operator_id and t.status = 'arrived' and t.travel_date between p_period_start and p_period_end
    and bi.status in ('confirmed', 'completed')
    and not exists (select 1 from public.settlement_items x where x.booking_item_id = bi.id and x.kind = 'sale');

  -- clawback of tickets that were settled earlier and cancelled since
  insert into public.settlement_items (settlement_id, booking_item_id, kind, fare_cents, commission_cents)
  select v_id, bi.id, 'refund_adjustment', sale.fare_cents, sale.commission_cents
  from public.booking_items bi
  join public.bus_trips t on t.id = bi.trip_id
  join public.settlement_items sale on sale.booking_item_id = bi.id and sale.kind = 'sale'
  where t.operator_id = p_operator_id and bi.status = 'cancelled'
    and not exists (select 1 from public.settlement_items x where x.booking_item_id = bi.id and x.kind = 'refund_adjustment');

  select coalesce(sum(fare_cents) filter (where kind = 'sale'), 0), coalesce(sum(fare_cents) filter (where kind = 'refund_adjustment'), 0),
         coalesce(sum(commission_cents) filter (where kind = 'sale'), 0) - coalesce(sum(commission_cents) filter (where kind = 'refund_adjustment'), 0),
         count(*) filter (where kind = 'sale'), count(*) filter (where kind = 'refund_adjustment')
    into v_gross, v_adj_fare, v_comm, v_n_sale, v_n_adj
    from public.settlement_items where settlement_id = v_id;

  if v_n_sale + v_n_adj = 0 then raise exception 'nothing_to_settle: no unsettled sales or adjustments in this period'; end if;
  if v_gross - v_adj_fare - v_comm < 0 then
    raise exception 'negative_settlement: adjustments exceed sales; they carry forward to the next settlement';
  end if;

  update public.settlements
     set gross_cents = v_gross, refunds_cents = v_adj_fare, commission_cents = v_comm,
         net_payable_cents = v_gross - v_adj_fare - v_comm
   where id = v_id;
  perform private.write_audit('settlement.create', 'settlement', v_id, null,
    jsonb_build_object('reference', v_ref, 'operator_id', p_operator_id, 'sales', v_n_sale, 'adjustments', v_n_adj));
  return public.get_settlement_detail(v_id);
end;
$$;

-- Status / payout recording by a platform admin (or a payout service acting as one).
create or replace function public.admin_update_settlement(
  p_settlement_id uuid, p_status text, p_paid_cents bigint default null,
  p_method text default null, p_txn_reference text default null, p_failure_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.settlements;
  v_paid bigint;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can record settlement payments'; end if;
  select * into s from public.settlements where id = p_settlement_id for update;
  if s.id is null then raise exception 'Settlement not found'; end if;
  if p_status not in ('pending', 'processing', 'paid', 'failed', 'reversed') then raise exception 'Unknown status %', p_status; end if;
  if not ((s.status = 'pending' and p_status in ('processing', 'failed'))
       or (s.status = 'processing' and p_status in ('processing', 'paid', 'failed'))
       or (s.status = 'failed' and p_status in ('processing', 'pending'))
       or (s.status = 'paid' and p_status = 'reversed')) then
    raise exception 'invalid_transition: % -> %', s.status, p_status;
  end if;

  v_paid := coalesce(p_paid_cents, s.paid_cents);
  if p_status = 'reversed' then v_paid := 0; end if;
  if v_paid < 0 or v_paid > greatest(s.net_payable_cents, 0) then raise exception 'invalid_amount: paid amount must be between 0 and the net payable'; end if;
  if p_status = 'paid' and (coalesce(btrim(p_txn_reference), '') = '' and s.txn_reference is null) then
    raise exception 'txn_reference_required: a verified transaction reference is required to mark a settlement paid';
  end if;
  if p_status = 'paid' and v_paid <> s.net_payable_cents then
    raise exception 'invalid_amount: a paid settlement must be paid in full';
  end if;
  if p_status = 'failed' and coalesce(btrim(p_failure_reason), '') = '' then raise exception 'A failure reason is required'; end if;

  update public.settlements set
    status = p_status,
    paid_cents = v_paid,
    method = coalesce(p_method, method),
    txn_reference = coalesce(nullif(btrim(p_txn_reference), ''), txn_reference),
    failure_reason = case when p_status = 'failed' then p_failure_reason when p_status in ('processing', 'paid') then null else failure_reason end,
    initiated_at = case when p_status in ('processing', 'paid') then coalesce(initiated_at, now()) else initiated_at end,
    completed_at = case when p_status = 'paid' then now() when p_status in ('reversed', 'processing', 'pending', 'failed') then null else completed_at end
  where id = p_settlement_id;

  perform private.write_audit('settlement.' || p_status, 'settlement', p_settlement_id,
    jsonb_build_object('status', s.status, 'paid_cents', s.paid_cents),
    jsonb_build_object('status', p_status, 'paid_cents', v_paid, 'txn_reference', p_txn_reference));
  return public.get_settlement_detail(p_settlement_id);
end;
$$;

revoke execute on function public.get_trip_financials(uuid) from public, anon;
revoke execute on function public.get_operator_earnings_summary(uuid, date, date, text) from public, anon;
revoke execute on function public.get_operator_revenue_trend(uuid, date, date, text, text) from public, anon;
revoke execute on function public.list_operator_earnings_by_trip(uuid, date, date, int, int) from public, anon;
revoke execute on function public.list_operator_settlements(uuid, text, int, int) from public, anon;
revoke execute on function public.get_settlement_detail(uuid) from public, anon;
revoke execute on function public.get_operator_home_summary(uuid) from public, anon;
revoke execute on function public.admin_set_commission(uuid, integer, date) from public, anon;
revoke execute on function public.admin_create_settlement(uuid, date, date) from public, anon;
revoke execute on function public.admin_update_settlement(uuid, text, bigint, text, text, text) from public, anon;
grant execute on function public.get_trip_financials(uuid) to authenticated;
grant execute on function public.get_operator_earnings_summary(uuid, date, date, text) to authenticated;
grant execute on function public.get_operator_revenue_trend(uuid, date, date, text, text) to authenticated;
grant execute on function public.list_operator_earnings_by_trip(uuid, date, date, int, int) to authenticated;
grant execute on function public.list_operator_settlements(uuid, text, int, int) to authenticated;
grant execute on function public.get_settlement_detail(uuid) to authenticated;
grant execute on function public.get_operator_home_summary(uuid) to authenticated;
grant execute on function public.admin_set_commission(uuid, integer, date) to authenticated;
grant execute on function public.admin_create_settlement(uuid, date, date) to authenticated;
grant execute on function public.admin_update_settlement(uuid, text, bigint, text, text, text) to authenticated;

-- the service-disable warning now uses real settlement data
create or replace function public.get_service_disable_impact(
  p_operator_id uuid,
  p_service public.operator_service_type
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active_trips int := 0;
  v_upcoming_trips int := 0;
  v_pending_bookings int := 0;
  v_confirmed_bookings int := 0;
  v_unsettled bigint := 0;
  v_active_shipments int := 0;
  v_ids uuid[];
begin
  if not (private.is_operator_staff(p_operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  if p_service = 'bus' then
    select count(*) into v_active_trips
      from public.bus_trips t where t.operator_id = p_operator_id and t.status in ('boarding', 'departed');
    select count(*) into v_upcoming_trips
      from public.bus_trips t where t.operator_id = p_operator_id and t.status = 'scheduled' and t.departure_at > now();
    select count(*) into v_pending_bookings
      from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
      where t.operator_id = p_operator_id and bi.status = 'payment_pending';
    select count(*) into v_confirmed_bookings
      from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
      where t.operator_id = p_operator_id and bi.status = 'confirmed' and t.status in ('scheduled', 'boarding', 'departed');
    select coalesce(array_agg(t.id), '{}') into v_ids from public.bus_trips t where t.operator_id = p_operator_id;
    select coalesce(sum(greatest(remaining_cents, 0)), 0) into v_unsettled from private.trip_financials(v_ids);
  elsif p_service = 'cargo' then
    select count(*) into v_active_shipments
      from public.cargo_shipments c
      where c.operator_id = p_operator_id
        and c.status in ('confirmed', 'picked_up', 'in_transit', 'arrived_at_hub', 'out_for_delivery');
  end if;

  return jsonb_build_object(
    'service', p_service,
    'active_trips', v_active_trips,
    'upcoming_trips', v_upcoming_trips,
    'pending_bookings', v_pending_bookings,
    'confirmed_bookings', v_confirmed_bookings,
    'active_shipments', v_active_shipments,
    'unsettled_cents', v_unsettled,
    'has_blockers', (v_active_trips + v_upcoming_trips + v_pending_bookings + v_confirmed_bookings + v_active_shipments) > 0
                    or v_unsettled > 0
  );
end;
$$;
