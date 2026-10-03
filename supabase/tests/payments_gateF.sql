-- =========================================================================
-- Checks for Gate F read models (20261003000900_gatef_admin_reads.sql)
--   * platform admins (support too) can read; operators / customers cannot
--   * dashboard figures come from SQL and agree with the underlying records
--   * payout profiles are listed with masked bank details only
--   * refund list carries booking / customer / operator / trip / policy / calculation fields
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

insert into auth.users (id, email) values ('77777777-0000-0000-0000-000000000007', 'support@test.invalid');
insert into public.user_roles (user_id, role) values ('77777777-0000-0000-0000-000000000007', 'platform_support');
insert into public.refund_policies (name, category, status, refund_bps, deduction_operator_share_bps, effective_from)
values ('Standard cancellation', 'default', 'active', 8000, 2500, current_date - 1);
insert into public.operator_bank_details (operator_id, account_holder_name, bank_name, account_number, ifsc)
values ((select id from t_ops where tag = 'A'), 'Operator A', 'SBI', '123456789012', 'SBIN0001234')
on conflict (operator_id) do update set account_number = excluded.account_number, ifsc = excluded.ifsc, account_holder_name = excluded.account_holder_name;

create function pg_temp.as_admin() returns void language sql as $f$ select pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f') $f$;

do $$
declare d jsonb; l jsonb; p jsonb; o public.orders; v_booking uuid;
begin
  -- access control
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_finance_dashboard(); raise exception 'FAIL 1a: operator read the finance dashboard';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.admin_list_refunds(); raise exception 'FAIL 1b: customer listed refunds';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_list_payment_profiles(); raise exception 'FAIL 1c: operator listed payout profiles';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('77777777-0000-0000-0000-000000000007');
  perform public.admin_finance_dashboard();           -- support may read
  perform pg_temp.as_server();

  perform pg_temp.as_admin();
  perform public.admin_set_commission((select id from t_ops where tag = 'A'), 1000);
  perform public.admin_set_payment_profile_status((select id from t_ops where tag = 'A'), 'verified', null);
  perform pg_temp.as_server();

  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'F1', 1);
  perform pg_temp.as_server();
  select * into o from public.orders where id = (select id from t_ref where tag = 'F1');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_f1', o.amount_cents, 'INR');
  v_booking := o.orderable_id;

  perform pg_temp.as_admin();
  d := public.admin_finance_dashboard();
  if (d ->> 'collected_cents')::bigint <> 50000 or (d ->> 'gross_revenue_cents')::bigint <> 50000 or (d ->> 'commission_cents')::bigint <> 5000
     or (d ->> 'pending_boarding_cents')::bigint <> 45000 or (d ->> 'eligible_cents')::bigint <> 0 then raise exception 'FAIL 2a: before boarding %', d; end if;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.verify_passenger_boarding((select id from public.booking_items where booking_id = v_booking), true);
  perform public.confirm_boarding((select id from public.booking_items where booking_id = v_booking));
  perform pg_temp.as_admin();
  d := public.admin_finance_dashboard();
  if (d ->> 'eligible_cents')::bigint <> 45000 or (d ->> 'operator_payable_cents')::bigint <> 45000 or (d ->> 'pending_settlement_cents')::bigint <> 0 then raise exception 'FAIL 2b: after boarding %', d; end if;

  perform public.admin_build_weekly_settlement(current_date + 1);
  d := public.admin_finance_dashboard();
  if (d ->> 'pending_settlement_cents')::bigint <> 45000 or (d ->> 'batches_awaiting_approval')::int <> 1 or (d ->> 'eligible_cents')::bigint <> 0 then raise exception 'FAIL 2c: after build %', d; end if;

  -- payout profiles: masked only
  p := public.admin_list_payment_profiles();
  if p::text like '%123456789012%' then raise exception 'FAIL 3a: full account number leaked'; end if;
  if (select e ->> 'account_masked' from jsonb_array_elements(p) e where e ->> 'operator_name' = (select name from public.operators where id = (select id from t_ops where tag = 'A'))) <> 'XXXXXXXX9012' then raise exception 'FAIL 3b: %', p; end if;
  if (select e ->> 'verification_status' from jsonb_array_elements(p) e where (e ->> 'operator_id')::uuid = (select id from t_ops where tag = 'A')) <> 'verified' then raise exception 'FAIL 3c'; end if;

  -- the operator's settlement detail carries the new engine's fields once the batch is approved
  perform public.admin_approve_settlement((select id from public.settlements where status = 'draft'));
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  d := public.get_settlement_detail((select id from public.settlements where status = 'approved'));
  if d ->> 'status' <> 'approved' or (d ->> 'adjustment_credits_cents')::bigint <> 0 or (d ->> 'recovery_netted_cents')::bigint <> 0
     or d ->> 'approved_at' is null or d ->> 'exported_at' is not null or d ->> 'bank_paid_at' is not null or (d ->> 'net_payable_cents')::bigint <> 45000 then
    raise exception 'FAIL 3d: operator settlement detail %', d;
  end if;
  perform pg_temp.as_admin();

  -- refund list
  -- a second ticket (not boarded, so not in the batch) is cancelled by its customer
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'F2', 2);
  perform pg_temp.as_server();
  select * into o from public.orders where id = (select id from t_ref where tag = 'F2');
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_f2', o.amount_cents, 'INR');
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking(o.orderable_id, 'plans changed');
  perform pg_temp.as_admin();
  l := public.admin_list_refunds();
  if jsonb_array_length(l) <> 1 then raise exception 'FAIL 4a: %', l; end if;
  if l -> 0 ->> 'status' <> 'requested' or l -> 0 ->> 'booking_reference' is null or (l -> 0 ->> 'original_amount_cents')::bigint <> 50000
     or l -> 0 ->> 'operator_name' is null or l -> 0 ->> 'reason_category' <> 'passenger_cancellation' or l -> 0 ->> 'razorpay_payment_id' <> 'pay_f2' or l -> 0 ->> 'first_ticket_id' is null then
    raise exception 'FAIL 4b: %', l -> 0;
  end if;
  perform public.admin_approve_refund((l -> 0 ->> 'refund_id')::uuid);
  l := public.admin_list_refunds('approved');
  if jsonb_array_length(l) <> 1 or l -> 0 ->> 'policy_name' <> 'Standard cancellation' or (l -> 0 ->> 'refund_cents')::bigint <> 40000
     or (l -> 0 ->> 'deduction_cents')::bigint <> 10000 or (l -> 0 ->> 'policy_refund_bps')::int <> 8000 then raise exception 'FAIL 4c: %', l; end if;
  if jsonb_array_length(public.admin_list_refunds('failed')) <> 0 then raise exception 'FAIL 4d: status filter'; end if;
  d := public.admin_finance_dashboard();
  if (d ->> 'refunds_pending_approval')::int <> 0 then raise exception 'FAIL 4e'; end if;
  perform pg_temp.as_server();
end $$;

rollback;
