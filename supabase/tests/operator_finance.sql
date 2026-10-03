-- =========================================================================
-- Checks for 20261002001900_settlements_and_earnings.sql
--   * trip financials keep sales, collected money, pending/failed payments and refunds apart
--     (refund initiated vs completed), commission (not configured / estimate / frozen),
--     net payable, paid, remaining; reconciliation discrepancy is 0
--   * settlements: created by admins from eligible sales only, never double-settled, partial and
--     failed payouts, paid needs a transaction reference and the full amount, clawback of
--     tickets cancelled after settlement, negative settlements carry forward
--   * operators can only read; staff/other operators/customers cannot see money
-- Everything is rolled back.  (Fares are 500.00 = 50000 cents per seat.)
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

create function pg_temp.pay(p_tag text) returns void language plpgsql security definer as $f$
declare o public.orders;
begin
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_' || p_tag, o.amount_cents);
end $f$;
grant execute on function pg_temp.pay(text) to authenticated;

create function pg_temp.fin() returns record language sql security definer as $f$
  select * from private.trip_financials(array[(select id from t_ref where tag = 'TRIP')]) $f$;

insert into auth.users (id, email) values ('99999999-0000-0000-0000-000000000009', 'staff@test.invalid');
insert into public.user_roles (user_id, role, operator_id)
  values ('99999999-0000-0000-0000-000000000009', 'operator_staff', (select id from t_ops where tag = 'A'));

-- O1 (seat 1) and O2 (seat 2) paid; O3 (seat 3) stays unpaid
do $$
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O1', 1);
  perform pg_temp.book('eeeeeeee-0000-0000-0000-00000000000e', 'O2', 2);
  perform pg_temp.as_server();
  perform pg_temp.pay('O1');
  perform pg_temp.pay('O2');
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O3', 3);
  perform pg_temp.as_server();
end $$;

-- ---- 1. no commission configured yet --------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  f jsonb; v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  f := public.get_trip_financials(v_trip);
  if (f ->> 'gross_cents')::bigint <> 100000 or (f ->> 'sold_tickets')::int <> 2 then raise exception 'FAIL 1a: gross/sold %', f; end if;
  if (f ->> 'collected_cents')::bigint <> 100000 then raise exception 'FAIL 1b: collected %', f ->> 'collected_cents'; end if;
  if (f ->> 'pending_payments_cents')::bigint <> 50000 then raise exception 'FAIL 1c: pending payments % (unpaid O3)', f ->> 'pending_payments_cents'; end if;
  if (f ->> 'failed_payments_cents')::bigint <> 0 or (f ->> 'refunds_initiated_cents')::bigint <> 0 or (f ->> 'refunds_completed_cents')::bigint <> 0 then
    raise exception 'FAIL 1d: failed/refunds should be zero %', f;
  end if;
  if (f ->> 'commission_configured')::boolean then raise exception 'FAIL 1e: commission must be reported as not configured'; end if;
  if (f ->> 'commission_cents')::bigint <> 0 or (f ->> 'net_payable_cents')::bigint <> 100000 then raise exception 'FAIL 1f: %', f; end if;
  if (f ->> 'discrepancy_cents')::bigint <> 0 then raise exception 'FAIL 1g: discrepancy %', f ->> 'discrepancy_cents'; end if;
  if (f ->> 'paid_cents')::bigint <> 0 or (f ->> 'remaining_cents')::bigint <> 100000 then raise exception 'FAIL 1h: paid/remaining'; end if;

  -- gross sales are NOT money received: a sold ticket with no captured payment shows up as a discrepancy
  perform pg_temp.as_server();
  update public.payments set status = 'failed' where id = (select id from public.payments order by created_at limit 1);
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  f := public.get_trip_financials(v_trip);
  if (f ->> 'collected_cents')::bigint <> 50000 or (f ->> 'failed_payments_cents')::bigint <> 50000 then raise exception 'FAIL 1i: collected vs failed %', f; end if;
  if (f ->> 'discrepancy_cents')::bigint <> -50000 then raise exception 'FAIL 1j: gross vs collected must be visible as a discrepancy %', f ->> 'discrepancy_cents'; end if;
  perform pg_temp.as_server();
  update public.payments set status = 'captured' where status = 'failed';
