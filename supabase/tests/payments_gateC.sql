-- =========================================================================
-- Checks for Gate C (20261003000500_gatec_operator_earnings.sql)
--   * commission: integer paise, floor rounding, immutable snapshot, windows / no overlap,
--     full-admin only, a missing rate holds the earning until one is set
--   * earning lifecycle: pending_boarding -> eligible on boarding (never on payment alone)
--   * ledger event 2 posted once per boarding cycle; correction reverses and re-posts
--   * duplicate scan, wrong operator
--   * cancellation before / after eligibility, after settlement (recovery + clawback), in a batch (blocked)
--   * refund pending holds the earning; rejection releases it
--   * breakdown RPC reconciles with private.trip_financials; RLS isolation
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

insert into auth.users (id, email) values ('77777777-0000-0000-0000-000000000007', 'support@test.invalid');
insert into public.user_roles (user_id, role) values ('77777777-0000-0000-0000-000000000007', 'platform_support');

create function pg_temp.reset_all() returns void language plpgsql as $f$
begin
  perform pg_temp.as_server();
  set constraints all immediate;
  alter table public.ledger_journals disable trigger ledger_journals_immutable;
  alter table public.ledger_entries disable trigger ledger_entries_immutable;
  delete from public.operator_earnings;
  delete from public.ledger_entries;
  delete from public.ledger_journals;
  alter table public.ledger_journals enable trigger ledger_journals_immutable;
  alter table public.ledger_entries enable trigger ledger_entries_immutable;
  delete from public.reconciliation_exceptions;
  delete from public.refunds;
  delete from public.payments;
  delete from public.orders;
  delete from public.boarding_events;
  delete from public.passenger_boarding;
  delete from public.booking_items;
  delete from public.passenger_identity;
  delete from public.passengers;
  delete from public.booking_status_history;
  delete from public.bookings;
  update public.trip_seats set status = 'available', hold_id = null;
  delete from public.seat_holds;
  set constraints all deferred;
end $f$;

create function pg_temp.bal(p_code text) returns bigint language sql as $f$
  select coalesce(sum(balance_cents), 0)::bigint from public.ledger_account_balances where account_code = p_code
$f$;
create function pg_temp.item_of(p_tag text) returns uuid language sql security definer as $f$
  select bi.id from public.booking_items bi join public.orders o on o.orderable_id = bi.booking_id
   where o.id = (select id from t_ref where tag = p_tag) limit 1
$f$;
create function pg_temp.earn(p_tag text) returns public.operator_earnings language sql security definer as $f$
  select e from public.operator_earnings e where e.booking_item_id = pg_temp.item_of(p_tag)
$f$;
-- book + pay as customer 1 (seat n), as the server
create function pg_temp.sale(p_tag text, p_seat int, p_pay text) returns void language plpgsql as $f$
declare o public.orders;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', p_tag, p_seat);
  perform pg_temp.as_server();
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, p_pay, o.amount_cents, 'INR');
end $f$;
-- board as operator A's admin (verify then confirm); returns the confirm result
create function pg_temp.board(p_tag text) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  r := public.verify_passenger_boarding(pg_temp.item_of(p_tag), true);
  r := public.confirm_boarding(pg_temp.item_of(p_tag));
  perform pg_temp.as_server();
  return r;
end $f$;
create function pg_temp.set_rate(p_bps int) returns void language plpgsql as $f$
begin
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_commission((select id from t_ops where tag = 'A'), p_bps);
  perform pg_temp.as_server();
end $f$;

