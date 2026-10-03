-- =========================================================================
-- Checks for Gate D (20261003000700_gated_settlement_engine.sql)
--   * weekly build: eligible earnings only, idempotent per operator+period, drafts only
--   * exclusions: unboarded, held (admin / refund), suspended operator, unresolved failed batch
--   * approval: full admin inside the RPC, verified payout profile, bank details unchanged, refunds re-checked,
--     beneficiary frozen at approval
--   * hold / release / cancel (releases earnings, adjustments and recovery reservations); exported batches are final
--   * operator adjustments credited, recoveries netted under the cap and never below zero
--   * settings validation + authorization, scheduler idempotency, operator visibility, legacy RPCs
-- Concurrency (two sessions) cannot be exercised in PGlite: the advisory lock + SKIP LOCKED are reviewed, and
-- double-build is covered by the unique period index and the `exists` path.
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

insert into auth.users (id, email) values ('77777777-0000-0000-0000-000000000007', 'support@test.invalid');
insert into public.user_roles (user_id, role) values ('77777777-0000-0000-0000-000000000007', 'platform_support');
insert into public.refund_policies (name, category, status, refund_bps, deduction_operator_share_bps, effective_from)
values ('test default', 'default', 'active', 8000, 2500, current_date - 1);
insert into public.operator_bank_details (operator_id, account_holder_name, bank_name, account_number, ifsc)
values ((select id from t_ops where tag = 'A'), 'Operator A', 'SBI', '123456789012', 'SBIN0001234')
on conflict (operator_id) do update set account_holder_name = excluded.account_holder_name, account_number = excluded.account_number, ifsc = excluded.ifsc;

create function pg_temp.reset_all() returns void language plpgsql as $f$
begin
  perform pg_temp.as_server();
  set constraints all immediate;
  alter table public.ledger_journals disable trigger ledger_journals_immutable;
  alter table public.ledger_entries disable trigger ledger_entries_immutable;
  delete from public.settlement_items;
  delete from public.operator_adjustments;
  delete from public.operator_recovery;
  delete from public.operator_earnings;
  delete from public.settlements;
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

create function pg_temp.item_of(p_tag text) returns uuid language sql security definer as $f$
  select bi.id from public.booking_items bi join public.orders o on o.orderable_id = bi.booking_id
   where o.id = (select id from t_ref where tag = p_tag) limit 1
$f$;
create function pg_temp.booking_of(p_tag text) returns uuid language sql security definer as $f$
  select orderable_id from public.orders where id = (select id from t_ref where tag = p_tag)
$f$;
create function pg_temp.earn(p_tag text) returns public.operator_earnings language sql security definer as $f$
  select e from public.operator_earnings e where e.booking_item_id = pg_temp.item_of(p_tag)
$f$;
create function pg_temp.refund_of(p_tag text) returns public.refunds language sql security definer as $f$
  select r from public.refunds r join public.payments p on p.id = r.payment_id
   where p.order_id = (select id from t_ref where tag = p_tag) order by r.created_at desc limit 1
$f$;
create function pg_temp.sale(p_tag text, p_seat int, p_pay text) returns void language plpgsql as $f$
declare o public.orders;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', p_tag, p_seat);
  perform pg_temp.as_server();
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, p_pay, o.amount_cents, 'INR');
end $f$;
create function pg_temp.board(p_tag text) returns void language plpgsql as $f$
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.verify_passenger_boarding(pg_temp.item_of(p_tag), true);
  perform public.confirm_boarding(pg_temp.item_of(p_tag));
  perform pg_temp.as_server();
end $f$;
create function pg_temp.as_admin() returns void language sql as $f$ select pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f') $f$;
create function pg_temp.build(p_end_offset int default 1, p_op uuid default null) returns jsonb language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.as_admin();
  r := public.admin_build_weekly_settlement(current_date + p_end_offset, p_op);
  perform pg_temp.as_server();
  return r;
end $f$;
create function pg_temp.batch_of(p_op text) returns uuid language sql security definer as $f$
  select id from public.settlements where operator_id = (select id from t_ops where tag = p_op) and status <> 'cancelled' order by period_end desc, generated_at desc limit 1
$f$;

select pg_temp.as_admin();
select public.admin_set_commission((select id from t_ops where tag = 'A'), 1000);
select pg_temp.as_server();

