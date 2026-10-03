-- =========================================================================
-- Checks for Gate B (20261003000400_gateb_ledger.sql)
--   * balanced journals only; integer paise; unknown accounts refused
--   * the same business event can never be posted twice (source_event_key)
--   * posted records are immutable; direct writes refused; clients cannot write
--   * payment capture / refund approval / refund processed post the matrix events
--   * duplicate captures and refunds net out; trial balance always balances
--   * corrections only through reversal journals (admin, once, audited)
--   * backfill is idempotent
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

-- a default refund policy so approvals can calculate (policies are admin data; none is seeded)
insert into public.refund_policies (name, category, status, refund_bps, deduction_operator_share_bps, effective_from)
values ('test default', 'default', 'active', 10000, 0, current_date - 1);

create function pg_temp.reset_all() returns void language plpgsql as $f$
begin
  perform pg_temp.as_server();
  set constraints all immediate;   -- flush deferred balance checks before touching the tables
  alter table public.ledger_journals disable trigger ledger_journals_immutable;
  alter table public.ledger_entries disable trigger ledger_entries_immutable;
  delete from public.ledger_entries;
  delete from public.ledger_journals;
  alter table public.ledger_journals enable trigger ledger_journals_immutable;
  alter table public.ledger_entries enable trigger ledger_entries_immutable;
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
  set constraints all deferred;
end $f$;

create function pg_temp.bal(p_code text) returns bigint language sql as $f$
  select coalesce(sum(balance_cents), 0)::bigint from public.ledger_account_balances where account_code = p_code
$f$;

create function pg_temp.order_of(p_tag text) returns public.orders language sql as $f$
  select o from public.orders o where o.id = (select id from t_ref where tag = p_tag)
$f$;