-- ---- 1. payment alone is not eligibility; a missing rate holds the earning ---------
do $$
declare e public.operator_earnings; r jsonb;
begin
  perform pg_temp.sale('S1', 1, 'pay_1');
  e := pg_temp.earn('S1');
  if e.id is null or e.status <> 'pending_boarding' or e.gross_cents <> 50000 then raise exception 'FAIL 1a: earning not created pending_boarding: %', e; end if;
  if e.commission_bps is not null then raise exception 'FAIL 1b: commission resolved with no rate configured'; end if;

  r := pg_temp.board('S1');
  e := pg_temp.earn('S1');
  if e.status <> 'on_hold' or e.hold_reason <> 'commission_not_configured' or e.eligible_at is not null then
    raise exception 'FAIL 1c: boarded without a rate should be held: %', e;
  end if;
  if exists (select 1 from public.ledger_journals where event_type = 'earning_eligible') then raise exception 'FAIL 1d: journal posted without a commission'; end if;

  perform pg_temp.set_rate(1000);
  e := pg_temp.earn('S1');
  if e.status <> 'eligible' or e.commission_bps <> 1000 or e.commission_cents <> 5000 or e.operator_net_cents <> 45000 then
    raise exception 'FAIL 1e: setting the rate did not release the earning: %', e;
  end if;
  if pg_temp.bal('operator_payable') <> 45000 or pg_temp.bal('platform_commission') <> 5000 or pg_temp.bal('booking_liability') <> 0 then
    raise exception 'FAIL 1f: event 2 balances wrong (% / % / %)', pg_temp.bal('operator_payable'), pg_temp.bal('platform_commission'), pg_temp.bal('booking_liability');
  end if;
  if (select operator_id from public.ledger_entries where journal_id = e.eligible_journal_id and amount_cents = 45000) is distinct from (select id from t_ops where tag = 'A') then
    raise exception 'FAIL 1g: operator dimension missing on operator_payable';
  end if;
end $$;

-- ---- 2. snapshot immutability + rate changes only affect later sales --------------
do $$
declare e1 public.operator_earnings; e2 public.operator_earnings;
begin
  perform pg_temp.set_rate(2000);     -- same effective date: replaces the 10% row for NEW sales
  e1 := pg_temp.earn('S1');
  if e1.commission_bps <> 1000 or e1.commission_cents <> 5000 then raise exception 'FAIL 2a: a rate change rewrote history: %', e1; end if;

  perform pg_temp.sale('S2', 2, 'pay_2');
  e2 := pg_temp.earn('S2');
  if e2.commission_bps <> 2000 or e2.commission_cents <> 10000 or e2.operator_net_cents <> 40000 then raise exception 'FAIL 2b: new sale not on the new rate: %', e2; end if;
  if e2.status <> 'pending_boarding' then raise exception 'FAIL 2c: new sale must wait for boarding'; end if;

  begin update public.operator_earnings set commission_bps = 0, commission_cents = 0, operator_net_cents = 50000 where id = e1.id;
    raise exception 'FAIL 2d: snapshot updated';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin update public.operator_earnings set gross_cents = 1 where id = e1.id; raise exception 'FAIL 2e: gross updated';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin update public.operator_earnings set operator_id = (select id from t_ops where tag = 'B') where id = e1.id; raise exception 'FAIL 2f: operator updated';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- ---- 3. floor rounding on an uneven fare ------------------------------------------
select pg_temp.reset_all();
do $$
declare o public.orders; e public.operator_earnings;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'S3', 1);
  perform pg_temp.as_server();
  update public.booking_items set fare_cents = 33333 where booking_id = (select orderable_id from public.orders where id = (select id from t_ref where tag = 'S3'));
  update public.bookings set total_fare_cents = 33333 where id = (select orderable_id from public.orders where id = (select id from t_ref where tag = 'S3'));
  update public.orders set amount_cents = 33333 where id = (select id from t_ref where tag = 'S3');
  select * into o from public.orders where id = (select id from t_ref where tag = 'S3');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_3', 33333, 'INR');
  e := pg_temp.earn('S3');
  if e.commission_cents <> 4000 or e.operator_net_cents <> 29333 then   -- 2000 bps: 6666.6 -> floor 6666?  see below
    null;
  end if;
  if e.commission_cents <> floor(33333 * 2000 / 10000.0) or e.commission_cents + e.operator_net_cents <> 33333 then
    raise exception 'FAIL 3a: rounding: commission %, net %', e.commission_cents, e.operator_net_cents;
  end if;
  if e.commission_cents <> 6666 or e.operator_net_cents <> 26667 then raise exception 'FAIL 3b: floor to commission, remainder to operator (got % / %)', e.commission_cents, e.operator_net_cents; end if;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.verify_passenger_boarding(pg_temp.item_of('S3'), true);
  perform public.confirm_boarding(pg_temp.item_of('S3'));
  perform pg_temp.as_server();
  if pg_temp.bal('operator_payable') <> 26667 or pg_temp.bal('platform_commission') <> 6666 or pg_temp.bal('booking_liability') <> 0 then
    raise exception 'FAIL 3c: journal does not match the split';
  end if;
end $$;