-- ---- 1. build: eligible earnings only, idempotent ---------------------------------------------------------
do $$
declare r jsonb; s public.settlements; v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.sale('S1', 1, 'pay_1');
  perform pg_temp.sale('S2', 2, 'pay_2');
  perform pg_temp.sale('S3', 3, 'pay_3');
  perform pg_temp.board('S1');
  perform pg_temp.board('S2');

  r := pg_temp.build();
  if (r ->> 'built')::int <> 1 then raise exception 'FAIL 1a: %', r; end if;
  select * into s from public.settlements where operator_id = v_a;
  if s.status <> 'draft' or s.gross_cents <> 100000 or s.commission_cents <> 10000 or s.net_payable_cents <> 90000
     or s.other_deductions_cents <> 0 or s.generated_at is null or s.approved_at is not null or s.exported_at is not null or s.bank_paid_at is not null then
    raise exception 'FAIL 1b: batch %', s;
  end if;
  if (select count(*) from public.settlement_items where settlement_id = s.id and kind = 'sale') <> 2 then raise exception 'FAIL 1c: items'; end if;
  if (pg_temp.earn('S1')).status <> 'in_batch' or (pg_temp.earn('S1')).settlement_id <> s.id or (pg_temp.earn('S2')).status <> 'in_batch' then raise exception 'FAIL 1d: earnings not committed'; end if;
  if (pg_temp.earn('S3')).status <> 'pending_boarding' then raise exception 'FAIL 1e: an unboarded ticket was settled'; end if;

  r := pg_temp.build();                                   -- same period again: nothing new
  if (r ->> 'built')::int <> 0 or (select count(*) from public.settlements where operator_id = v_a) <> 1 then raise exception 'FAIL 1f: rebuild created a second batch: %', r; end if;
  begin insert into public.settlements (reference, operator_id, period_start, period_end, status) select 'ST-DUP', operator_id, period_start, period_end, 'draft' from public.settlements limit 1;
    raise exception 'FAIL 1g: duplicate period accepted';
  exception when unique_violation then null; end;

  -- only full admins build; the build never touches the ledger
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_build_weekly_settlement(current_date + 1); raise exception 'FAIL 1h: support built settlements';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_build_weekly_settlement(current_date + 1); raise exception 'FAIL 1i: operator built settlements';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();
  if exists (select 1 from public.ledger_journals where event_type like 'settlement%') then raise exception 'FAIL 1j: building posted to the ledger'; end if;
  if not exists (select 1 from public.audit_logs where action = 'settlement.build' and entity_id = s.id) then raise exception 'FAIL 1k: build not audited'; end if;
end $$;

-- ---- 2. exclusions -----------------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare r jsonb; v_a uuid := (select id from t_ops where tag = 'A'); v_set uuid; v_ref uuid;
begin
  perform pg_temp.sale('S4', 1, 'pay_4');   -- admin hold
  perform pg_temp.sale('S5', 2, 'pay_5');   -- refund pending
  perform pg_temp.sale('S6', 3, 'pay_6');   -- clean
  perform pg_temp.board('S4'); perform pg_temp.board('S5'); perform pg_temp.board('S6');

  perform pg_temp.as_admin();
  perform public.admin_hold_earning((pg_temp.earn('S4')).id, true, 'under review');
  perform pg_temp.as_server();
  insert into public.refunds (payment_id, amount_cents, reason, status)
    select p.id, 1000, 'dispute', 'requested' from public.payments p where p.razorpay_payment_id = 'pay_5';
  if (pg_temp.earn('S5')).status <> 'on_hold' or (pg_temp.earn('S4')).hold_reason <> 'admin_hold' then raise exception 'FAIL 2a: holds not applied'; end if;

  r := pg_temp.build();
  select id into v_set from public.settlements where operator_id = v_a;
  if (select count(*) from public.settlement_items where settlement_id = v_set and kind = 'sale') <> 1 or (pg_temp.earn('S6')).status <> 'in_batch'
     or (pg_temp.earn('S4')).status <> 'on_hold' or (pg_temp.earn('S5')).status <> 'on_hold' then raise exception 'FAIL 2b: held earnings must stay out of the batch'; end if;

  -- admin hold: only an administrator lifts it
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_hold_earning((pg_temp.earn('S4')).id, false); raise exception 'FAIL 2c: operator lifted an admin hold';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_admin();
  begin perform public.admin_hold_earning((pg_temp.earn('S6')).id, true, ''); raise exception 'FAIL 2d: hold without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.admin_hold_earning((pg_temp.earn('S4')).id, false);
  perform pg_temp.as_server();
  if (pg_temp.earn('S4')).status <> 'eligible' then raise exception 'FAIL 2e: released earning should be eligible again: %', (pg_temp.earn('S4')).status; end if;

  -- suspended operator is skipped
  update public.operators set status = 'suspended' where id = v_a;
  r := pg_temp.build(2);
  if (r ->> 'built')::int <> 0 or r -> 'operators' -> 0 ->> 'reason' <> 'operator_not_active' then raise exception 'FAIL 2f: %', r; end if;
  update public.operators set status = 'approved' where id = v_a;

  -- a later build now picks up the released earning
  r := pg_temp.build(2);
  if (r ->> 'built')::int <> 1 then raise exception 'FAIL 2g: %', r; end if;
  if (pg_temp.earn('S4')).status <> 'in_batch' then raise exception 'FAIL 2h'; end if;