end $$;

-- ---- 2. access control --------------------------------------------------------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');   -- operator staff: no money
  begin perform public.get_trip_financials(v_trip); raise exception 'FAIL 2a: staff saw trip financials';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.get_operator_earnings_summary(v_a, current_date, current_date + 5); raise exception 'FAIL 2b: staff saw earnings';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_trip_financials(v_trip); raise exception 'FAIL 2c: operator B saw trip financials';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.get_operator_earnings_summary(v_a, current_date, current_date + 5); raise exception 'FAIL 2d: operator B saw earnings';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.list_operator_settlements(v_a); raise exception 'FAIL 2e: operator B listed settlements';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.get_trip_financials(v_trip); raise exception 'FAIL 2f: customer saw financials';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.get_trip_financials(v_trip);   -- platform admin may
  perform pg_temp.as_server();
end $$;

-- ---- 3. settlement preconditions (Gate D engine: boarding makes an earning eligible) -----------------------------
create function pg_temp.board_item(p_tag text) returns void language plpgsql security definer as $f$
declare v_item uuid;
begin
  select bi.id into v_item from public.booking_items bi join public.orders o on o.orderable_id = bi.booking_id
   where o.id = (select id from t_ref where tag = p_tag) limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', 'aaaaaaaa-0000-0000-0000-00000000000a', 'role', 'authenticated')::text, true);
  perform public.verify_passenger_boarding(v_item, true);
  perform public.confirm_boarding(v_item);
  perform set_config('request.jwt.claims', '', true);
end $f$;

do $$
declare v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.admin_create_settlement(v_a, current_date, current_date + 5); raise exception 'FAIL 3a: operator created a settlement';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_set_commission(v_a, 1000); raise exception 'FAIL 3b: operator set commission';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- nothing is eligible until passengers board
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  begin perform public.admin_create_settlement(v_a, current_date, current_date + 5); raise exception 'FAIL 3c: settled tickets nobody boarded';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%nothing_to_settle%' then raise exception 'FAIL 3d: %', sqlerrm; end if;
  end;
  perform pg_temp.as_server();
  perform pg_temp.board_item('O1');
  perform pg_temp.board_item('O2');
  update public.bus_trips set status = 'arrived' where id = (select id from t_ref where tag = 'TRIP');
  -- boarded but no commission rate: held, not settleable
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  begin perform public.admin_create_settlement(v_a, current_date, current_date + 5); raise exception 'FAIL 3e: settled without a commission rate';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%nothing_to_settle%' then raise exception 'FAIL 3f: %', sqlerrm; end if;
  end;
  perform pg_temp.as_server();
  if (select count(*) from public.operator_earnings where status = 'on_hold' and hold_reason = 'commission_not_configured') <> 2 then raise exception 'FAIL 3g: boarded earnings should be held'; end if;
end $$;

-- ---- 4. commission + settlement ------------------------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_a uuid := (select id from t_ops where tag = 'A');
  d jsonb; f jsonb; e jsonb;
