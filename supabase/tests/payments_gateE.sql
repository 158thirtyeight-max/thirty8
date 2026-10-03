-- =========================================================================
-- Checks for Gate E (20261003000800_gatee_sbi_export_import.sql)
--   * export: immutable snapshot + SHA-256, only approved batches, idempotent re-export, one file per batch,
--     configurable template (validated), CSV quoting, full-admin only, downloads audited
--   * import: preview changes nothing; confirm applies only matched rows; file applied once (hash);
--     UTR unique; amount / account / unknown / not-exported / already-paid / duplicate rows become exceptions
--   * paid: earnings settled, adjustments settled, recoveries reduced, ledger event 4; failed rows fail the batch only
--   * maker-checker: the approver cannot confirm payment
--   * zero-net batches settle through an explicit RPC
--   * reconciliation: detects, never corrects; exceptions resolved only by a person with a note
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

insert into auth.users (id, email) values
  ('77777777-0000-0000-0000-000000000007', 'support@test.invalid'),
  ('88888888-0000-0000-0000-000000000008', 'admin2@test.invalid');
insert into public.user_roles (user_id, role) values
  ('77777777-0000-0000-0000-000000000007', 'platform_support'),
  ('88888888-0000-0000-0000-000000000008', 'platform_admin');
insert into public.operator_bank_details (operator_id, account_holder_name, bank_name, account_number, ifsc)
values ((select id from t_ops where tag = 'A'), 'Operator A', 'SBI', '123456789012', 'SBIN0001234')
on conflict (operator_id) do update set account_holder_name = excluded.account_holder_name, account_number = excluded.account_number, ifsc = excluded.ifsc;

create function pg_temp.reset_all() returns void language plpgsql as $f$
begin
  perform pg_temp.as_server();
  set constraints all immediate;
  alter table public.ledger_journals disable trigger ledger_journals_immutable;
  alter table public.ledger_entries disable trigger ledger_entries_immutable;
  alter table public.settlement_exports disable trigger settlement_exports_immutable;
  alter table public.settlement_export_rows disable trigger settlement_export_rows_immutable;
  delete from public.bank_result_rows;
  delete from public.bank_result_imports;
  delete from public.settlement_payments;
  update public.settlements set export_id = null;
  delete from public.settlement_export_rows;
  delete from public.settlement_exports;
  delete from public.settlement_items;
  delete from public.operator_adjustments;
  delete from public.operator_recovery;
  delete from public.operator_earnings;
  delete from public.settlements;
  delete from public.ledger_entries;
  delete from public.ledger_journals;
  alter table public.ledger_journals enable trigger ledger_journals_immutable;
  alter table public.ledger_entries enable trigger ledger_entries_immutable;
  alter table public.settlement_exports enable trigger settlement_exports_immutable;
  alter table public.settlement_export_rows enable trigger settlement_export_rows_immutable;
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
create function pg_temp.as_admin() returns void language sql as $f$ select pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f') $f$;
create function pg_temp.as_admin2() returns void language sql as $f$ select pg_temp.as_user('88888888-0000-0000-0000-000000000008') $f$;
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
-- sell + board one seat, build the batch for that period, approve it as admin 1; returns the batch id
create function pg_temp.ready_batch(p_tag text, p_seat int, p_end_offset int) returns uuid language plpgsql as $f$
declare v uuid;
begin
  perform pg_temp.sale(p_tag, p_seat, 'pay_' || p_tag);
  perform pg_temp.board(p_tag);
  perform pg_temp.as_admin();
  perform public.admin_build_weekly_settlement(current_date + p_end_offset);
  select id into v from public.settlements where operator_id = (select id from t_ops where tag = 'A') and status = 'draft' and period_end = current_date + p_end_offset;
  perform public.admin_approve_settlement(v);
  perform pg_temp.as_server();
  return v;
end $f$;
create function pg_temp.ref(p_id uuid) returns text language sql security definer as $f$ select reference from public.settlements where id = p_id $f$;
create function pg_temp.st(p_id uuid) returns text language sql security definer as $f$ select status from public.settlements where id = p_id $f$;
create function pg_temp.exc(p_kind text) returns int language sql security definer as $f$ select count(*)::int from public.reconciliation_exceptions where kind = p_kind and status = 'open' $f$;