end $$;

-- ---- 3. approval ---------------------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); v_set uuid; b jsonb; v_set2 uuid;
begin
  perform pg_temp.sale('S7', 1, 'pay_7');
  perform pg_temp.board('S7');
  perform pg_temp.build();
  v_set := pg_temp.batch_of('A');

  -- who may approve
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3a: operator approved';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3b: support approved';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3c: customer approved';
  exception when insufficient_privilege then null; end;

  -- no verified payout profile
  begin perform pg_temp.as_admin(); perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3d: approved without a payout profile';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'payment_profile_missing%' then raise exception 'FAIL 3d2: %', sqlerrm; end if; end;
  perform pg_temp.as_admin();
  begin perform public.admin_set_payment_profile_status(v_a, 'failed', ''); raise exception 'FAIL 3e: failed without a note';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.admin_set_payment_profile_status(v_a, 'failed', 'name does not match the account');
  begin perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3f: approved with a failed profile';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'payment_profile_not_verified%' then raise exception 'FAIL 3f2: %', sqlerrm; end if; end;
  perform public.admin_set_payment_profile_status(v_a, 'verified', null);
  perform public.admin_set_payout_hold(v_a, true, 'investigation');
  begin perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3g: approved while payouts are held';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'payout_on_hold%' then raise exception 'FAIL 3g2: %', sqlerrm; end if; end;
  perform public.admin_set_payout_hold(v_a, false);

  b := public.admin_approve_settlement(v_set);
  perform pg_temp.as_server();
  if (select status from public.settlements where id = v_set) <> 'approved' or (select approved_by from public.settlements where id = v_set) is null
     or (select approved_at from public.settlements where id = v_set) is null then raise exception 'FAIL 3h: %', b; end if;
  if not exists (select 1 from public.audit_logs where action = 'settlement.approve' and entity_id = v_set) then raise exception 'FAIL 3i: approval not audited'; end if;
  begin perform pg_temp.as_admin(); perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3j: approved twice';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();

  -- the beneficiary is frozen; later bank changes do not touch the approved batch
  update public.operator_bank_details set account_number = '999988887777' where operator_id = v_a;
  perform pg_temp.as_admin();
  b := public.admin_get_settlement_beneficiary(v_set);
  perform pg_temp.as_server();
  if b ->> 'account_masked' <> 'XXXXXXXX7777' and b ->> 'account_masked' <> 'XXXXXXXX9012' then raise exception 'FAIL 3k: %', b; end if;
  if b ->> 'account_masked' <> 'XXXXXXXX9012' then raise exception 'FAIL 3l: the frozen beneficiary changed with the bank details: %', b; end if;
  if (select account_number from public.settlement_beneficiaries where settlement_id = v_set) <> '123456789012' then raise exception 'FAIL 3m'; end if;
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform 1 from public.settlement_beneficiaries; raise exception 'FAIL 3n: operator read the beneficiary table';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  -- a NEW batch cannot be approved until the changed details are verified again
  perform pg_temp.sale('S8', 2, 'pay_8');
  perform pg_temp.board('S8');
  perform pg_temp.build(2);
  v_set2 := pg_temp.batch_of('A');
  if v_set2 = v_set then raise exception 'FAIL 3o: second batch not created'; end if;
  begin perform pg_temp.as_admin(); perform public.admin_approve_settlement(v_set2); raise exception 'FAIL 3p: approved after a bank change';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'bank_details_changed_reverify%' then raise exception 'FAIL 3p2: %', sqlerrm; end if; end;
  perform pg_temp.as_admin();
  perform public.admin_set_payment_profile_status(v_a, 'verified', null);
  perform public.admin_approve_settlement(v_set2);
  perform pg_temp.as_server();
  if (select account_number from public.settlement_beneficiaries where settlement_id = v_set2) <> '999988887777' then raise exception 'FAIL 3q: new batch must freeze the new details'; end if;
