-- =========================================================================
-- Checks for Gate G part 1 (20261003001100_gateg_notifications_and_provider_settlement.sql)
--   * operator admins hear about payout profile, eligibility, settlement lifecycle, cancelled / recovered tickets
--   * customers hear about failed payments and the refund lifecycle
--   * one notification per event (replays never duplicate); staff and other operators are never notified
--   * notification text never contains amounts or bank details
--   * each user reads only their own notifications
--   * Razorpay -> bank settlements are booked once per Razorpay settlement id, full admin only
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

insert into auth.users (id, email) values
  ('77777777-0000-0000-0000-000000000007', 'support@test.invalid'),
  ('88888888-0000-0000-0000-000000000008', 'admin2@test.invalid'),
  ('99999999-0000-0000-0000-000000000009', 'staff@test.invalid');
insert into public.user_roles (user_id, role, operator_id) values
  ('77777777-0000-0000-0000-000000000007', 'platform_support', null),
  ('88888888-0000-0000-0000-000000000008', 'platform_admin', null),
  ('99999999-0000-0000-0000-000000000009', 'operator_staff', (select id from t_ops where tag = 'A')),
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'operator_admin', (select id from t_ops where tag = 'A')),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'operator_admin', (select id from t_ops where tag = 'B'))
on conflict do nothing;
insert into public.refund_policies (name, category, status, refund_bps, deduction_operator_share_bps, effective_from)
values ('test default', 'default', 'active', 8000, 2500, current_date - 1);
insert into public.operator_bank_details (operator_id, account_holder_name, bank_name, account_number, ifsc)
values ((select id from t_ops where tag = 'A'), 'Operator A', 'SBI', '123456789012', 'SBIN0001234')
on conflict (operator_id) do update set account_number = excluded.account_number, ifsc = excluded.ifsc, account_holder_name = excluded.account_holder_name;

create function pg_temp.as_admin() returns void language sql as $f$ select pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f') $f$;
create function pg_temp.as_admin2() returns void language sql as $f$ select pg_temp.as_user('88888888-0000-0000-0000-000000000008') $f$;
create function pg_temp.n(p_user text, p_type text) returns int language sql security definer as $f$
  select count(*)::int from public.notifications where profile_id = p_user::uuid and type = p_type
$f$;
create function pg_temp.sale(p_tag text, p_seat int, p_pay text) returns void language plpgsql as $f$
declare o public.orders;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', p_tag, p_seat);
  perform pg_temp.as_server();
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, p_pay, o.amount_cents, 'INR');
end $f$;
create function pg_temp.item_of(p_tag text) returns uuid language sql security definer as $f$
  select bi.id from public.booking_items bi join public.orders o on o.orderable_id = bi.booking_id where o.id = (select id from t_ref where tag = p_tag) limit 1
$f$;
create function pg_temp.board(p_tag text) returns void language plpgsql as $f$
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.verify_passenger_boarding(pg_temp.item_of(p_tag), true);
  perform public.confirm_boarding(pg_temp.item_of(p_tag));
  perform pg_temp.as_server();
end $f$;

-- ---- 1. payout profile ------------------------------------------------------------------------------------------
do $$
declare v_a uuid := (select id from t_ops where tag = 'A'); v_adm text := 'aaaaaaaa-0000-0000-0000-00000000000a';
begin
  perform pg_temp.as_admin();
  perform public.admin_set_commission(v_a, 1000);
  perform public.admin_set_payment_profile_status(v_a, 'failed', 'name mismatch');
  perform public.admin_set_payment_profile_status(v_a, 'verified', null);
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_payment_profile_failed') <> 1 or pg_temp.n(v_adm, 'operator_payment_profile_verified') <> 1 then raise exception 'FAIL 1a: profile notifications'; end if;
  if pg_temp.n('99999999-0000-0000-0000-000000000009', 'operator_payment_profile_verified') <> 0 then raise exception 'FAIL 1b: staff was notified about finance'; end if;
  if pg_temp.n('bbbbbbbb-0000-0000-0000-00000000000b', 'operator_payment_profile_verified') <> 0 then raise exception 'FAIL 1c: another operator was notified'; end if;
  -- the same event again does not duplicate
  perform pg_temp.as_admin();
  perform public.admin_set_payment_profile_status(v_a, 'verified', null);
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_payment_profile_verified') <> 1 then raise exception 'FAIL 1d: duplicate notification'; end if;
end $$;