begin
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_commission(null, 1000);   -- platform default 10%
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  f := public.get_trip_financials(v_trip);
  if (f ->> 'commission_cents')::bigint <> 10000 or (f ->> 'net_payable_cents')::bigint <> 90000 or not (f ->> 'commission_is_estimate')::boolean then
    raise exception 'FAIL 4a: estimated commission %', f;
  end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  d := public.admin_create_settlement(v_a, current_date, current_date + 5);
  insert into t_ref values ('SET1', (d ->> 'id')::uuid);
  if (d ->> 'gross_cents')::bigint <> 100000 or (d ->> 'commission_cents')::bigint <> 10000 or (d ->> 'net_payable_cents')::bigint <> 90000
     or (d ->> 'refunds_cents')::bigint <> 0 or d ->> 'status' <> 'draft' or (d ->> 'sale_items')::int <> 2 then
    raise exception 'FAIL 4b: settlement %', d;
  end if;
  if (d ->> 'net_payable_cents')::bigint <> (d ->> 'gross_cents')::bigint - (d ->> 'refunds_cents')::bigint - (d ->> 'commission_cents')::bigint - (d ->> 'other_deductions_cents')::bigint then
    raise exception 'FAIL 4c: settlement arithmetic';
  end if;

  -- not settled twice
  begin perform public.admin_create_settlement(v_a, current_date, current_date + 5); raise exception 'FAIL 4d: the same sales were settled twice';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  begin
    insert into public.settlement_items (settlement_id, booking_item_id, kind, fare_cents, commission_cents, net_cents)
    select (select id from t_ref where tag = 'SET1'), booking_item_id, 'sale', 1, 0, 1 from public.settlement_items limit 1;
    raise exception 'FAIL 4e: duplicate sale item accepted';
  exception when unique_violation then null; end;

  -- drafts are internal: the operator sees the batch only once an admin approved it
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  e := public.list_operator_settlements(v_a);
  if jsonb_array_length(e -> 'settlements') <> 0 then raise exception 'FAIL 4f: operator sees a draft %', e; end if;
  begin perform public.get_settlement_detail((select id from t_ref where tag = 'SET1')); raise exception 'FAIL 4g: operator read a draft';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin update public.settlements set status = 'paid'; raise exception 'FAIL 4h: operator updated a settlement';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_update_settlement((select id from t_ref where tag = 'SET1'), 'paid', 90000, 'bank', 'TX1'); raise exception 'FAIL 4i: operator marked a payout paid';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- an admin verifies the payout profile and approves; then the operator sees it
  perform pg_temp.as_server();
  insert into public.operator_bank_details (operator_id, account_holder_name, bank_name, account_number, ifsc)
    values (v_a, 'Operator A', 'SBI', '123456789012', 'SBIN0001234') on conflict (operator_id) do nothing;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_payment_profile_status(v_a, 'verified', null);
  perform public.admin_approve_settlement((select id from t_ref where tag = 'SET1'));
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  e := public.list_operator_settlements(v_a);
  if jsonb_array_length(e -> 'settlements') <> 1 or (e -> 'settlements' -> 0 ->> 'outstanding_cents')::bigint <> 90000 then raise exception 'FAIL 4j: list %', e; end if;
  e := public.get_settlement_detail((select id from t_ref where tag = 'SET1'));
  if (e ->> 'outstanding_cents')::bigint <> 90000 or e ->> 'txn_reference' is not null or e ->> 'status' <> 'approved' then raise exception 'FAIL 4k: detail %', e; end if;
  perform pg_temp.as_server();
end $$;

-- ---- 5. payout state (set by the bank-result import in Gate E; simulated here) ---------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_a uuid := (select id from t_ops where tag = 'A');
  v_set uuid := (select id from t_ref where tag = 'SET1'); d jsonb; f jsonb;