select pg_temp.as_admin();
select public.admin_set_commission((select id from t_ops where tag = 'A'), 1000);
select public.admin_set_payment_profile_status((select id from t_ops where tag = 'A'), 'verified', null);
select pg_temp.as_server();

-- ---- 1. export --------------------------------------------------------------------------------------------------
do $$
declare b1 uuid; b2 uuid; x jsonb; y jsonb; v_ref text; e public.settlement_exports;
begin
  b1 := pg_temp.ready_batch('E1', 1, 1);
  v_ref := pg_temp.ref(b1);

  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_export_settlement_file(array[b1]); raise exception 'FAIL 1a: operator exported';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_export_settlement_file(array[b1]); raise exception 'FAIL 1b: support exported';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.admin_export_settlement_file(array[b1]); raise exception 'FAIL 1c: customer exported';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  perform pg_temp.as_admin();
  x := public.admin_export_settlement_file(array[b1]);
  perform pg_temp.as_server();
  if x ->> 'content' <> E'Beneficiary Name,Account Number,IFSC,Amount,Payment Mode,Narration,Reference\nOperator A,123456789012,SBIN0001234,450.00,NEFT,' || v_ref || ',' || v_ref || E'\n' then
    raise exception 'FAIL 1d: file content %', x ->> 'content';
  end if;
  if x ->> 'sha256' <> encode(extensions.digest(convert_to(x ->> 'content', 'UTF8'), 'sha256'), 'hex') or (x ->> 'row_count')::int <> 1 or (x ->> 'total_cents')::bigint <> 45000 then raise exception 'FAIL 1e: %', x - 'content'; end if;
  if (x ->> 'template_confirmed')::boolean then raise exception 'FAIL 1f: the SBI layout must be flagged as unconfirmed'; end if;
  if pg_temp.st(b1) <> 'exported' or (select exported_at from public.settlements where id = b1) is null or (select export_id from public.settlements where id = b1) <> (x ->> 'export_id')::uuid then raise exception 'FAIL 1g: batch not marked exported'; end if;
  if not exists (select 1 from public.audit_logs where action = 'settlement_export.create' and entity_id = (x ->> 'export_id')::uuid) then raise exception 'FAIL 1h: export not audited'; end if;

  -- same batches again: the same immutable snapshot
  perform pg_temp.as_admin();
  y := public.admin_export_settlement_file(array[b1]);
  perform pg_temp.as_server();
  if y ->> 'export_id' <> x ->> 'export_id' or y ->> 'sha256' <> x ->> 'sha256' or not (y ->> 'already_exported')::boolean then raise exception 'FAIL 1i: re-export must return the same file'; end if;
  if (select count(*) from public.settlement_exports) <> 1 then raise exception 'FAIL 1j: a second export file was created'; end if;

  -- immutability
  begin update public.settlement_exports set content = 'x'; raise exception 'FAIL 1k: export edited';
  exception when object_not_in_prerequisite_state then null; end;
  begin delete from public.settlement_exports; raise exception 'FAIL 1l: export deleted';
  exception when object_not_in_prerequisite_state then null; end;

  -- download is audited; clients cannot read the table
  perform pg_temp.as_admin();
  y := public.admin_get_settlement_export((x ->> 'export_id')::uuid);
  perform pg_temp.as_server();
  if y ->> 'content' <> x ->> 'content' or not exists (select 1 from public.audit_logs where action = 'settlement_export.download') then raise exception 'FAIL 1m'; end if;
  begin perform pg_temp.as_admin(); perform 1 from public.settlement_exports; raise exception 'FAIL 1n: client read export contents';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  -- a batch already in a file cannot be put in another; draft / zero batches are refused
  b2 := pg_temp.ready_batch('E2', 2, 2);
  begin perform pg_temp.as_admin(); perform public.admin_export_settlement_file(array[b1, b2]); raise exception 'FAIL 1o: a batch was exported twice';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'already_exported%' then raise exception 'FAIL 1o2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();
  perform pg_temp.sale('E3', 3, 'pay_E3'); perform pg_temp.board('E3');
  perform pg_temp.as_admin();
  perform public.admin_build_weekly_settlement(current_date + 3);
  begin perform public.admin_export_settlement_file(array[(select id from public.settlements where status = 'draft')]); raise exception 'FAIL 1p: exported a draft';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'settlement_not_approved%' then raise exception 'FAIL 1p2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 1b. template: validated, CSV quoting, configurable layout --------------------------------------------------------