-- ---- 2. earnings eligible (one per trip per day) + settlement lifecycle ---------------------------------------------------
do $$
declare v_adm text := 'aaaaaaaa-0000-0000-0000-00000000000a'; b1 uuid; r text; p jsonb;
begin
  perform pg_temp.sale('G1', 1, 'pay_g1'); perform pg_temp.sale('G2', 2, 'pay_g2');
  perform pg_temp.board('G1'); perform pg_temp.board('G2');
  if pg_temp.n(v_adm, 'operator_earning_eligible') <> 1 then raise exception 'FAIL 2a: eligibility must notify once per trip per day, got %', pg_temp.n(v_adm, 'operator_earning_eligible'); end if;

  perform pg_temp.as_admin();
  perform public.admin_build_weekly_settlement(current_date + 1);
  select id, reference into b1, r from public.settlements where status = 'draft';
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_settlement_approved') <> 0 then raise exception 'FAIL 2b: a draft must not notify the operator'; end if;

  perform pg_temp.as_admin();
  perform public.admin_approve_settlement(b1);
  perform public.admin_hold_settlement(b1, 'review');
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_settlement_approved') <> 1 or pg_temp.n(v_adm, 'operator_settlement_on_hold') <> 1 then raise exception 'FAIL 2c: approve / hold notifications'; end if;
  perform pg_temp.as_admin();
  perform public.admin_release_settlement_hold(b1);
  perform public.admin_cancel_settlement(b1, 'rebuild');
  perform public.admin_build_weekly_settlement(current_date + 2);
  select id, reference into b1, r from public.settlements where status = 'draft';
  perform public.admin_approve_settlement(b1);
  perform public.admin_export_settlement_file(array[b1]);
  p := public.admin_preview_bank_result('r.csv', jsonb_build_array(jsonb_build_object('reference', r, 'amount', '900.00', 'utr', 'G-UTR-1', 'status', 'SUCCESS')));
  perform pg_temp.as_admin2();
  perform public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_payout_processing') <> 1 or pg_temp.n(v_adm, 'operator_payout_paid') <> 1 then raise exception 'FAIL 2d: processing / paid notifications (% / %)', pg_temp.n(v_adm, 'operator_payout_processing'), pg_temp.n(v_adm, 'operator_payout_paid'); end if;
  if pg_temp.n('bbbbbbbb-0000-0000-0000-00000000000b', 'operator_payout_paid') <> 0 then raise exception 'FAIL 2e'; end if;
  if (select body from public.notifications where profile_id = v_adm::uuid and type = 'operator_payout_paid') not like '%' || r || '%' then raise exception 'FAIL 2f: the settlement reference should be in the text'; end if;

  -- a rejected bank payment
  perform pg_temp.sale('G3', 3, 'pay_g3'); perform pg_temp.board('G3');
  perform pg_temp.as_admin();
  perform public.admin_build_weekly_settlement(current_date + 3);
  select id, reference into b1, r from public.settlements where status = 'draft';
  perform public.admin_approve_settlement(b1);
  perform public.admin_export_settlement_file(array[b1]);
  p := public.admin_preview_bank_result('f.csv', jsonb_build_array(jsonb_build_object('reference', r, 'amount', '450.00', 'status', 'REJECTED', 'failure_reason', 'bad IFSC')));
  perform pg_temp.as_admin2();
  perform public.admin_confirm_bank_result((p ->> 'import_id')::uuid);
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_payout_failed') <> 1 then raise exception 'FAIL 2g: failed payout notification'; end if;
end $$;