begin
  -- the manual status RPC is gone: nobody can mark a payout paid by hand
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  begin perform public.admin_update_settlement(v_set, 'paid', 90000, 'bank', 'TX'); raise exception 'FAIL 5a: manual paid accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'manual_status_updates_disabled%' then raise exception 'FAIL 5b: %', sqlerrm; end if; end;
  perform pg_temp.as_server();

  update public.settlements set status = 'exported', paid_cents = 45000, exported_at = now() where id = v_set;   -- partial bank result
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  f := public.get_trip_financials(v_trip);
  if (f ->> 'paid_cents')::bigint <> 45000 or (f ->> 'remaining_cents')::bigint <> 45000 then raise exception 'FAIL 5e: partial payout allocation %', f; end if;
  d := public.get_settlement_detail(v_set);
  if (d ->> 'outstanding_cents')::bigint <> 45000 then raise exception 'FAIL 5f: outstanding after a partial payout'; end if;

  perform pg_temp.as_server();
  update public.settlements set status = 'paid', paid_cents = 90000, txn_reference = 'UTR123456', completed_at = now(), bank_paid_at = now() where id = v_set;
  update public.operator_earnings set status = 'settled' where settlement_id = v_set;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  d := public.get_settlement_detail(v_set);
  if d ->> 'status' <> 'paid' or (d ->> 'outstanding_cents')::bigint <> 0 or d ->> 'txn_reference' <> 'UTR123456' then raise exception 'FAIL 5k: %', d; end if;
  f := public.get_trip_financials(v_trip);
  if (f ->> 'paid_cents')::bigint <> 90000 or (f ->> 'remaining_cents')::bigint <> 0 then raise exception 'FAIL 5l: %', f; end if;
  perform pg_temp.as_server();
  if (select count(*) from public.audit_logs where entity_type = 'settlement') < 2 then raise exception 'FAIL 5m: settlement changes must be audited'; end if;
end $$;

-- ---- 6. refunds: initiated vs completed, clawback after settlement --------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_a uuid := (select id from t_ops where tag = 'A');
  v_booking uuid := (select b.id from public.bookings b where b.customer_id = 'eeeeeeee-0000-0000-0000-00000000000e');
  f jsonb;
begin
  -- the trip departed long ago in this story; an admin cancels customer 2's booking
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.cancel_booking(v_booking, 'test cancellation');
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  f := public.get_trip_financials(v_trip);
  if (f ->> 'gross_cents')::bigint <> 50000 or (f ->> 'cancelled_value_cents')::bigint <> 50000 or (f ->> 'cancelled_bookings')::int <> 1 then
    raise exception 'FAIL 6a: after cancellation %', f;
  end if;
  if (f ->> 'refunds_initiated_cents')::bigint <> 50000 or (f ->> 'refunds_completed_cents')::bigint <> 0 then
    raise exception 'FAIL 6b: a refund request is not a completed refund %', f;
  end if;
  if (f ->> 'collected_cents')::bigint <> 100000 or (f ->> 'discrepancy_cents')::bigint <> 0 then raise exception 'FAIL 6c: money received is unchanged by a refund request %', f; end if;
  -- the operator was already paid for that ticket: the clawback is visible, remaining goes negative
  if (f ->> 'refund_deductions_cents')::bigint <> 45000 or (f ->> 'net_payable_cents')::bigint <> 45000 or (f ->> 'remaining_cents')::bigint <> -45000 then
    raise exception 'FAIL 6d: clawback %', f;
  end if;
  perform pg_temp.as_server();
  if (select amount_cents from public.operator_recovery) <> 45000 then raise exception 'FAIL 6d2: the clawback must become an operator recovery'; end if;

  update public.refunds set status = 'processed', processed_at = now();
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  f := public.get_trip_financials(v_trip);
  if (f ->> 'refunds_initiated_cents')::bigint <> 0 or (f ->> 'refunds_completed_cents')::bigint <> 50000 then raise exception 'FAIL 6e: completed refund %', f; end if;

  -- nothing new is eligible: no settlement is created, and no negative one
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  begin perform public.admin_create_settlement(v_a, current_date, current_date + 5); raise exception 'FAIL 6f: settlement created from nothing';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%nothing_to_settle%' and sqlerrm not like '%exists%' then raise exception 'FAIL 6g: %', sqlerrm; end if;
  end;
  perform pg_temp.as_server();
  if (select count(*) from public.settlements) <> 1 then raise exception 'FAIL 6h: a failed settlement left rows behind'; end if;
end $$;