select pg_temp.reset_all();
do $$
declare b uuid; x jsonb;
begin
  perform pg_temp.as_admin();
  begin perform public.admin_set_platform_setting('settlement_export_template', '{"columns":[{"header":"x","field":"secret_field"}]}'::jsonb); raise exception 'FAIL 1q: unknown field accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_set_platform_setting('settlement_export_template', '{"columns":[]}'::jsonb); raise exception 'FAIL 1r: empty template accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_set_platform_setting('settlement_export_template', '{"columns":[{"header":"a","field":"amount"}]}'::jsonb); raise exception 'FAIL 1s: support changed the template';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  update public.operator_bank_details set account_holder_name = 'A, "Quoted" Travels' where operator_id = (select id from t_ops where tag = 'A');
  perform pg_temp.as_admin();
  perform public.admin_set_payment_profile_status((select id from t_ops where tag = 'A'), 'verified', null);
  perform public.admin_set_platform_setting('settlement_export_template',
    '{"confirmed":true,"format":"csv","columns":[{"header":"Amt (paise)","field":"amount_paise"},{"header":"Name","field":"beneficiary_name"},{"header":"Ref","field":"reference"}]}'::jsonb);
  perform pg_temp.as_server();
  b := pg_temp.ready_batch('E4', 1, 1);
  perform pg_temp.as_admin();
  x := public.admin_export_settlement_file(array[b]);
  perform pg_temp.as_server();
  if x ->> 'content' <> E'Amt (paise),Name,Ref\n45000,"A, ""Quoted"" Travels",' || pg_temp.ref(b) || E'\n' then raise exception 'FAIL 1t: layout/quoting %', x ->> 'content'; end if;
  if not (x ->> 'template_confirmed')::boolean then raise exception 'FAIL 1u: confirmed flag not carried'; end if;
  perform pg_temp.as_admin();
  perform public.admin_set_platform_setting('settlement_export_template', jsonb_build_object('confirmed', false, 'format', 'csv', 'columns', jsonb_build_array(
    jsonb_build_object('header', 'Beneficiary Name', 'field', 'beneficiary_name'), jsonb_build_object('header', 'Account Number', 'field', 'account_number'),
    jsonb_build_object('header', 'IFSC', 'field', 'ifsc'), jsonb_build_object('header', 'Amount', 'field', 'amount'),
    jsonb_build_object('header', 'Payment Mode', 'value', 'NEFT'), jsonb_build_object('header', 'Narration', 'field', 'narration'),
    jsonb_build_object('header', 'Reference', 'field', 'reference'))));
  perform pg_temp.as_server();
  update public.operator_bank_details set account_holder_name = 'Operator A' where operator_id = (select id from t_ops where tag = 'A');
  perform pg_temp.as_admin();
  perform public.admin_set_payment_profile_status((select id from t_ops where tag = 'A'), 'verified', null);
  perform pg_temp.as_server();
end $$;