-- ---- 4. duplicate scan, wrong operator, correction cycles -----------------------------
select pg_temp.reset_all();
select pg_temp.set_rate(1000);   -- back to 10% for the remaining sections
do $$
declare r jsonb; e public.operator_earnings; n int;
begin
  perform pg_temp.sale('S4', 1, 'pay_4');
  r := pg_temp.board('S4');
  e := pg_temp.earn('S4');
  if e.status <> 'eligible' or e.eligible_cycle <> 1 then raise exception 'FAIL 4a: %', e; end if;

  -- scanning again: rejected, no second journal
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  r := public.confirm_boarding(pg_temp.item_of('S4'));
  perform pg_temp.as_server();
  if coalesce((r ->> 'ok')::boolean, true) then raise exception 'FAIL 4b: duplicate boarding accepted: %', r; end if;
  select count(*) into n from public.ledger_journals where event_type = 'earning_eligible';
  if n <> 1 then raise exception 'FAIL 4c: duplicate scan posted % journals', n; end if;

  -- operator B cannot board A's passenger (and earns nothing from it)
  perform pg_temp.sale('S4B', 2, 'pay_4b');
  begin perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
    perform public.verify_passenger_boarding(pg_temp.item_of('S4B'), true); raise exception 'FAIL 4d: operator B verified';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  if (pg_temp.earn('S4B')).status <> 'pending_boarding' then raise exception 'FAIL 4e: wrong-operator scan changed the earning'; end if;

  -- correction: eligibility is withdrawn and event 2 reversed
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.correct_boarding(pg_temp.item_of('S4'), 'scanned the wrong passenger');
  perform pg_temp.as_server();
  e := pg_temp.earn('S4');
  if e.status <> 'pending_boarding' or e.eligible_at is not null or e.eligible_journal_id is not null then raise exception 'FAIL 4f: correction did not withdraw eligibility: %', e; end if;
  if pg_temp.bal('operator_payable') <> 0 or pg_temp.bal('platform_commission') <> 0 or pg_temp.bal('booking_liability') <> 100000 then
    raise exception 'FAIL 4g: reversal did not restore the liability (% / % / %)', pg_temp.bal('operator_payable'), pg_temp.bal('platform_commission'), pg_temp.bal('booking_liability');
  end if;

  -- boarded again: a NEW cycle, one live set of balances
  r := pg_temp.board('S4');
  e := pg_temp.earn('S4');
  if e.status <> 'eligible' or e.eligible_cycle <> 2 then raise exception 'FAIL 4h: second cycle %', e; end if;
  if pg_temp.bal('operator_payable') <> 45000 or pg_temp.bal('platform_commission') <> 5000 or pg_temp.bal('booking_liability') <> 50000 then
    raise exception 'FAIL 4i: balances after re-board (% / % / %)', pg_temp.bal('operator_payable'), pg_temp.bal('platform_commission'), pg_temp.bal('booking_liability');
  end if;
end $$;
-- (the S4B sale above holds a second 50000 in booking_liability, so liability is 100000 / 50000 in section 4)

-- ---- 5. cancellation: before boarding, after eligibility --------------------------------
select pg_temp.reset_all();
do $$
declare e public.operator_earnings; v_booking uuid;
begin
  -- 5a: cancelled before boarding
  perform pg_temp.sale('S5', 1, 'pay_5');
  select orderable_id into v_booking from public.orders where id = (select id from t_ref where tag = 'S5');
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking(v_booking, 'plans changed');
  perform pg_temp.as_server();
  e := pg_temp.earn('S5');
  if e.status <> 'void' or e.refund_adjustment_cents <> 45000 then raise exception 'FAIL 5a: %', e; end if;

  -- 5b: boarded (eligible) then cancelled by an admin: event 2 is reversed
  perform pg_temp.sale('S5B', 2, 'pay_5b');
  perform pg_temp.board('S5B');
  select orderable_id into v_booking from public.orders where id = (select id from t_ref where tag = 'S5B');
  if pg_temp.bal('operator_payable') <> 45000 then raise exception 'FAIL 5b0: setup'; end if;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.cancel_booking(v_booking, 'admin cancel');
  perform pg_temp.as_server();
  e := pg_temp.earn('S5B');
  if e.status <> 'void' or e.eligible_journal_id is not null then raise exception 'FAIL 5b: %', e; end if;
  if pg_temp.bal('operator_payable') <> 0 or pg_temp.bal('platform_commission') <> 0 then raise exception 'FAIL 5c: cancellation left operator money on the ledger'; end if;
  -- the customer's money is back in booking_liability for BOTH cancelled tickets, ready for the refund journals
  if pg_temp.bal('booking_liability') <> 100000 then raise exception 'FAIL 5d: liability % (expected 100000)', pg_temp.bal('booking_liability'); end if;