end $$;

-- ---- 3b. a refund raised while the batch waits blocks approval -----------------------------------------------------
select pg_temp.reset_all();
update public.operator_bank_details set account_number = '123456789012' where operator_id = (select id from t_ops where tag = 'A');
select pg_temp.as_admin();
select public.admin_set_payment_profile_status((select id from t_ops where tag = 'A'), 'verified', null);
select pg_temp.as_server();
do $$
declare v_set uuid; v_ref uuid;
begin
  perform pg_temp.sale('S9', 1, 'pay_9');
  perform pg_temp.board('S9');
  perform pg_temp.build();
  v_set := pg_temp.batch_of('A');
  insert into public.refunds (payment_id, amount_cents, reason, status)
    select p.id, 1000, 'late dispute', 'requested' from public.payments p where p.razorpay_payment_id = 'pay_9' returning id into v_ref;
  begin perform pg_temp.as_admin(); perform public.admin_approve_settlement(v_set); raise exception 'FAIL 3r: approved a batch with an unresolved refund';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'refund_pending_in_batch%' then raise exception 'FAIL 3r2: %', sqlerrm; end if; end;
  perform pg_temp.as_admin();
  perform public.admin_reject_refund(v_ref, 'not warranted');
  perform public.admin_approve_settlement(v_set);
  perform pg_temp.as_server();
  if (select status from public.settlements where id = v_set) <> 'approved' then raise exception 'FAIL 3s'; end if;
end $$;

-- ---- 4. hold, release, cancel --------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare v_set uuid; v_set2 uuid; v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.sale('S10', 1, 'pay_10');
  perform pg_temp.board('S10');
  perform pg_temp.build();
  v_set := pg_temp.batch_of('A');

  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_hold_settlement(v_set, 'x'); raise exception 'FAIL 4a: operator held a settlement';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_admin(); perform public.admin_hold_settlement(v_set, ' '); raise exception 'FAIL 4b: hold without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_admin();
  perform public.admin_hold_settlement(v_set, 'checking operator documents');
  begin perform public.admin_approve_settlement(v_set); raise exception 'FAIL 4c: approved while on hold';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.admin_release_settlement_hold(v_set);
  perform pg_temp.as_server();
  if (select status from public.settlements where id = v_set) <> 'draft' then raise exception 'FAIL 4d: release should return to draft'; end if;

  -- cancel: everything returns to the pool; the same period can be rebuilt
  perform pg_temp.as_admin();
  begin perform public.admin_cancel_settlement(v_set, ''); raise exception 'FAIL 4e: cancel without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.admin_cancel_settlement(v_set, 'wrong period');
  perform pg_temp.as_server();
  if (select status from public.settlements where id = v_set) <> 'cancelled' or (pg_temp.earn('S10')).status <> 'eligible' or (pg_temp.earn('S10')).settlement_id is not null
     or exists (select 1 from public.settlement_items where settlement_id = v_set) then raise exception 'FAIL 4f: cancel did not release the earning'; end if;
  if not exists (select 1 from public.audit_logs where action = 'settlement.cancel' and entity_id = v_set and jsonb_array_length(after -> 'items') = 1) then raise exception 'FAIL 4g: cancel must keep the item list in the audit log'; end if;
  perform pg_temp.build();
  v_set2 := pg_temp.batch_of('A');
  if v_set2 = v_set or (pg_temp.earn('S10')).status <> 'in_batch' then raise exception 'FAIL 4h: rebuild after cancel'; end if;

  -- an exported batch is final here
  update public.settlements set status = 'exported' where id = v_set2;
  begin perform pg_temp.as_admin(); perform public.admin_cancel_settlement(v_set2, 'oops'); raise exception 'FAIL 4i: cancelled an exported batch';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'settlement_not_cancellable%' then raise exception 'FAIL 4i2: %', sqlerrm; end if; end;
  begin perform public.admin_hold_settlement(v_set2, 'oops'); raise exception 'FAIL 4j: held an exported batch';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 5. a failed batch is never merged automatically ------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare v_set uuid; r jsonb;