-- ---- 3. cancelled / recovered tickets -------------------------------------------------------------------------------------
do $$
declare v_adm text := 'aaaaaaaa-0000-0000-0000-00000000000a'; v_b1 uuid; v_e uuid;
begin
  -- G1/G2 are settled by the paid batch above? use fresh tickets for clarity
  update public.trip_seats set status = 'available', hold_id = null where seat_id = (select seat_id from public.trip_seats where trip_id = (select id from t_ref where tag = 'TRIP') order by seat_id offset 3 limit 1);
  perform pg_temp.sale('G4', 4, 'pay_g4');
  perform pg_temp.board('G4');
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking((select orderable_id from public.orders where id = (select id from t_ref where tag = 'G4')), 'x');
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_ticket_cancelled') <> 1 then raise exception 'FAIL 3a: cancelling an eligible ticket must notify the operator'; end if;

  -- a ticket that was never boarded: no operator noise
  update public.trip_seats set status = 'available', hold_id = null where seat_id = (select seat_id from public.trip_seats where trip_id = (select id from t_ref where tag = 'TRIP') order by seat_id offset 3 limit 1);
  perform pg_temp.sale('G5', 4, 'pay_g5');
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking((select orderable_id from public.orders where id = (select id from t_ref where tag = 'G5')), 'x');
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_ticket_cancelled') <> 1 then raise exception 'FAIL 3b: an unboarded cancellation must not notify the operator'; end if;

  -- a ticket cancelled after it was paid out
  update public.trip_seats set status = 'available', hold_id = null where seat_id = (select seat_id from public.trip_seats where trip_id = (select id from t_ref where tag = 'TRIP') order by seat_id offset 3 limit 1);
  perform pg_temp.sale('G6', 4, 'pay_g6'); perform pg_temp.board('G6');
  update public.operator_earnings set status = 'settled' where booking_item_id = pg_temp.item_of('G6');
  perform pg_temp.as_admin();
  perform public.cancel_booking((select orderable_id from public.orders where id = (select id from t_ref where tag = 'G6')), 'refund after payout');
  perform pg_temp.as_server();
  if pg_temp.n(v_adm, 'operator_ticket_recovered') <> 1 then raise exception 'FAIL 3c: recovery notification'; end if;
end $$;

-- ---- 4. customer: failed payment + refund lifecycle ---------------------------------------------------------------------------
do $$
declare v_c text := 'dddddddd-0000-0000-0000-00000000000d'; o public.orders; r public.refunds; v_ref text; v_req0 int;
begin
  update public.trip_seats set status = 'available', hold_id = null where seat_id = (select seat_id from public.trip_seats where trip_id = (select id from t_ref where tag = 'TRIP') order by seat_id offset 3 limit 1);
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'G7', 4);
  perform pg_temp.as_server();
  select * into o from public.orders where id = (select id from t_ref where tag = 'G7');
  perform public.handle_payment_failure(o.order_reference, 'pay_g7_failed', 'declined');
  perform public.handle_payment_failure(o.order_reference, 'pay_g7_failed', 'declined');
  if pg_temp.n(v_c, 'payment_failed') <> 1 then raise exception 'FAIL 4a: failed payment notification (%)', pg_temp.n(v_c, 'payment_failed'); end if;
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_g7', o.amount_cents, 'INR');

  v_req0 := pg_temp.n(v_c, 'refund_requested');
  perform pg_temp.as_user(v_c::uuid);
  perform public.cancel_booking(o.orderable_id, 'plans changed');
  perform pg_temp.as_server();
  select r2.* into r from public.refunds r2 join public.payments p on p.id = r2.payment_id where p.razorpay_payment_id = 'pay_g7';
  if pg_temp.n(v_c, 'refund_requested') <> v_req0 + 1 then raise exception 'FAIL 4b: refund requested notification'; end if;
  perform pg_temp.as_admin();
  perform public.admin_approve_refund(r.id);
  perform public.admin_begin_refund_execution(r.id);
  perform pg_temp.as_server();
  perform public.record_refund_provider_result(r.id, 'rfnd_g7', 'pending');
  if pg_temp.n(v_c, 'refund_approved') <> 1 or pg_temp.n(v_c, 'refund_completed') <> 0 then raise exception 'FAIL 4c: approved yes, completed not until the provider confirms'; end if;
  perform public.confirm_refund('rfnd_g7', 'pay_g7', r.id);
  perform public.confirm_refund('rfnd_g7', 'pay_g7', r.id);
  if pg_temp.n(v_c, 'refund_completed') <> 1 then raise exception 'FAIL 4d: completed notification (replayed webhook must not duplicate)'; end if;

  -- declined refund
  update public.trip_seats set status = 'available', hold_id = null where seat_id = (select seat_id from public.trip_seats where trip_id = (select id from t_ref where tag = 'TRIP') order by seat_id offset 3 limit 1);
  perform pg_temp.sale('G8', 4, 'pay_g8');
  perform pg_temp.as_user(v_c::uuid);
  perform public.cancel_booking((select orderable_id from public.orders where id = (select id from t_ref where tag = 'G8')), 'x');
  perform pg_temp.as_admin();
  perform public.admin_reject_refund((select r3.id from public.refunds r3 join public.payments p on p.id = r3.payment_id where p.razorpay_payment_id = 'pay_g8'), 'not eligible');
  perform pg_temp.as_server();
  if pg_temp.n(v_c, 'refund_rejected') <> 1 then raise exception 'FAIL 4e: declined notification'; end if;
  if pg_temp.n('eeeeeeee-0000-0000-0000-00000000000e', 'refund_requested') <> 0 then raise exception 'FAIL 4f: another customer was notified'; end if;