end $$;

-- ---- 6. refund pending holds the earning; rejection releases it ----------------------------
select pg_temp.reset_all();
do $$
declare e public.operator_earnings; v_pay uuid; v_ref uuid;
begin
  perform pg_temp.sale('S6', 1, 'pay_6');
  perform pg_temp.board('S6');
  select id into v_pay from public.payments where razorpay_payment_id = 'pay_6';
  insert into public.refunds (payment_id, amount_cents, reason, status) values (v_pay, 1000, 'goodwill', 'requested') returning id into v_ref;
  e := pg_temp.earn('S6');
  if e.status <> 'on_hold' or e.hold_reason <> 'refund_pending' then raise exception 'FAIL 6a: %', e; end if;
  if e.eligible_journal_id is null then raise exception 'FAIL 6b: a hold must not undo the eligibility journal'; end if;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_reject_refund(v_ref, 'not warranted');
  perform pg_temp.as_server();
  e := pg_temp.earn('S6');
  if e.status <> 'eligible' or e.hold_reason is not null then raise exception 'FAIL 6c: rejection did not release the hold: %', e; end if;
  if (select count(*) from public.ledger_journals where event_type = 'earning_eligible') <> 1 then raise exception 'FAIL 6d: hold/release re-posted event 2'; end if;
end $$;

-- ---- 7. settled / in-batch earnings ----------------------------------------------------------
select pg_temp.reset_all();
do $$
declare e public.operator_earnings; v_booking uuid; rec public.operator_recovery;
begin
  perform pg_temp.sale('S7', 1, 'pay_7');
  perform pg_temp.board('S7');
  select orderable_id into v_booking from public.orders where id = (select id from t_ref where tag = 'S7');

  -- in a batch: neither a boarding correction nor a cancellation may silently change it
  update public.operator_earnings set status = 'in_batch' where booking_item_id = pg_temp.item_of('S7');
  begin perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.cancel_booking(v_booking, 'x'); raise exception 'FAIL 7a: cancelled an item in a batch';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'earning_in_settlement_batch%' then raise exception 'FAIL 7a2: wrong error %', sqlerrm; end if; end;
  perform pg_temp.as_server();
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.correct_boarding(pg_temp.item_of('S7'), 'x'); raise exception 'FAIL 7b: corrected a batched boarding';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'earning_already_batched%' then raise exception 'FAIL 7b2: wrong error %', sqlerrm; end if; end;
  perform pg_temp.as_server();

  -- settled (paid out) then cancelled by an admin: clawback + recovery, not a silent negative balance
  update public.operator_earnings set status = 'settled' where booking_item_id = pg_temp.item_of('S7');
  -- the payout (Gate E) debits operator_payable; mimic it so the ledger shows the real position
  perform private.post_journal('test:payout', 'settlement_paid', jsonb_build_array(
    jsonb_build_object('account', 'operator_payable', 'side', 'debit', 'amount_cents', 45000, 'operator_id', (select id from t_ops where tag = 'A')),
    jsonb_build_object('account', 'settlement_bank', 'side', 'credit', 'amount_cents', 45000)));
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.cancel_booking(v_booking, 'refund after settlement');
  perform pg_temp.as_server();
  e := pg_temp.earn('S7');
  if e.status <> 'clawed_back' then raise exception 'FAIL 7c: %', e; end if;
  select * into rec from public.operator_recovery where earning_id = e.id;
  if rec.amount_cents <> 45000 or rec.status <> 'open' or rec.operator_id <> (select id from t_ops where tag = 'A') then raise exception 'FAIL 7d: recovery %', rec; end if;
  if pg_temp.bal('operator_receivable') <> 45000 then raise exception 'FAIL 7e: receivable not booked'; end if;
  if pg_temp.bal('operator_payable') <> 0 then raise exception 'FAIL 7f: payable must be exactly zero, not negative (%)', pg_temp.bal('operator_payable'); end if;
  if pg_temp.bal('booking_liability') <> 50000 then raise exception 'FAIL 7g: liability should be restored for the refund (got %)', pg_temp.bal('booking_liability'); end if;
  if not exists (select 1 from public.audit_logs where action = 'earning.clawback' and entity_id = e.id) then raise exception 'FAIL 7h: clawback not audited'; end if;
