-- =========================================================================
-- Support functions for Phase 5 (Razorpay Edge Functions):
--  - get_app_secret(): lets a service-role Edge Function read a secret out
--    of private.app_secrets without needing Deno environment variables
--    (there's no tool access to set Edge Function secrets for a hosted
--    project from here, so secrets are stored in the DB instead and locked
--    to service_role-only execute).
--  - am_i_platform_admin(): thin public wrapper so an Edge Function can
--    check the caller's admin status via RPC with the caller's own JWT,
--    without duplicating the private.is_platform_admin() logic.
--  - confirm_refund() made idempotent: the refund Edge Function calls it
--    optimistically right after a successful Razorpay refund call, and the
--    refund.processed webhook may also call it for the same refund later —
--    the second call must be a safe no-op, not an error.
-- =========================================================================

create or replace function public.get_app_secret(p_key text)
returns text
language sql
security definer
stable
set search_path = ''
as $$
  select value from private.app_secrets where key = p_key;
$$;

revoke execute on function public.get_app_secret(text) from public, anon, authenticated;
grant execute on function public.get_app_secret(text) to service_role;

create or replace function public.am_i_platform_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select private.is_platform_admin();
$$;

grant execute on function public.am_i_platform_admin() to authenticated;

create or replace function public.confirm_refund(
  p_razorpay_refund_id text,
  p_payment_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments;
  v_refund public.refunds;
begin
  select * into v_payment from public.payments where razorpay_payment_id = p_payment_id for update;
  if v_payment.id is null then
    raise exception 'Payment not found for razorpay_payment_id %', p_payment_id;
  end if;

  if exists (
    select 1 from public.refunds
    where payment_id = v_payment.id and razorpay_refund_id = p_razorpay_refund_id and status = 'processed'
  ) then
    return;
  end if;

  select * into v_refund from public.refunds
  where payment_id = v_payment.id and status = 'pending'
  order by created_at desc
  limit 1
  for update;

  if v_refund.id is null then
    raise exception 'No pending refund found for payment %', p_payment_id;
  end if;

  update public.refunds
  set status = 'processed', razorpay_refund_id = p_razorpay_refund_id, processed_at = now()
  where id = v_refund.id;

  update public.payments set status = 'refunded' where id = v_payment.id;
  update public.orders set status = 'refunded' where id = v_payment.order_id;
end;
$$;