end $$;

-- ---- 5. no money or bank details in any text; own-notifications only --------------------------------------------------------------
do $$
declare bad int;
begin
  select count(*) into bad from public.notifications
   where (title || ' ' || coalesce(body, '')) ~ '(₹|INR|paise|rupee|\mRs\M|123456789012|SBIN0001234|XXXX)'
     and type in (select key from public.notification_templates where key like 'operator\_%' or key like 'refund\_%' or key = 'payment_failed');
  if bad <> 0 then raise exception 'FAIL 5a: % notification(s) contain an amount or bank detail: %', bad, (select string_agg(title || ' / ' || body, ' | ') from public.notifications where (title || ' ' || coalesce(body, '')) ~ '(₹|INR|paise|rupee|\mRs\M|123456789012|SBIN0001234|XXXX)'); end if;

  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  if exists (select 1 from public.notifications where profile_id <> 'dddddddd-0000-0000-0000-00000000000d') then raise exception 'FAIL 5b: customer reads others'' notifications'; end if;
  if not exists (select 1 from public.notifications) then raise exception 'FAIL 5c: customer cannot read own'; end if;
  begin insert into public.notifications (profile_id, title) values ('dddddddd-0000-0000-0000-00000000000d', 'fake'); raise exception 'FAIL 5d: client inserted a notification';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if exists (select 1 from public.notifications where profile_id <> 'aaaaaaaa-0000-0000-0000-00000000000a') then raise exception 'FAIL 5e: operator reads others'' notifications'; end if;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  if exists (select 1 from public.notifications where type like 'operator\_%') then raise exception 'FAIL 5f: operator B sees operator A notifications'; end if;
  perform pg_temp.as_server();
end $$;

-- ---- 6. Razorpay -> bank settlement -----------------------------------------------------------------------------------------------
do $$
declare v_id uuid; v_id2 uuid; v_clear bigint; v_bank bigint;
begin
  select coalesce(sum(balance_cents), 0) into v_clear from public.ledger_account_balances where account_code = 'razorpay_clearing';
  select coalesce(sum(balance_cents), 0) into v_bank from public.ledger_account_balances where account_code = 'settlement_bank';

  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_record_provider_settlement('setl_1', 100000, current_date); raise exception 'FAIL 6a: support booked a settlement';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_record_provider_settlement('setl_1', 100000, current_date); raise exception 'FAIL 6b: operator booked a settlement';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_admin();
  begin perform public.admin_record_provider_settlement(' ', 100, current_date); raise exception 'FAIL 6c: blank reference';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_record_provider_settlement('setl_x', 0, current_date); raise exception 'FAIL 6d: zero amount';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  v_id := public.admin_record_provider_settlement('setl_1', 100000, current_date, 'weekly Razorpay settlement');
  v_id2 := public.admin_record_provider_settlement('setl_1', 100000, current_date);          -- same settlement again: no-op
  begin perform public.admin_record_provider_settlement('setl_1', 99999, current_date); raise exception 'FAIL 6e: same id, different amount';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  if v_id <> v_id2 or (select count(*) from public.provider_settlements) <> 1 or (select count(*) from public.ledger_journals where event_type = 'provider_settlement') <> 1 then raise exception 'FAIL 6f: duplicate booking'; end if;
  if (select coalesce(sum(balance_cents), 0) from public.ledger_account_balances where account_code = 'settlement_bank') <> v_bank + 100000
     or (select coalesce(sum(balance_cents), 0) from public.ledger_account_balances where account_code = 'razorpay_clearing') <> v_clear - 100000 then raise exception 'FAIL 6g: ledger effect'; end if;
  if not exists (select 1 from public.audit_logs where action = 'provider_settlement.record' and entity_id = v_id) then raise exception 'FAIL 6h: not audited'; end if;
end $$;

rollback;