end $$;

-- ---- 8. commission administration ---------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); v_id uuid; v_old uuid;
begin
  delete from public.operator_commission_config;
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_set_commission(v_a, 500);
    raise exception 'FAIL 8a: operator set its own commission';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_set_commission(v_a, 500);
    raise exception 'FAIL 8b: platform_support changed commission';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  begin perform public.admin_set_commission(v_a, 10001); raise exception 'FAIL 8c: rate above 100 percent accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  v_old := public.admin_set_commission(v_a, 1000, current_date - 10);
  v_id := public.admin_set_commission(v_a, 1500, current_date);
  perform pg_temp.as_server();
  if (select effective_to from public.operator_commission_config where id = v_old) <> current_date - 1 then raise exception 'FAIL 8d: earlier rate not closed the day before'; end if;
  if private.commission_rate_bps(v_a, current_date - 5) <> 1000 or private.commission_rate_bps(v_a, current_date) <> 1500 then raise exception 'FAIL 8e: windowed lookup wrong'; end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_deactivate_commission(v_id);
  perform pg_temp.as_server();
  if private.commission_rate_bps(v_a, current_date) is not null then raise exception 'FAIL 8f: deactivated rate still applies (the closed window must not leak)'; end if;
  if not exists (select 1 from public.audit_logs where action = 'commission.deactivate') or not exists (select 1 from public.audit_logs where action = 'commission.set') then
    raise exception 'FAIL 8g: commission changes not audited';
  end if;
end $$;

-- ---- 9. breakdown reconciles with trip_financials; RLS ------------------------------------------------
select pg_temp.reset_all();
select pg_temp.set_rate(1000);
do $$
declare b jsonb; f jsonb; v_trip uuid := (select id from t_ref where tag = 'TRIP'); v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.sale('S9A', 1, 'pay_9a');
  perform pg_temp.sale('S9B', 2, 'pay_9b');
  perform pg_temp.sale('S9C', 3, 'pay_9c');
  perform pg_temp.board('S9A');
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.cancel_booking((select orderable_id from public.orders where id = (select id from t_ref where tag = 'S9C')), 'cancel');
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  b := public.get_operator_earnings_breakdown(v_a);
  f := public.get_trip_financials(v_trip);
  if (b ->> 'gross_cents')::bigint <> (f ->> 'gross_cents')::bigint then raise exception 'FAIL 9a: gross % vs trip_financials %', b ->> 'gross_cents', f ->> 'gross_cents'; end if;
  if (b ->> 'commission_cents')::bigint <> (f ->> 'commission_cents')::bigint then raise exception 'FAIL 9b: commission % vs %', b ->> 'commission_cents', f ->> 'commission_cents'; end if;
  if (b ->> 'net_cents')::bigint <> (f ->> 'net_payable_cents')::bigint then raise exception 'FAIL 9c: net % vs %', b ->> 'net_cents', f ->> 'net_payable_cents'; end if;
  if (b ->> 'eligible_cents')::bigint <> 45000 or (b ->> 'pending_boarding_cents')::bigint <> 45000 then raise exception 'FAIL 9d: eligible/pending split %', b; end if;
  if (b ->> 'refund_adjustment_cents')::bigint <> 45000 then raise exception 'FAIL 9e: refund adjustment %', b; end if;
  if (b ->> 'tickets')::int <> 2 then raise exception 'FAIL 9f: tickets %', b; end if;

  -- isolation
  begin perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b'); perform public.get_operator_earnings_breakdown(v_a);
    raise exception 'FAIL 9g: operator B read operator A earnings';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  if exists (select 1 from public.operator_earnings) or exists (select 1 from public.operator_recovery) then raise exception 'FAIL 9h: operator B sees rows'; end if;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  if exists (select 1 from public.operator_earnings) then raise exception 'FAIL 9i: customer sees earnings'; end if;
  begin insert into public.operator_earnings (booking_item_id, booking_id, trip_id, operator_id, gross_cents)
    select id, booking_id, trip_id, (select id from t_ops where tag = 'A'), 1 from public.booking_items limit 1;
    raise exception 'FAIL 9j: customer inserted an earning';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if (select count(*) from public.operator_earnings) <> 3 then raise exception 'FAIL 9k: operator A should see its 3 earnings'; end if;
  begin update public.operator_earnings set status = 'settled'; raise exception 'FAIL 9l: operator marked an earning settled';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();
end $$;

rollback;