begin
  perform pg_temp.sale('S11', 1, 'pay_11');
  perform pg_temp.board('S11');
  perform pg_temp.build();
  v_set := pg_temp.batch_of('A');
  update public.settlements set status = 'failed', failure_reason = 'bank rejected' where id = v_set;

  perform pg_temp.sale('S12', 2, 'pay_12');
  perform pg_temp.board('S12');
  r := pg_temp.build(2);
  if (r ->> 'built')::int <> 0 or r -> 'operators' -> 0 ->> 'reason' <> 'prior_failed_batch_unresolved' then raise exception 'FAIL 5a: %', r; end if;
  if (pg_temp.earn('S11')).status <> 'in_batch' then raise exception 'FAIL 5b: failed batch earnings must stay committed until released'; end if;

  perform pg_temp.as_admin();
  perform public.admin_cancel_settlement(v_set, 'released after the bank confirmed nothing was paid');
  perform pg_temp.as_server();
  r := pg_temp.build(2);
  if (r ->> 'built')::int <> 1 then raise exception 'FAIL 5c: %', r; end if;
  if (select count(*) from public.settlement_items where settlement_id = pg_temp.batch_of('A') and kind = 'sale') <> 2 then raise exception 'FAIL 5d: released + new earnings should be in the new batch'; end if;
end $$;

-- ---- 6. adjustments credited, recoveries netted under the cap, never below zero ---------------------------------------------
select pg_temp.reset_all();
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); s public.settlements; v_rec uuid; r jsonb; v_set uuid;
begin
  -- an operator share of a cancellation deduction (2500) from a refunded sale
  perform pg_temp.sale('S13', 1, 'pay_13');
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking(pg_temp.booking_of('S13'), 'plans changed');
  perform pg_temp.as_admin();
  perform public.admin_approve_refund((pg_temp.refund_of('S13')).id);
  perform pg_temp.as_server();
  if (select amount_cents from public.operator_adjustments) <> 2500 then raise exception 'FAIL 6a: adjustment'; end if;

  -- an open recovery (30000) and two paid + boarded sales (net 90000)
  insert into public.operator_recovery (operator_id, earning_id, booking_item_id, amount_cents, reason)
    select v_a, e.id, e.booking_item_id, 30000, 'test recovery' from public.operator_earnings e limit 1 returning id into v_rec;
  perform pg_temp.sale('S14', 2, 'pay_14'); perform pg_temp.sale('S15', 3, 'pay_15');
  perform pg_temp.board('S14'); perform pg_temp.board('S15');

  r := pg_temp.build();
  select * into s from public.settlements where operator_id = v_a;
  if s.gross_cents <> 100000 or s.commission_cents <> 10000 or s.adjustment_credits_cents <> 2500 or s.recovery_netted_cents <> 30000
     or s.net_payable_cents <> 62500 or s.other_deductions_cents <> 27500 then raise exception 'FAIL 6b: %', s; end if;
  if s.net_payable_cents <> s.gross_cents - s.refunds_cents - s.commission_cents - s.other_deductions_cents then raise exception 'FAIL 6c: arithmetic'; end if;
  if (select count(*) from public.settlement_items where settlement_id = s.id) <> 4 then raise exception 'FAIL 6d: items %', (select count(*) from public.settlement_items where settlement_id = s.id); end if;
  if (select status from public.operator_adjustments) <> 'in_batch' or private.recovery_reserved(v_rec) <> 30000 then raise exception 'FAIL 6e: reservations'; end if;

  -- cancelling releases the credit and the recovery reservation
  perform pg_temp.as_admin();
  perform public.admin_cancel_settlement(s.id, 'rebuild with a different cap');
  perform pg_temp.as_server();
  if (select status from public.operator_adjustments) <> 'open' or private.recovery_reserved(v_rec) <> 0 then raise exception 'FAIL 6f: cancel did not release credit/reservation'; end if;

  -- cap 10% of (earnings + credits) = 9250
  perform pg_temp.as_admin();
  perform public.admin_set_platform_setting('settlement_recovery_cap_bps', '1000'::jsonb);
  perform pg_temp.as_server();
  perform pg_temp.build();
  select * into s from public.settlements where operator_id = v_a and status = 'draft';
  if s.recovery_netted_cents <> 9250 or s.net_payable_cents <> 83250 then raise exception 'FAIL 6g: capped netting %', s; end if;
  perform pg_temp.as_admin();
  perform public.admin_cancel_settlement(s.id, 'again');
  perform public.admin_set_platform_setting('settlement_recovery_cap_bps', '10000'::jsonb);
  perform pg_temp.as_server();

  -- a recovery bigger than the payable: the batch bottoms out at zero and the rest carries forward
  update public.operator_recovery set amount_cents = 1000000 where id = v_rec;
  perform pg_temp.build();
  select * into s from public.settlements where operator_id = v_a and status = 'draft';
  if s.net_payable_cents <> 0 or s.recovery_netted_cents <> 92500 then raise exception 'FAIL 6h: net must never go negative: %', s; end if;
  if private.recovery_reserved(v_rec) <> 92500 or (select amount_cents - recovered_cents - private.recovery_reserved(v_rec) from public.operator_recovery where id = v_rec) <> 907500 then raise exception 'FAIL 6i: carry forward'; end if;