-- ---- 2. import: preview, maker-checker, confirm, idempotency ------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare b1 uuid; v_ref text; x jsonb; p jsonb; rows jsonb; c jsonb; v_imp uuid; v_pay public.settlement_payments;
begin
  b1 := pg_temp.ready_batch('E5', 1, 1);
  v_ref := pg_temp.ref(b1);
  perform pg_temp.as_admin();
  x := public.admin_export_settlement_file(array[b1]);
  perform pg_temp.as_server();
  rows := jsonb_build_array(jsonb_build_object('reference', v_ref, 'account', '9012', 'amount', '450.00', 'utr', 'SBIN26277000001', 'status', 'SUCCESS', 'paid_on', '2026-10-03'));

  -- nobody but a full admin
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_preview_bank_result('r.csv', rows); raise exception 'FAIL 2a: operator previewed';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_preview_bank_result('r.csv', rows); raise exception 'FAIL 2b: support previewed';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  -- preview changes nothing
  perform pg_temp.as_admin();
  p := public.admin_preview_bank_result('r.csv', rows);
  perform pg_temp.as_server();
  v_imp := (p ->> 'import_id')::uuid;
  if p -> 'summary' ->> 'matched' <> '1' or pg_temp.st(b1) <> 'exported' or exists (select 1 from public.settlement_payments) then raise exception 'FAIL 2c: preview %', p; end if;

  -- the approver (admin 1) cannot confirm; nothing is applied
  begin perform pg_temp.as_admin(); perform public.admin_confirm_bank_result(v_imp); raise exception 'FAIL 2d: the approver confirmed payment';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'maker_checker_violation%' then raise exception 'FAIL 2d2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();
  if pg_temp.st(b1) <> 'exported' then raise exception 'FAIL 2e: maker-checker violation applied something'; end if;

  perform pg_temp.as_admin2();
  c := public.admin_confirm_bank_result(v_imp);
  perform pg_temp.as_server();
  if (c ->> 'paid')::int <> 1 or (c ->> 'exceptions')::int <> 0 then raise exception 'FAIL 2f: %', c; end if;
  if pg_temp.st(b1) <> 'paid' then raise exception 'FAIL 2g: batch not paid'; end if;
  if (select paid_cents from public.settlements where id = b1) <> 45000 or (select txn_reference from public.settlements where id = b1) <> 'SBIN26277000001'
     or (select bank_paid_at from public.settlements where id = b1)::date <> '2026-10-03' or (select completed_at from public.settlements where id = b1) is null
     or (select exported_at from public.settlements where id = b1) is null or (select approved_at from public.settlements where id = b1) is null then raise exception 'FAIL 2h: dates / reference'; end if;
  select * into v_pay from public.settlement_payments where settlement_id = b1;
  if v_pay.status <> 'paid' or v_pay.utr <> 'SBIN26277000001' or v_pay.amount_cents <> 45000 or v_pay.provider <> 'manual_sbi' or v_pay.confirmed_by <> '88888888-0000-0000-0000-000000000008' then raise exception 'FAIL 2i: payment row %', v_pay; end if;
  if (select status from public.operator_earnings where settlement_id = b1) <> 'settled' then raise exception 'FAIL 2j: earnings not settled'; end if;
  if pg_temp.bal('operator_payable') <> 0 or pg_temp.bal('settlement_bank') <> -45000 or pg_temp.bal('platform_commission') <> 5000 or pg_temp.bal('booking_liability') <> 0 then
    raise exception 'FAIL 2k: ledger after payout (% / % / % / %)', pg_temp.bal('operator_payable'), pg_temp.bal('settlement_bank'), pg_temp.bal('platform_commission'), pg_temp.bal('booking_liability');
  end if;
  if not exists (select 1 from public.audit_logs where action = 'settlement.paid' and entity_id = b1) or not exists (select 1 from public.audit_logs where action = 'bank_import.confirm') then raise exception 'FAIL 2l: audit'; end if;

  -- the same file again is a no-op
  perform pg_temp.as_admin();
  p := public.admin_preview_bank_result('r-again.csv', rows);
  perform pg_temp.as_server();
  if not (p ->> 'already_imported')::boolean or (select count(*) from public.settlement_payments) <> 1 then raise exception 'FAIL 2m: re-import %', p; end if;
  perform pg_temp.as_admin2();
  c := public.admin_confirm_bank_result(v_imp);
  perform pg_temp.as_server();
  if not (c ->> 'already_confirmed')::boolean or (select count(*) from public.settlement_payments) <> 1 or (select count(*) from public.ledger_journals where event_type = 'settlement_paid') <> 1 then raise exception 'FAIL 2n: duplicate confirm paid twice'; end if;

  -- a different file reusing the UTR, or paying a paid batch, creates exceptions only
  perform pg_temp.as_admin();
  p := public.admin_preview_bank_result('r2.csv', jsonb_build_array(jsonb_build_object('reference', v_ref, 'amount', '450.00', 'utr', 'SBIN26277000001', 'status', 'SUCCESS')));
  perform pg_temp.as_server();
  if p -> 'summary' ->> 'already_paid' <> '1' then raise exception 'FAIL 2o: %', p; end if;
  perform pg_temp.as_admin2();
  c := public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if (c ->> 'paid')::int <> 0 or (c ->> 'exceptions')::int <> 1 or pg_temp.exc('bank_row_already_paid') <> 1 or (select count(*) from public.settlement_payments) <> 1 then raise exception 'FAIL 2p: %', c; end if;