-- ---- 7. earnings summary, trend, per-trip list, home --------------------------------------------------------
do $$
declare
  v_a uuid := (select id from t_ops where tag = 'A'); s jsonb; t jsonb; l jsonb; h jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  s := public.get_operator_earnings_summary(v_a, current_date, current_date + 5);
  if (s ->> 'gross_sales_cents')::bigint <> 50000 or (s ->> 'tickets_sold')::int <> 1 or (s ->> 'completed_bookings')::int <> 1 or (s ->> 'cancelled_bookings')::int <> 1 then
    raise exception 'FAIL 7a: summary %', s;
  end if;
  if (s ->> 'refunds_completed_cents')::bigint <> 50000 or (s ->> 'platform_fees_cents')::bigint <> 5000
     or (s ->> 'net_payable_cents')::bigint <> 45000 or (s ->> 'paid_to_operator_cents')::bigint <> 90000 then
    raise exception 'FAIL 7b: summary money %', s;
  end if;
  if (s -> 'settlements_by_status' -> 'paid' ->> 'count')::int <> 1 or (s -> 'settlements_by_status' -> 'paid' ->> 'net_cents')::bigint <> 90000
     or (s -> 'settlements_by_status' -> 'failed' ->> 'count')::int <> 0 then
    raise exception 'FAIL 7c: settlements by status %', s -> 'settlements_by_status';
  end if;
  -- outside the date range: nothing, and settlement history of other periods is not mixed in
  s := public.get_operator_earnings_summary(v_a, current_date - 30, current_date - 20);
  if (s ->> 'gross_sales_cents')::bigint <> 0 or (s ->> 'tickets_sold')::int <> 0 then raise exception 'FAIL 7d: empty range %', s; end if;
  if (public.get_operator_earnings_summary(v_a, current_date, current_date + 5, 'cargo') ->> 'supported')::boolean then raise exception 'FAIL 7e: cargo has no ledger yet'; end if;

  t := public.get_operator_revenue_trend(v_a, current_date, current_date + 5, 'day');
  if jsonb_array_length(t -> 'points') <> 1 or (t -> 'points' -> 0 ->> 'gross_cents')::bigint <> 50000 then raise exception 'FAIL 7f: trend %', t; end if;

  l := public.list_operator_earnings_by_trip(v_a, current_date, current_date + 5);
  if jsonb_array_length(l -> 'trips') <> 1 or (l -> 'trips' -> 0 ->> 'source_name') <> 'T Src' or (l -> 'trips' -> 0 ->> 'remaining_cents')::bigint <> -45000 then raise exception 'FAIL 7g: by trip %', l; end if;

  h := public.get_operator_home_summary(v_a);
  if (h ->> 'financials_visible')::boolean is not true or (h ->> 'pending_payout_cents') is null then raise exception 'FAIL 7h: home (admin) %', h; end if;
  -- staff see operations numbers but no money
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  h := public.get_operator_home_summary(v_a);
  if (h ->> 'financials_visible')::boolean or h -> 'pending_payout_cents' <> 'null'::jsonb or h -> 'todays_ticket_sales_cents' <> 'null'::jsonb then
    raise exception 'FAIL 7i: staff must not receive money fields %', h;
  end if;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_operator_home_summary(v_a); raise exception 'FAIL 7j: operator B read operator A home';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 8. history stays readable when the Bus service is disabled ---------------------------------------------------
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); s jsonb;
begin
  update public.operator_services set state = 'disabled' where operator_id = v_a and service_type = 'bus';
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  s := public.get_operator_earnings_summary(v_a, current_date, current_date + 5);
  if (s ->> 'paid_to_operator_cents')::bigint <> 90000 then raise exception 'FAIL 8a: history hidden after disabling %', s; end if;
  if jsonb_array_length(public.list_operator_settlements(v_a) -> 'settlements') <> 1 then raise exception 'FAIL 8b: settlements hidden'; end if;
  perform pg_temp.as_server();
end $$;

rollback;
