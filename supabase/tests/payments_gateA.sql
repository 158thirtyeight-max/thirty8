-- =========================================================================
-- Checks for Gate A (payment integrity): 20261003000200 + 20261003000300
--   * captured amount AND currency are validated; replays are idempotent
--   * a duplicate real capture is recorded + queued for refund, never ignored
--   * a failed attempt does not kill the order or free the seats (retry works)
--   * captured-without-confirmed-booking is detected, never auto-corrected
--   * refund lifecycle: requested -> approved -> submitted_to_provider -> processed | failed
--       - cancellation only REQUESTS; operators/customers/support cannot approve
--       - execution is serialised; acceptance by the provider is not completion
--       - over-refund and double refund are blocked; partial refund keeps payment captured
--       - failed refund retry is safe; unknown provider refund events are queued
--   * webhook registry: claim / duplicate / in-progress / retry
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

-- a default refund policy so approvals can calculate (policies are admin data; none is seeded)
insert into public.refund_policies (name, category, status, refund_bps, deduction_operator_share_bps, effective_from)
values ('test default', 'default', 'active', 10000, 0, current_date - 1);

insert into auth.users (id, email) values ('77777777-0000-0000-0000-000000000007', 'support@test.invalid');
insert into public.user_roles (user_id, role) values ('77777777-0000-0000-0000-000000000007', 'platform_support');

create function pg_temp.reset_all() returns void language plpgsql as $f$
begin
  perform pg_temp.as_server();
  delete from public.reconciliation_exceptions;
  delete from public.refunds;
  delete from public.payments;
  delete from public.orders;
  delete from public.booking_items;
  delete from public.passengers;
  delete from public.booking_status_history;
  delete from public.bookings;
  update public.trip_seats set status = 'available', hold_id = null;
  delete from public.seat_holds;
end $f$;

create function pg_temp.order_of(p_tag text) returns public.orders language sql as $f$
  select o from public.orders o where o.id = (select id from t_ref where tag = p_tag)
$f$;

-- ---- 1. amount + currency validation, idempotent replay ------------------
do $$
declare o public.orders; r jsonb;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O1', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O1');

  r := public.confirm_booking_after_payment(o.order_reference, 'pay_cur', o.amount_cents, 'USD');
  if r ->> 'status' <> 'refund_pending' or r ->> 'reason' not like 'currency_mismatch%' then
    raise exception 'FAIL 1a: wrong currency not refused: %', r;
  end if;
  if (select status from public.bookings where id = o.orderable_id) <> 'payment_pending' then
    raise exception 'FAIL 1b: booking changed on wrong currency';
  end if;
  if not exists (select 1 from public.refunds rf join public.payments p on p.id = rf.payment_id
                  where p.razorpay_payment_id = 'pay_cur' and rf.status = 'requested' and rf.amount_cents = o.amount_cents) then
    raise exception 'FAIL 1c: refund REQUEST not created (must be requested, not executed)';
  end if;
  if not exists (select 1 from public.reconciliation_exceptions where kind = 'captured_not_applied' and entity_id = 'pay_cur' and status = 'open') then
    raise exception 'FAIL 1d: unapplied capture not queued as an exception';
  end if;
end $$;

select pg_temp.reset_all();
do $$
declare o public.orders; r jsonb;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O1', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O1');
  r := public.confirm_booking_after_payment(o.order_reference, 'pay_ok', o.amount_cents, 'INR', 'upi');
  if r ->> 'status' <> 'confirmed' then raise exception 'FAIL 1e: expected confirmed, got %', r; end if;
  if (select method from public.payments where razorpay_payment_id = 'pay_ok') <> 'upi' then raise exception 'FAIL 1f: method not stored'; end if;
  r := public.confirm_booking_after_payment(o.order_reference, 'pay_ok', o.amount_cents, 'INR', 'upi');
  if not coalesce((r ->> 'already_processed')::boolean, false) then raise exception 'FAIL 1g: replay not idempotent: %', r; end if;
  if (select count(*) from public.payments where order_id = o.id) <> 1 then raise exception 'FAIL 1h: duplicate payment row on replay'; end if;
  if exists (select 1 from public.refunds) then raise exception 'FAIL 1i: refund created on the happy path'; end if;