end $$;

-- ---- 3. validation of rows ---------------------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare b1 uuid; b2 uuid; b3 uuid; r1 text; r2 text; r3 text; p jsonb; c jsonb;
begin
  b1 := pg_temp.ready_batch('E6', 1, 1); b2 := pg_temp.ready_batch('E7', 2, 2); b3 := pg_temp.ready_batch('E8', 3, 3);
  r1 := pg_temp.ref(b1); r2 := pg_temp.ref(b2); r3 := pg_temp.ref(b3);
  perform pg_temp.as_admin();
  perform public.admin_export_settlement_file(array[b1, b2, b3]);
  p := public.admin_preview_bank_result('bad.csv', jsonb_build_array(
    jsonb_build_object('reference', r1, 'amount', '449.99', 'utr', 'U1', 'status', 'SUCCESS'),                         -- wrong amount
    jsonb_build_object('reference', r2, 'account', '0000', 'amount', '450.00', 'utr', 'U2', 'status', 'SUCCESS'),     -- wrong account
    jsonb_build_object('reference', 'ST-NOPE0000', 'amount', '450.00', 'utr', 'U3', 'status', 'SUCCESS'),             -- unknown batch
    jsonb_build_object('reference', r3, 'amount', '450.00', 'status', 'SUCCESS'),                                      -- no UTR
    jsonb_build_object('reference', r3, 'amount', '450.00', 'utr', 'U5', 'status', 'MAYBE'),                           -- unknown status
    jsonb_build_object('reference', r3, 'amount', 'abc', 'utr', 'U6', 'status', 'SUCCESS')));                          -- unreadable amount
  perform pg_temp.as_server();
  if p -> 'summary' ->> 'amount_mismatch' <> '1' or p -> 'summary' ->> 'account_mismatch' <> '1' or p -> 'summary' ->> 'unmatched' <> '1'
     or p -> 'summary' ->> 'missing_utr' <> '1' or p -> 'summary' ->> 'invalid_row' <> '2' then raise exception 'FAIL 3a: %', p -> 'summary'; end if;
  perform pg_temp.as_admin2();
  c := public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if (c ->> 'paid')::int <> 0 or (c ->> 'exceptions')::int <> 6 then raise exception 'FAIL 3b: %', c; end if;
  if pg_temp.st(b1) <> 'exported' or pg_temp.st(b2) <> 'exported' or pg_temp.st(b3) <> 'exported' or exists (select 1 from public.settlement_payments) then raise exception 'FAIL 3c: a mismatched row changed a batch'; end if;
  if pg_temp.exc('bank_row_amount_mismatch') <> 1 or pg_temp.exc('bank_row_unmatched') <> 1 or pg_temp.exc('bank_row_account_mismatch') <> 1 then raise exception 'FAIL 3d: exceptions not queued'; end if;

  -- duplicate rows / duplicate UTR inside one file: only the first applies
  perform pg_temp.as_admin();
  p := public.admin_preview_bank_result('dups.csv', jsonb_build_array(
    jsonb_build_object('reference', r1, 'amount', '450.00', 'utr', 'D1', 'status', 'SUCCESS'),
    jsonb_build_object('reference', r1, 'amount', '450.00', 'utr', 'D2', 'status', 'SUCCESS'),
    jsonb_build_object('reference', r2, 'amount', '450.00', 'utr', 'D1', 'status', 'SUCCESS')));
  perform pg_temp.as_server();
  if p -> 'summary' ->> 'matched' <> '1' or p -> 'summary' ->> 'duplicate_row' <> '1' or p -> 'summary' ->> 'duplicate_utr' <> '1' then raise exception 'FAIL 3e: %', p -> 'summary'; end if;
  perform pg_temp.as_admin2();
  c := public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if (c ->> 'paid')::int <> 1 or pg_temp.st(b1) <> 'paid' or pg_temp.st(b2) <> 'exported' then raise exception 'FAIL 3f: %', c; end if;

  -- a UTR already used by another payment can never be paid again
  perform pg_temp.as_admin();
  p := public.admin_preview_bank_result('reuse.csv', jsonb_build_array(jsonb_build_object('reference', r2, 'amount', '450.00', 'utr', 'D1', 'status', 'SUCCESS')));
  perform pg_temp.as_server();
  if p -> 'summary' ->> 'duplicate_utr' <> '1' then raise exception 'FAIL 3g: %', p -> 'summary'; end if;
  begin insert into public.settlement_payments (settlement_id, provider, amount_cents, status, utr, idempotency_key) values (b2, 'manual_sbi', 45000, 'paid', 'D1', 'x');
    raise exception 'FAIL 3h: duplicate UTR accepted by the database';
  exception when unique_violation then null; end;

  -- a batch that was never exported cannot be paid by a bank file
  perform pg_temp.as_admin();
  p := public.admin_preview_bank_result('unexp.csv', jsonb_build_array(jsonb_build_object('reference', r2, 'amount', '450.00', 'utr', 'U9', 'status', 'SUCCESS')));
  perform pg_temp.as_server();
  update public.settlements set status = 'approved' where id = b2;
  perform pg_temp.as_admin();
  p := public.admin_preview_bank_result('unexp2.csv', jsonb_build_array(jsonb_build_object('reference', r2, 'amount', '450.00', 'utr', 'U10', 'status', 'SUCCESS')));
  perform pg_temp.as_server();
  if p -> 'summary' ->> 'batch_not_exported' <> '1' then raise exception 'FAIL 3i: %', p -> 'summary'; end if;
  update public.settlements set status = 'exported' where id = b2;