end $$;

-- ---- 7. settings ----------------------------------------------------------------------------------------------------------
do $$
begin
  perform pg_temp.as_user('77777777-0000-0000-0000-000000000007');
  begin perform public.admin_set_platform_setting('settlement_run_hour', '9'::jsonb); raise exception 'FAIL 7a: support changed a settlement setting';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.admin_set_platform_setting('settlement_run_hour', '9'::jsonb); raise exception 'FAIL 7b: operator changed a settlement setting';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_admin();
  begin perform public.admin_set_platform_setting('settlement_run_dow', '9'::jsonb); raise exception 'FAIL 7c: day 9 accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_set_platform_setting('settlement_run_hour', '25'::jsonb); raise exception 'FAIL 7d: hour 25 accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_set_platform_setting('settlement_recovery_cap_bps', '20000'::jsonb); raise exception 'FAIL 7e: cap above 100 percent accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_set_platform_setting('settlement_timezone', '"Mars/Phobos"'::jsonb); raise exception 'FAIL 7f: bad time zone accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_set_platform_setting('razorpay_route_enabled', 'true'::jsonb); raise exception 'FAIL 7g: Razorpay Route enabled without configuration';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'provider_not_configured%' then raise exception 'FAIL 7g2: %', sqlerrm; end if; end;
  begin perform public.admin_set_platform_setting('settlement_provider', '"razorpayx"'::jsonb); raise exception 'FAIL 7h: unconfigured provider selected';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.admin_set_platform_setting('settlement_run_hour', '14'::jsonb);
  perform public.admin_set_platform_setting('settlement_run_hour', '12'::jsonb);
  perform pg_temp.as_server();
  if private.cfg_text('settlement_provider', 'x') <> 'manual_sbi' then raise exception 'FAIL 7i: default provider must be manual_sbi'; end if;
end $$;

-- ---- 8. scheduler ------------------------------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare v_tz text := private.cfg_text('settlement_timezone', 'Asia/Kolkata'); v_dow int := extract(isodow from (now() at time zone v_tz))::int;
begin
  perform pg_temp.as_admin();
  perform public.admin_set_platform_setting('settlement_week_start_dow', to_jsonb(v_dow));
  perform public.admin_set_platform_setting('settlement_run_dow', to_jsonb((v_dow % 7) + 1));     -- tomorrow: not due yet
  perform pg_temp.as_server();
  perform private.cron_build_weekly_settlement();
  if exists (select 1 from public.settlement_runs) then raise exception 'FAIL 8a: the scheduler ran before its slot'; end if;

  perform pg_temp.as_admin();
  perform public.admin_set_platform_setting('settlement_run_dow', to_jsonb(v_dow));
  perform public.admin_set_platform_setting('settlement_run_hour', '0'::jsonb);                      -- due since midnight
  perform pg_temp.as_server();
  perform private.cron_build_weekly_settlement();
  perform private.cron_build_weekly_settlement();                                                    -- idempotent
  if (select count(*) from public.settlement_runs) <> 1 or (select status from public.settlement_runs) <> 'completed' then raise exception 'FAIL 8b: scheduler run %', (select count(*) from public.settlement_runs); end if;
  if (select period_end - period_start from public.settlement_runs) <> 6 then raise exception 'FAIL 8c: period is a week'; end if;
  if (select period_end from public.settlement_runs) >= (now() at time zone v_tz)::date then raise exception 'FAIL 8d: the period must be closed'; end if;
  if exists (select 1 from public.settlements where status <> 'draft') then raise exception 'FAIL 8e: the scheduler may only create drafts'; end if;