end $$;

-- ---- 2. duplicate real capture -------------------------------------------
-- (continues from the confirmed order above)
do $$
declare o public.orders; r jsonb;
begin
  o := pg_temp.order_of('O1');
  r := public.confirm_booking_after_payment(o.order_reference, 'pay_second', o.amount_cents, 'INR');
  if r ->> 'status' <> 'duplicate_refund_pending' then raise exception 'FAIL 2a: duplicate capture ignored: %', r; end if;
  if (select status from public.payments where razorpay_payment_id = 'pay_second') <> 'duplicate_captured' then
    raise exception 'FAIL 2b: duplicate payment not recorded as duplicate_captured';
  end if;
  if not exists (select 1 from public.refunds rf join public.payments p on p.id = rf.payment_id
                  where p.razorpay_payment_id = 'pay_second' and rf.status = 'requested') then
    raise exception 'FAIL 2c: refund request for the duplicate not created';
  end if;
  if not exists (select 1 from public.reconciliation_exceptions where kind = 'duplicate_capture' and entity_id = 'pay_second') then
    raise exception 'FAIL 2d: duplicate capture not queued';
  end if;
  if (select status from public.bookings where id = o.orderable_id) <> 'confirmed' then raise exception 'FAIL 2e: booking disturbed'; end if;
  -- replay of the duplicate is a no-op
  r := public.confirm_booking_after_payment(o.order_reference, 'pay_second', o.amount_cents, 'INR');
  if not coalesce((r ->> 'already_processed')::boolean, false) then raise exception 'FAIL 2f: duplicate replay not idempotent'; end if;
  if (select count(*) from public.refunds) <> 1 then raise exception 'FAIL 2g: duplicate replay created another refund'; end if;
end $$;

-- ---- 3. failed attempt is retryable ---------------------------------------
select pg_temp.reset_all();
do $$
declare o public.orders; r jsonb;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O3', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O3');

  perform public.handle_payment_failure(o.order_reference, 'pay_f1', 'card declined');
  perform public.handle_payment_failure(o.order_reference, 'pay_f1', 'card declined');   -- replay
  if (select status from public.orders where id = o.id) <> 'created' then raise exception 'FAIL 3a: first failed attempt closed the order'; end if;
  if (select status from public.bookings where id = o.orderable_id) <> 'payment_pending' then raise exception 'FAIL 3b: booking failed on first attempt'; end if;
  if not exists (select 1 from public.trip_seats ts join public.booking_items bi on bi.trip_seat_id = ts.id
                  where bi.booking_id = o.orderable_id and ts.status = 'held') then
    raise exception 'FAIL 3c: seat freed on the first failed attempt';
  end if;
  if (select count(*) from public.payments where razorpay_payment_id = 'pay_f1' and status = 'failed' and failure_reason = 'card declined') <> 1 then
    raise exception 'FAIL 3d: failed attempt not recorded exactly once';
  end if;

  -- the customer retries on the same order and succeeds
  r := public.confirm_booking_after_payment(o.order_reference, 'pay_f2', o.amount_cents, 'INR');
  if r ->> 'status' <> 'confirmed' then raise exception 'FAIL 3e: retry after a failed attempt not confirmed: %', r; end if;
  -- a stale failure arriving later changes nothing
  perform public.handle_payment_failure(o.order_reference, 'pay_f3', 'late');
  if (select status from public.bookings where id = o.orderable_id) <> 'confirmed' then raise exception 'FAIL 3f: stale failure undid a paid booking'; end if;
end $$;