end $$;

-- ---- 4. bank failure + release, maker-checker setting ------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare b1 uuid; r1 text; p jsonb; c jsonb;
begin
  b1 := pg_temp.ready_batch('E9', 1, 1); r1 := pg_temp.ref(b1);
  perform pg_temp.as_admin();
  perform public.admin_export_settlement_file(array[b1]);
  p := public.admin_preview_bank_result('fail.csv', jsonb_build_array(jsonb_build_object('reference', r1, 'amount', '450.00', 'status', 'REJECTED', 'failure_reason', 'Invalid IFSC')));
  perform pg_temp.as_server();
  perform pg_temp.as_admin2();
  c := public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if (c ->> 'failed')::int <> 1 or pg_temp.st(b1) <> 'failed' or (select failure_reason from public.settlements where id = b1) <> 'Invalid IFSC' then raise exception 'FAIL 4a: %', c; end if;
  if (select status from public.operator_earnings) <> 'in_batch' or exists (select 1 from public.ledger_journals where event_type = 'settlement_paid') then raise exception 'FAIL 4b: a failed payout must not settle anything'; end if;
  if (select status from public.settlement_payments) <> 'failed' then raise exception 'FAIL 4c: failed attempt not recorded'; end if;
  perform pg_temp.as_admin();
  perform public.admin_cancel_settlement(b1, 'bank rejected the account; operator will correct details');
  perform pg_temp.as_server();
  if (select status from public.operator_earnings) <> 'eligible' then raise exception 'FAIL 4d: release did not return the earning'; end if;

  -- with maker-checker off, a single admin may do both (the setting is audited)
  perform pg_temp.as_admin();
  perform public.admin_set_platform_setting('settlement_maker_checker', 'false'::jsonb);
  perform public.admin_build_weekly_settlement(current_date + 2);
  perform public.admin_approve_settlement((select id from public.settlements where status = 'draft'));
  perform pg_temp.as_server();
  b1 := (select id from public.settlements where status = 'approved'); r1 := pg_temp.ref(b1);
  perform pg_temp.as_admin();
  perform public.admin_export_settlement_file(array[b1]);
  p := public.admin_preview_bank_result('solo.csv', jsonb_build_array(jsonb_build_object('reference', r1, 'amount', '450.00', 'utr', 'S1', 'status', 'SUCCESS')));
  c := public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if pg_temp.st(b1) <> 'paid' then raise exception 'FAIL 4e: %', c; end if;
  if not exists (select 1 from public.audit_logs where action = 'platform_setting.set' and (after ->> 'key') = 'settlement_maker_checker') then raise exception 'FAIL 4f: setting change not audited'; end if;
  perform pg_temp.as_admin();
  perform public.admin_set_platform_setting('settlement_maker_checker', 'true'::jsonb);
  perform pg_temp.as_server();