end $$;

-- ---- 9. visibility for operators -------------------------------------------------------------------------------------------------
select pg_temp.reset_all();
delete from public.operator_payment_profiles;
select pg_temp.as_admin();
select public.admin_set_platform_setting('settlement_week_start_dow', '1'::jsonb);
select public.admin_set_platform_setting('settlement_run_dow', '1'::jsonb);
select public.admin_set_platform_setting('settlement_run_hour', '12'::jsonb);
select pg_temp.as_server();
update public.operator_bank_details set account_number = '123456789012' where operator_id = (select id from t_ops where tag = 'A');
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); p jsonb; v_set uuid;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  p := public.get_my_payment_profile(v_a);
  if p ->> 'verification_status' <> 'unverified' or (p ->> 'settlement_eligible')::boolean or p ->> 'required_action' is null then raise exception 'FAIL 9a: %', p; end if;
  perform pg_temp.as_admin();
  perform public.admin_set_payment_profile_status(v_a, 'verified', null);
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  p := public.get_my_payment_profile(v_a);
  if p ->> 'account_masked' <> 'XXXXXXXX9012' or p ->> 'ifsc_masked' <> 'SBIN*******' or not (p ->> 'settlement_eligible')::boolean or p::text like '%123456789012%' then raise exception 'FAIL 9b: masked profile %', p; end if;
  begin perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b'); perform public.get_my_payment_profile(v_a); raise exception 'FAIL 9c: operator B read operator A profile';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  if exists (select 1 from public.operator_payment_profiles) is false then raise exception 'FAIL 9d'; end if;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  if exists (select 1 from public.operator_payment_profiles) then raise exception 'FAIL 9e: operator B sees payment profiles'; end if;
  perform pg_temp.as_server();

  -- operator_payment_profiles cannot be written by clients
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); update public.operator_payment_profiles set verification_status = 'verified'; raise exception 'FAIL 9f: operator verified itself';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_set_payment_profile_status(v_a, 'verified', null); raise exception 'FAIL 9g: operator verified itself via RPC';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  -- drafts are hidden, approved batches are visible, other operators see nothing
  perform pg_temp.sale('S16', 1, 'pay_16'); perform pg_temp.board('S16');
  perform pg_temp.build();
  v_set := pg_temp.batch_of('A');
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if jsonb_array_length(public.list_operator_settlements(v_a) -> 'settlements') <> 0 then raise exception 'FAIL 9h: draft visible'; end if;
  perform pg_temp.as_admin();
  perform public.admin_approve_settlement(v_set);
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if jsonb_array_length(public.list_operator_settlements(v_a) -> 'settlements') <> 1 then raise exception 'FAIL 9i: approved batch invisible'; end if;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  if exists (select 1 from public.settlements) then raise exception 'FAIL 9j: operator B sees settlements'; end if;
  perform pg_temp.as_server();
end $$;

-- ---- 10. legacy RPCs ----------------------------------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare d jsonb; v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.sale('S17', 1, 'pay_17'); perform pg_temp.board('S17');
  perform pg_temp.as_admin();
  d := public.admin_create_settlement(v_a, current_date - 6, current_date + 1);
  if d ->> 'status' <> 'draft' or (d ->> 'net_payable_cents')::bigint <> 45000 then raise exception 'FAIL 10a: legacy create must use the engine: %', d; end if;
  begin perform public.admin_update_settlement((d ->> 'id')::uuid, 'paid', 45000, 'bank', 'TX'); raise exception 'FAIL 10b: manual paid accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'manual_status_updates_disabled%' then raise exception 'FAIL 10b2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();
  if exists (select 1 from public.ledger_journals where event_type like 'settlement%') then raise exception 'FAIL 10c'; end if;
end $$;

rollback;