-- ---- 4. captured but booking never confirmed: detected, not auto-corrected -
select pg_temp.reset_all();
do $$
declare o public.orders; n int;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O4', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O4');
  -- a capture that somehow has no confirmed booking and no refund (e.g. a half-applied manual fix)
  insert into public.payments (order_id, razorpay_payment_id, amount_cents, status, captured_at)
  values (o.id, 'pay_orphan', o.amount_cents, 'captured', now() - interval '30 minutes');
  n := private.detect_captured_unconfirmed();
  if n <> 1 then raise exception 'FAIL 4a: detector found % orphan(s), expected 1', n; end if;
  if (select status from public.bookings where id = o.orderable_id) <> 'payment_pending' then
    raise exception 'FAIL 4b: detector changed the booking (must never auto-correct)';
  end if;
  perform private.detect_captured_unconfirmed();
  if (select count(*) from public.reconciliation_exceptions where kind = 'captured_without_confirmed_booking') <> 1 then
    raise exception 'FAIL 4c: detector is not idempotent';
  end if;
end $$;

-- ---- 5. refund lifecycle ---------------------------------------------------
select pg_temp.reset_all();
do $$
declare
  o public.orders; v_booking uuid; v_refund uuid; v_pay uuid; j jsonb; r text; v_amt int;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O5', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O5');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_r1', o.amount_cents, 'INR');
  v_booking := o.orderable_id;
  v_amt := o.amount_cents;

  -- customer cancels: this only REQUESTS a refund
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking(v_booking, 'plans changed');
  perform pg_temp.as_server();
  select id into v_refund from public.refunds;
  if (select status from public.refunds where id = v_refund) <> 'requested' then raise exception 'FAIL 5a: cancel did not create a requested refund'; end if;
  if (select requested_by from public.refunds where id = v_refund) <> 'dddddddd-0000-0000-0000-00000000000d' then raise exception 'FAIL 5a2: requester not recorded'; end if;
  if (select status from public.payments where razorpay_payment_id = 'pay_r1') <> 'captured' then raise exception 'FAIL 5b: payment changed by a mere request'; end if;

  -- nobody except a full admin may approve
  begin perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.admin_approve_refund(v_refund); raise exception 'FAIL 5c: customer approved a refund';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_approve_refund(v_refund); raise exception 'FAIL 5d: operator approved a refund';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_approve_refund(v_refund); raise exception 'FAIL 5e: platform_support approved a refund';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  -- execution before approval is refused
  begin perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f'); perform public.admin_begin_refund_execution(v_refund); raise exception 'FAIL 5f: unapproved refund executed';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();

  -- rejection needs a reason
  begin perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f'); perform public.admin_reject_refund(v_refund, '  '); raise exception 'FAIL 5g: rejected without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_approve_refund(v_refund);
  perform pg_temp.as_server();
  if (select status from public.refunds where id = v_refund) <> 'approved' then raise exception 'FAIL 5h: not approved'; end if;
  if not exists (select 1 from public.audit_logs where action = 'refund.approve' and entity_id = v_refund) then raise exception 'FAIL 5i: approval not audited'; end if;

  -- execute: serialised
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  j := public.admin_begin_refund_execution(v_refund);
  if (j ->> 'amount_cents')::int <> v_amt or j ->> 'razorpay_payment_id' <> 'pay_r1' then raise exception 'FAIL 5j: execution payload %', j; end if;
  begin perform public.admin_begin_refund_execution(v_refund); raise exception 'FAIL 5k: refund executed twice';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();

  -- provider ACCEPTED it but has not processed it: still not completed
  r := public.record_refund_provider_result(v_refund, 'rfnd_1', 'pending');
  if r <> 'submitted_to_provider' or (select status from public.payments where razorpay_payment_id = 'pay_r1') <> 'captured' then
    raise exception 'FAIL 5l: acceptance treated as completion (%)', r;
  end if;

  -- provider-confirmed (webhook) completes it, exactly once
  perform public.confirm_refund('rfnd_1', 'pay_r1', v_refund);
  perform public.confirm_refund('rfnd_1', 'pay_r1', v_refund);
  if (select status from public.refunds where id = v_refund) <> 'processed' then raise exception 'FAIL 5m: not processed'; end if;
  if (select refunded_cents from public.payments where razorpay_payment_id = 'pay_r1') <> v_amt then raise exception 'FAIL 5n: refunded_cents wrong or double counted'; end if;
  if (select status from public.payments where razorpay_payment_id = 'pay_r1') <> 'refunded' or (select status from public.orders where id = o.id) <> 'refunded' then
    raise exception 'FAIL 5o: full refund not reflected on payment/order';
  end if;

  -- cannot refund the same payment again
  begin
    select id into v_pay from public.payments where razorpay_payment_id = 'pay_r1';
    insert into public.refunds (payment_id, amount_cents, reason, status) values (v_pay, 100, 'again', 'requested');
    raise exception 'FAIL 5p: refund beyond the paid amount accepted';
  exception when check_violation then null; end;