end $$;

-- ---- 5. netting: partial recovery on a paid batch, zero-net batch ------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); v_rec uuid; b1 uuid; b2 uuid; r1 text; p jsonb; c jsonb;
begin
  perform pg_temp.sale('E10', 1, 'pay_E10'); perform pg_temp.board('E10');
  insert into public.operator_recovery (operator_id, earning_id, booking_item_id, amount_cents, reason)
    select v_a, e.id, e.booking_item_id, 10000, 'earlier clawback' from public.operator_earnings e limit 1 returning id into v_rec;
  perform pg_temp.as_admin();
  perform public.admin_build_weekly_settlement(current_date + 1);
  b1 := (select id from public.settlements where status = 'draft'); r1 := pg_temp.ref(b1);
  perform public.admin_approve_settlement(b1);
  perform public.admin_export_settlement_file(array[b1]);
  p := public.admin_preview_bank_result('net.csv', jsonb_build_array(jsonb_build_object('reference', r1, 'amount', '350.00', 'utr', 'N1', 'status', 'SUCCESS')));
  perform pg_temp.as_server();
  if (select net_payable_cents from public.settlements where id = b1) <> 35000 then raise exception 'FAIL 5a: expected 45000 - 10000 netted'; end if;
  perform pg_temp.as_admin2();
  perform public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if (select recovered_cents from public.operator_recovery where id = v_rec) <> 10000 or (select status from public.operator_recovery where id = v_rec) <> 'recovered' then raise exception 'FAIL 5b: recovery not applied'; end if;
  if pg_temp.bal('settlement_bank') <> -35000 or pg_temp.bal('operator_payable') <> 0 or pg_temp.bal('operator_receivable') <> -10000 then
    raise exception 'FAIL 5c: ledger (bank % payable % receivable %)', pg_temp.bal('settlement_bank'), pg_temp.bal('operator_payable'), pg_temp.bal('operator_receivable');
  end if;

  -- a recovery larger than the payable leaves a zero-net batch
  perform pg_temp.sale('E11', 2, 'pay_E11'); perform pg_temp.board('E11');
  update public.operator_recovery set amount_cents = 500000, recovered_cents = 0, status = 'open' where id = v_rec;
  perform pg_temp.as_admin();
  perform public.admin_build_weekly_settlement(current_date + 2);
  b2 := (select id from public.settlements where status = 'draft');
  perform public.admin_approve_settlement(b2);
  begin perform public.admin_export_settlement_file(array[b2]); raise exception 'FAIL 5d: zero-net batch exported';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'zero_net_batch%' then raise exception 'FAIL 5d2: %', sqlerrm; end if; end;
  begin perform public.admin_settle_zero_batch(b2, 'netting only'); raise exception 'FAIL 5e: the approver settled its own batch';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'maker_checker_violation%' then raise exception 'FAIL 5e2: %', sqlerrm; end if; end;
  perform pg_temp.as_admin2();
  begin perform public.admin_settle_zero_batch(b2, ' '); raise exception 'FAIL 5f: no reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.admin_settle_zero_batch(b2, 'recovery consumed the whole payable');
  perform pg_temp.as_server();
  if pg_temp.st(b2) <> 'paid' or (select txn_reference from public.settlements where id = b2) not like 'NETTING-%' then raise exception 'FAIL 5g'; end if;
  if (select recovered_cents from public.operator_recovery where id = v_rec) <> 45000 or pg_temp.bal('operator_payable') <> 0 then raise exception 'FAIL 5h: netting not applied (%)', (select recovered_cents from public.operator_recovery where id = v_rec); end if;
  if (select count(*) from public.settlement_payments where provider = 'internal') <> 1 then raise exception 'FAIL 5i'; end if;
