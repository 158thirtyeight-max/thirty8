-- =========================================================================
-- Gate F: read models for the admin Finance & Settlements pages (all aggregation in SQL, never in JavaScript)
--   admin_finance_dashboard   headline figures
--   admin_list_payment_profiles   operators' payout profiles with MASKED bank details
--   admin_list_refunds        refund requests with booking / customer / operator / trip / policy / calculation
-- Platform admins can read (support included); every write stays in the full-admin RPCs of earlier gates.
-- Reversible: supabase/rollbacks/20261003000900_gatef_admin_reads.down.sql
-- =========================================================================

create or replace function public.admin_finance_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  if not private.is_platform_admin() then raise exception 'not_authorized' using errcode = '42501'; end if;
  select jsonb_build_object(
    'collected_cents', (select coalesce(sum(amount_cents), 0) from public.payments where status in ('captured', 'refunded')),
    'refunded_cents', (select coalesce(sum(amount_cents), 0) from public.refunds where status = 'processed'),
    'gross_revenue_cents', (select coalesce(sum(gross_cents), 0) from public.operator_earnings where status not in ('void', 'clawed_back')),
    'commission_cents', (select coalesce(sum(commission_cents), 0) from public.operator_earnings where status not in ('void', 'clawed_back')),
    'operator_net_cents', (select coalesce(sum(operator_net_cents), 0) from public.operator_earnings where status not in ('void', 'clawed_back')),
    'operator_payable_cents', (select coalesce(sum(case when e.side = 'credit' then e.amount_cents else -e.amount_cents end), 0)
                                 from public.ledger_entries e join public.ledger_accounts a on a.id = e.account_id where a.code = 'operator_payable'),
    'pending_boarding_cents', (select coalesce(sum(coalesce(operator_net_cents, gross_cents)), 0) from public.operator_earnings where status = 'pending_boarding'),
    'eligible_cents', (select coalesce(sum(operator_net_cents), 0) from public.operator_earnings where status = 'eligible'),
    'on_hold_cents', (select coalesce(sum(coalesce(operator_net_cents, gross_cents)), 0) from public.operator_earnings where status = 'on_hold'),
    'pending_settlement_cents', (select coalesce(sum(net_payable_cents), 0) from public.settlements where status in ('draft', 'approved', 'on_hold', 'exported', 'partially_paid')),
    'settled_cents', (select coalesce(sum(paid_cents), 0) from public.settlements where status = 'paid'),
    'cancellation_income_cents', (select coalesce(sum(case when e.side = 'credit' then e.amount_cents else -e.amount_cents end), 0)
                                    from public.ledger_entries e join public.ledger_accounts a on a.id = e.account_id where a.code = 'cancellation_income'),
    'outstanding_recovery_cents', (select coalesce(sum(amount_cents - recovered_cents), 0) from public.operator_recovery where status in ('open', 'partially_recovered')),
    'batches_awaiting_approval', (select count(*) from public.settlements where status = 'draft'),
    'batches_awaiting_export', (select count(*) from public.settlements where status = 'approved'),
    'batches_awaiting_bank_result', (select count(*) from public.settlements where status = 'exported'),
    'failed_batches', (select count(*) from public.settlements where status = 'failed'),
    'refunds_pending_approval', (select count(*) from public.refunds where status = 'requested'),
    'failed_refunds', (select count(*) from public.refunds where status = 'failed'),
    'open_exceptions', (select count(*) from public.reconciliation_exceptions where status = 'open'),
    'critical_exceptions', (select count(*) from public.reconciliation_exceptions where status = 'open' and severity = 'critical')
  ) into v;
  return v;
end;
$$;

create or replace function public.admin_list_payment_profiles()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'not_authorized' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'operator_id', o.id, 'operator_name', o.name, 'operator_status', o.status,
      'verification_status', coalesce(p.verification_status, 'unverified'), 'verified_at', p.verified_at,
      'verification_note', p.verification_note, 'payout_hold', coalesce(p.payout_hold, false), 'restriction_reason', p.restriction_reason,
      'block_reason', private.payout_block_reason(o.id),
      'bank_name', b.bank_name, 'account_holder', b.account_holder_name,
      'account_masked', case when b.account_number is null then null else repeat('X', greatest(length(b.account_number) - 4, 0)) || right(b.account_number, 4) end,
      'ifsc_masked', case when b.ifsc is null then null else left(b.ifsc, 4) || '*******' end,
      'has_bank_details', b.operator_id is not null and b.account_number is not null and b.ifsc is not null) order by o.name)
    from public.operators o
    left join public.operator_payment_profiles p on p.operator_id = o.id
    left join public.operator_bank_details b on b.operator_id = o.id), '[]'::jsonb);
end;
$$;

create or replace function public.admin_list_refunds(p_status text default null, p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'not_authorized' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(x order by x.requested_at desc) from (
      select r.id as refund_id, r.status, r.reason, r.reason_category, r.created_at as requested_at, r.processed_at,
             r.failure_reason, r.rejection_reason, r.retry_count, r.razorpay_refund_id,
             r.requested_cents as original_amount_cents, r.amount_cents as refund_cents, r.calc_deduction_cents as deduction_cents,
             r.calc_source, r.policy_id, pol.name as policy_name, r.policy_version, r.policy_refund_bps,
             r.calc_operator_share_cents as operator_share_cents,
             exists (select 1 from public.refund_overrides ov where ov.refund_id = r.id) as overridden,
             p.status as payment_status, p.razorpay_payment_id, p.refunded_cents as payment_refunded_cents, p.amount_cents as payment_amount_cents,
             b.id as booking_id, b.booking_reference,
             (select count(*) from public.booking_items bi where bi.booking_id = b.id) as ticket_count,
             (select (array_agg(bi.id order by bi.created_at))[1] from public.booking_items bi where bi.booking_id = b.id) as first_ticket_id,
             c.full_name as customer_name, coalesce(b.contact_email, c.email) as customer_email, coalesce(b.contact_phone, c.phone) as customer_phone,
             op.name as operator_name, t.departure_at, svc.service_name as trip_label,
             ap.full_name as approved_by_name, ex.full_name as executed_by_name
      from public.refunds r
      join public.payments p on p.id = r.payment_id
      join public.orders o on o.id = p.order_id
      left join public.bookings b on o.orderable_type = 'booking' and b.id = o.orderable_id
      left join public.profiles c on c.id = o.customer_id
      left join public.refund_policies pol on pol.id = r.policy_id
      left join public.operators op on op.id = private.refund_operator(r.id)
      left join lateral (select t2.* from public.booking_items bi join public.bus_trips t2 on t2.id = bi.trip_id
                          where bi.booking_id = b.id order by t2.departure_at limit 1) t on true
      left join public.bus_services svc on svc.id = t.service_id
      left join public.profiles ap on ap.id = r.approved_by
      left join public.profiles ex on ex.id = r.executed_by
      where p_status is null or r.status::text = p_status
      order by r.created_at desc
      limit greatest(least(coalesce(p_limit, 100), 500), 1)) x), '[]'::jsonb);
end;
$$;

revoke execute on function public.admin_finance_dashboard(), public.admin_list_payment_profiles(), public.admin_list_refunds(text, integer) from public, anon;
grant execute on function public.admin_finance_dashboard(), public.admin_list_payment_profiles(), public.admin_list_refunds(text, integer) to authenticated;