end $$;

-- ---- 6. partial refund + failed refund retry --------------------------------
select pg_temp.reset_all();
do $$
declare
  o public.orders; v_refund uuid; v_pay uuid; r text; v_amt int;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O6', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O6');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_p1', o.amount_cents, 'INR');
  v_amt := o.amount_cents;
  select id into v_pay from public.payments where razorpay_payment_id = 'pay_p1';

  insert into public.refunds (payment_id, amount_cents, reason, status) values (v_pay, v_amt / 2, 'partial', 'pending')
  returning id into v_refund;       -- legacy 'pending' is normalised to requested
  if (select status from public.refunds where id = v_refund) <> 'requested' then raise exception 'FAIL 6a: legacy pending not normalised'; end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_approve_refund(v_refund);
  perform public.admin_begin_refund_execution(v_refund);
  perform pg_temp.as_server();

  -- provider rejects it definitively -> failed
  r := public.record_refund_provider_result(v_refund, null, 'failed', 'insufficient balance', true);
  if r <> 'failed' or (select failure_reason from public.refunds where id = v_refund) is null then raise exception 'FAIL 6b: failure not recorded (%)', r; end if;
  if (select status from public.payments where id = v_pay) <> 'captured' or (select refunded_cents from public.payments where id = v_pay) <> 0 then
    raise exception 'FAIL 6c: failed refund changed the payment';
  end if;

  -- retry only from failed, only by a full admin
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_retry_refund(v_refund); raise exception 'FAIL 6d: operator retried a refund';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_retry_refund(v_refund);
  begin perform public.admin_retry_refund(v_refund); raise exception 'FAIL 6e: retry of a non-failed refund accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  if (select retry_count from public.refunds where id = v_refund) <> 1 then raise exception 'FAIL 6f: retry not counted'; end if;
  perform public.admin_begin_refund_execution(v_refund);
  perform pg_temp.as_server();

  -- provider says processed in its own response (verified provider data): completes
  r := public.record_refund_provider_result(v_refund, 'rfnd_p1', 'processed');
  if r <> 'processed' then raise exception 'FAIL 6g: %', r; end if;
  if (select status from public.payments where id = v_pay) <> 'captured' or (select refunded_cents from public.payments where id = v_pay) <> v_amt / 2 then
    raise exception 'FAIL 6h: partial refund must keep the payment captured and track refunded_cents';
  end if;
  if (select status from public.orders where id = o.id) <> 'paid' then raise exception 'FAIL 6i: partial refund marked the order refunded'; end if;

  -- the remaining half can still be requested, but not more
  insert into public.refunds (payment_id, amount_cents, reason, status) values (v_pay, v_amt - v_amt / 2, 'rest', 'requested');
  begin insert into public.refunds (payment_id, amount_cents, reason, status) values (v_pay, 1, 'over', 'requested');
    raise exception 'FAIL 6j: over-refund accepted';
  exception when check_violation then null; end;

  -- rejected refunds free their share of the budget
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_reject_refund((select id from public.refunds where reason = 'rest'), 'customer withdrew');
  perform pg_temp.as_server();
  insert into public.refunds (payment_id, amount_cents, reason, status) values (v_pay, 1, 'ok now', 'requested');
end $$;