end $$;

-- ---- 6. reconciliation: detect, never correct ---------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare b1 uuid; b2 uuid; x jsonb; r jsonb; v_exc uuid; v_a uuid := (select id from t_ops where tag = 'A');
begin
  b1 := pg_temp.ready_batch('E12', 1, 1); b2 := pg_temp.ready_batch('E13', 2, 2);
  perform pg_temp.as_admin();
  x := public.admin_export_settlement_file(array[b1]);
  perform pg_temp.as_server();

  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_run_reconciliation(); raise exception 'FAIL 6a: operator ran reconciliation';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_admin();
  r := public.admin_run_reconciliation();
  perform pg_temp.as_server();
  if (r ->> 'found')::int <> 0 then raise exception 'FAIL 6b: a healthy system must reconcile cleanly: %', r; end if;

  -- break things on purpose
  update public.settlements set exported_at = now() - interval '5 days' where id = b1;
  alter table public.settlement_exports disable trigger settlement_exports_immutable;
  update public.settlement_exports set content = content || 'tampered' where id = (x ->> 'export_id')::uuid;
  alter table public.settlement_exports enable trigger settlement_exports_immutable;
  perform private.post_journal('test:stray', 'test', jsonb_build_array(
    jsonb_build_object('account', 'booking_liability', 'side', 'debit', 'amount_cents', 700),
    jsonb_build_object('account', 'operator_payable', 'side', 'credit', 'amount_cents', 700, 'operator_id', v_a)));
  update public.settlements set status = 'paid', paid_cents = net_payable_cents, txn_reference = 'FAKE', completed_at = now() where id = b2;

  perform pg_temp.as_admin();
  r := public.admin_run_reconciliation();
  perform pg_temp.as_server();
  if (r -> 'summary' ->> 'bank_result_overdue')::int <> 1 or (r -> 'summary' ->> 'export_hash_mismatch')::int <> 1
     or (r -> 'summary' ->> 'operator_payable_mismatch')::int <> 1 or (r -> 'summary' ->> 'settlement_payment_mismatch')::int <> 1 then raise exception 'FAIL 6c: %', r; end if;
  -- nothing was changed to make it match
  if pg_temp.st(b1) <> 'exported' or pg_temp.st(b2) <> 'paid' or pg_temp.bal('operator_payable') <> 90700 then raise exception 'FAIL 6d: reconciliation edited financial records'; end if;
  perform pg_temp.as_admin();
  perform public.admin_run_reconciliation();                    -- repeat: no duplicates
  perform pg_temp.as_server();
  if (select count(*) from public.reconciliation_exceptions where kind = 'operator_payable_mismatch') <> 1 then raise exception 'FAIL 6e: duplicate exception'; end if;

  select id into v_exc from public.reconciliation_exceptions where kind = 'operator_payable_mismatch';
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_resolve_exception(v_exc, 'resolved', 'x'); raise exception 'FAIL 6f: support resolved an exception';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_admin(); perform public.admin_resolve_exception(v_exc, 'resolved', ' '); raise exception 'FAIL 6g: resolved without a note';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_admin();
  perform public.admin_resolve_exception(v_exc, 'ignored', 'known stray journal from a test');
  begin perform public.admin_resolve_exception(v_exc, 'resolved', 'again'); raise exception 'FAIL 6h: closed exception reopened';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  if not exists (select 1 from public.audit_logs where action = 'reconciliation.ignored' and entity_id = v_exc) then raise exception 'FAIL 6i: resolution not audited'; end if;
  if (select count(*) from public.reconciliation_runs) <> 3 then raise exception 'FAIL 6j: runs not recorded'; end if;
end $$;

rollback;