-- ---- 1. post_journal validation + idempotency ---------------------------------
do $$
declare j1 uuid; j2 uuid;
begin
  perform pg_temp.as_server();
  if (select count(*) from public.ledger_accounts) <> 10 then raise exception 'FAIL 1a: chart of accounts not seeded'; end if;

  j1 := private.post_journal('t:1', 'test', jsonb_build_array(
          jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', 500),
          jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', 500)));
  j2 := private.post_journal('t:1', 'test', jsonb_build_array(
          jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', 500),
          jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', 500)));
  if j1 <> j2 then raise exception 'FAIL 1b: same event key created a second journal'; end if;
  if (select count(*) from public.ledger_entries where journal_id = j1) <> 2 then raise exception 'FAIL 1c: entries duplicated on replay'; end if;

  begin perform private.post_journal('t:1', 'test', jsonb_build_array(
          jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', 900),
          jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', 900)));
    raise exception 'FAIL 1d: same key with a different total accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  begin perform private.post_journal('t:2', 'test', jsonb_build_array(
          jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', 500),
          jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', 499)));
    raise exception 'FAIL 1e: unbalanced journal accepted';
  exception when check_violation then null; end;

  begin perform private.post_journal('t:3', 'test', jsonb_build_array(
          jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', 0),
          jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', 0)));
    raise exception 'FAIL 1f: zero amounts accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  begin perform private.post_journal('t:4', 'test', jsonb_build_array(
          jsonb_build_object('account', 'nope', 'side', 'debit', 'amount_cents', 5),
          jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', 5)));
    raise exception 'FAIL 1g: unknown account accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  if exists (select 1 from public.ledger_journals where source_event_key in ('t:2', 't:3', 't:4')) then
    raise exception 'FAIL 1h: a refused journal left rows behind';
  end if;

  begin perform private.post_journal('t:5', 'test', jsonb_build_array(
          jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', 5)));
    raise exception 'FAIL 1i: single-line journal accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- ---- 2. immutability, single writer, deferred balance check ---------------------
do $$
declare v_j uuid;
begin
  perform pg_temp.as_server();
  select id into v_j from public.ledger_journals where source_event_key = 't:1';

  begin update public.ledger_entries set amount_cents = 1 where journal_id = v_j; raise exception 'FAIL 2a: entry updated';
  exception when object_not_in_prerequisite_state then null; end;
  begin delete from public.ledger_entries where journal_id = v_j; raise exception 'FAIL 2b: entry deleted';
  exception when object_not_in_prerequisite_state then null; end;
  begin update public.ledger_journals set event_type = 'x' where id = v_j; raise exception 'FAIL 2c: journal updated';
  exception when object_not_in_prerequisite_state then null; end;
  begin delete from public.ledger_journals where id = v_j; raise exception 'FAIL 2d: journal deleted';
  exception when object_not_in_prerequisite_state then null; end;
  begin truncate public.ledger_entries; raise exception 'FAIL 2e: truncated';
  exception when object_not_in_prerequisite_state then null; end;

  begin
    insert into public.ledger_journals (source_event_key, event_type, total_cents) values ('direct', 'x', 10);
    raise exception 'FAIL 2f: direct journal insert accepted';
  exception when insufficient_privilege then null; end;

  -- even with the writer flag, an unbalanced journal is caught by the constraint trigger
  -- (the whole attempt sits in a sub-block so its rows are rolled back with the error)
  begin
    perform set_config('thirty8.ledger_writer', 'on', true);
    insert into public.ledger_journals (source_event_key, event_type, total_cents) values ('sneaky', 'x', 10);
    insert into public.ledger_entries (journal_id, account_id, side, amount_cents)
      values ((select id from public.ledger_journals where source_event_key = 'sneaky'),
              (select id from public.ledger_accounts where code = 'razorpay_clearing'), 'debit', 10);
    set constraints all immediate;
    raise exception 'FAIL 2g: unbalanced journal passed the balance constraint';
  exception when check_violation then null; end;
  set constraints all deferred;
  perform set_config('thirty8.ledger_writer', 'off', true);
end $$;
select pg_temp.reset_all();

-- ---- 3. clients cannot write; only admins read -----------------------------------
do $$
begin
  perform private.post_journal('t:ro', 'test', jsonb_build_array(
          jsonb_build_object('account', 'razorpay_clearing', 'side', 'debit', 'amount_cents', 5),
          jsonb_build_object('account', 'booking_liability', 'side', 'credit', 'amount_cents', 5)));

  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin insert into public.ledger_journals (source_event_key, event_type, total_cents) values ('c', 'x', 5);
    raise exception 'FAIL 3a: customer wrote a journal';
  exception when insufficient_privilege then null; end;
  if exists (select 1 from public.ledger_journals) or exists (select 1 from public.ledger_entries) then
    raise exception 'FAIL 3b: customer can read the ledger';
  end if;
  begin perform private.post_journal('c2', 'x', '[]'::jsonb); raise exception 'FAIL 3c: customer called post_journal';
  exception when insufficient_privilege then null; end;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if exists (select 1 from public.ledger_journals) then raise exception 'FAIL 3d: operator can read the ledger'; end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  if (select count(*) from public.ledger_journals) <> 1 then raise exception 'FAIL 3e: admin cannot read the ledger'; end if;
  perform pg_temp.as_server();
end $$;
select pg_temp.reset_all();

-- ---- 4. payment capture + refund lifecycle post the matrix -----------------------
do $$
declare o public.orders; v_refund uuid; v_pay uuid; v_amt int;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O4', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O4');
  v_amt := o.amount_cents;
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_l1', v_amt, 'INR');
  select id into v_pay from public.payments where razorpay_payment_id = 'pay_l1';

  if pg_temp.bal('razorpay_clearing') <> v_amt or pg_temp.bal('booking_liability') <> v_amt then
    raise exception 'FAIL 4a: capture not posted Dr clearing / Cr liability (% / %)', pg_temp.bal('razorpay_clearing'), pg_temp.bal('booking_liability');
  end if;
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_l1', v_amt, 'INR');   -- replay
  if (select count(*) from public.ledger_journals where event_type = 'payment_captured') <> 1 then
    raise exception 'FAIL 4b: payment replay posted a second journal';
  end if;

  -- cancellation requests a refund: nothing is posted yet
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking(o.orderable_id, 'x');
  perform pg_temp.as_server();
  select id into v_refund from public.refunds;
  if (select count(*) from public.ledger_journals) <> 1 then raise exception 'FAIL 4c: a mere refund REQUEST posted to the ledger'; end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_approve_refund(v_refund);
  perform pg_temp.as_server();
  if pg_temp.bal('refund_payable') <> v_amt or pg_temp.bal('booking_liability') <> 0 then
    raise exception 'FAIL 4d: approval not posted Dr liability / Cr refund payable';
  end if;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_begin_refund_execution(v_refund);
  perform pg_temp.as_server();
  perform public.record_refund_provider_result(v_refund, 'rfnd_l1', 'pending');
  if (select count(*) from public.ledger_journals where event_type = 'refund_processed') <> 0 then
    raise exception 'FAIL 4e: provider acceptance posted the processed journal';
  end if;
  perform public.confirm_refund('rfnd_l1', 'pay_l1', v_refund);
  perform public.confirm_refund('rfnd_l1', 'pay_l1', v_refund);   -- replayed webhook
  if pg_temp.bal('refund_payable') <> 0 or pg_temp.bal('razorpay_clearing') <> 0 or pg_temp.bal('booking_liability') <> 0 then
    raise exception 'FAIL 4f: after the refund the accounts do not net to zero (% / % / %)',
      pg_temp.bal('refund_payable'), pg_temp.bal('razorpay_clearing'), pg_temp.bal('booking_liability');
  end if;
  if (select count(*) from public.ledger_journals) <> 3 then raise exception 'FAIL 4g: expected 3 journals, got %', (select count(*) from public.ledger_journals); end if;

  if (select sum(amount_cents) filter (where side = 'debit') from public.ledger_entries)
     <> (select sum(amount_cents) filter (where side = 'credit') from public.ledger_entries) then
    raise exception 'FAIL 4h: trial balance does not balance';
  end if;
end $$;
select pg_temp.reset_all();

-- ---- 5. duplicate capture + its refund net out ------------------------------------
do $$
declare o public.orders; v_amt int; v_refund uuid;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O5', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O5');
  v_amt := o.amount_cents;
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_d1', v_amt, 'INR');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_d2', v_amt, 'INR');   -- duplicate real capture
  if pg_temp.bal('razorpay_clearing') <> 2 * v_amt then raise exception 'FAIL 5a: both captures must be on the ledger'; end if;

  select r.id into v_refund from public.refunds r join public.payments p on p.id = r.payment_id where p.razorpay_payment_id = 'pay_d2';
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_approve_refund(v_refund);
  perform public.admin_begin_refund_execution(v_refund);
  perform pg_temp.as_server();
  perform public.record_refund_provider_result(v_refund, 'rfnd_d2', 'processed');
  if pg_temp.bal('razorpay_clearing') <> v_amt or pg_temp.bal('booking_liability') <> v_amt or pg_temp.bal('refund_payable') <> 0 then
    raise exception 'FAIL 5b: duplicate refund should leave exactly the one real sale (% / % / %)',
      pg_temp.bal('razorpay_clearing'), pg_temp.bal('booking_liability'), pg_temp.bal('refund_payable');
  end if;
end $$;

-- ---- 6. reversal -------------------------------------------------------------------
do $$
declare v_j uuid; v_rev uuid; v_before bigint;
begin
  perform pg_temp.as_server();
  select id into v_j from public.ledger_journals where event_type = 'payment_captured' order by posted_at limit 1;
  v_before := pg_temp.bal('razorpay_clearing');

  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_reverse_journal(v_j, 'oops');
    raise exception 'FAIL 6a: operator reversed a journal';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f'); perform public.admin_reverse_journal(v_j, ' ');
    raise exception 'FAIL 6b: reversal without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  v_rev := public.admin_reverse_journal(v_j, 'posted in error');
  perform pg_temp.as_server();
  if pg_temp.bal('razorpay_clearing') >= v_before then raise exception 'FAIL 6c: reversal did not reduce the account'; end if;
  if (select reverses_journal_id from public.ledger_journals where id = v_rev) <> v_j then raise exception 'FAIL 6d: reversal not linked'; end if;
  if (select count(*) from public.ledger_entries where journal_id = v_j) <> 2 then raise exception 'FAIL 6e: original entries changed'; end if;
  if not exists (select 1 from public.audit_logs where action = 'ledger.reverse' and entity_id = v_j) then raise exception 'FAIL 6f: reversal not audited'; end if;

  begin perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f'); perform public.admin_reverse_journal(v_j, 'again');
    raise exception 'FAIL 6g: journal reversed twice';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f'); perform public.admin_reverse_journal(v_rev, 'undo undo');
    raise exception 'FAIL 6h: reversal reversed';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;
select pg_temp.reset_all();

-- ---- 7. backfill is idempotent and covers pre-ledger money -----------------------------
do $$
declare o public.orders; n1 int; n2 int;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O7', 1);
  perform pg_temp.as_server();
  o := pg_temp.order_of('O7');
  alter table public.payments disable trigger payments_ledger;      -- simulate a payment recorded before the ledger existed
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_old', o.amount_cents, 'INR');
  alter table public.payments enable trigger payments_ledger;
  if (select count(*) from public.ledger_journals) <> 0 then raise exception 'FAIL 7a: setup'; end if;

  n1 := private.ledger_backfill();
  n2 := private.ledger_backfill();
  if n1 <> 1 or n2 <> 0 then raise exception 'FAIL 7b: backfill posted % then % journals (expected 1 then 0)', n1, n2; end if;
  if pg_temp.bal('razorpay_clearing') <> o.amount_cents then raise exception 'FAIL 7c: backfilled balance wrong'; end if;
end $$;

rollback;