-- ---- 7. unknown provider refund events are queued, never guessed ------------
select pg_temp.reset_all();
do $$
declare o public.orders; v_refund uuid; v_pay uuid;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O7', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O7');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_u1', o.amount_cents, 'INR');
  perform public.confirm_refund('rfnd_dashboard', 'pay_u1');           -- 2-arg call form still works
  if not exists (select 1 from public.reconciliation_exceptions where kind = 'unmatched_refund_event' and entity_id = 'rfnd_dashboard') then
    raise exception 'FAIL 7a: unknown refund event not queued';
  end if;
  if (select refunded_cents from public.payments where razorpay_payment_id = 'pay_u1') <> 0 then raise exception 'FAIL 7b: unknown refund changed the payment'; end if;

  -- a refund still only `requested` when the provider reports it processed: conflict, no state change
  select id into v_pay from public.payments where razorpay_payment_id = 'pay_u1';
  insert into public.refunds (payment_id, amount_cents, reason, status) values (v_pay, 100, 'x', 'requested') returning id into v_refund;
  perform public.confirm_refund('rfnd_x', 'pay_u1', v_refund);
  if (select status from public.refunds where id = v_refund) <> 'requested' then raise exception 'FAIL 7c: unapproved refund completed by an event'; end if;
  if not exists (select 1 from public.reconciliation_exceptions where kind = 'refund_state_conflict') then raise exception 'FAIL 7d: conflict not queued'; end if;
end $$;

-- ---- 8. cancelling a booking whose payment was already queued for refund -----
select pg_temp.reset_all();
do $$
declare o public.orders;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O8', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O8');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_c1', o.amount_cents, 'USD');   -- refund requested (currency)
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking(o.orderable_id, 'cancel anyway');
  perform pg_temp.as_server();
  if (select count(*) from public.refunds) <> 1 then raise exception 'FAIL 8a: cancel added a second refund for one payment (% rows)', (select count(*) from public.refunds); end if;
end $$;

-- ---- 9. webhook registry -----------------------------------------------------
do $$
declare r text;
begin
  perform pg_temp.as_server();
  r := public.webhook_begin('evt_1', 'payment.captured', '{"a":1}'::jsonb);
  if r <> 'process' then raise exception 'FAIL 9a: first delivery -> %', r; end if;
  r := public.webhook_begin('evt_1', 'payment.captured', '{"a":1}'::jsonb);
  if r <> 'in_progress' then raise exception 'FAIL 9b: concurrent delivery -> %', r; end if;
  perform public.webhook_finish('evt_1', true);
  r := public.webhook_begin('evt_1', 'payment.captured', '{"a":1}'::jsonb);
  if r <> 'duplicate' then raise exception 'FAIL 9c: redelivery after success -> %', r; end if;

  r := public.webhook_begin('evt_2', 'refund.processed', '{}'::jsonb);
  perform public.webhook_finish('evt_2', false, 'boom');
  if (select status from public.processed_webhook_events where event_id = 'evt_2') <> 'failed' then raise exception 'FAIL 9d: failure not recorded'; end if;
  r := public.webhook_begin('evt_2', 'refund.processed', '{}'::jsonb);
  if r <> 'process' or (select attempts from public.processed_webhook_events where event_id = 'evt_2') <> 2 then
    raise exception 'FAIL 9e: failed event not retried (% / attempts %)', r, (select attempts from public.processed_webhook_events where event_id = 'evt_2');
  end if;
end $$;

-- ---- 10. clients cannot reach the service-only functions ---------------------
do $$
begin
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.webhook_begin('evt_x', 't', '{}'::jsonb); raise exception 'FAIL 10a: customer called webhook_begin';
  exception when insufficient_privilege then null; end;
  begin perform public.record_refund_provider_result(gen_random_uuid(), 'x', 'processed'); raise exception 'FAIL 10b: customer called record_refund_provider_result';
  exception when insufficient_privilege then null; end;
  begin perform public.confirm_booking_after_payment('x', 'y', 1, 'INR'); raise exception 'FAIL 10c: customer called confirm_booking_after_payment';
  exception when insufficient_privilege then null; end;
  begin perform count(*) from public.reconciliation_exceptions where false; perform 1;
  end;
  if exists (select 1 from public.reconciliation_exceptions) then raise exception 'FAIL 10d: customer can read the exception queue'; end if;
  perform pg_temp.as_server();
end $$;

rollback;
