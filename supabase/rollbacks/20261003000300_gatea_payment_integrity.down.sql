-- Rollback for 20261003000300_gatea_payment_integrity.sql
-- Restores the pre-Gate-A functions (captured from 20261002000200 / 20261002001700 /
-- 20261002000300 / 20260923002600 / 20261002001800) and drops the new objects.
-- Refund rows keep their data; live lifecycle states are folded back into the old
-- three-value model (requested/approved/submitted_to_provider -> pending, rejected -> failed).
-- Enum values added by 20261003000200 cannot be dropped and stay unused.

select cron.unschedule('detect-captured-unconfirmed');
drop function if exists private.detect_captured_unconfirmed();

drop function if exists public.admin_approve_refund(uuid);
drop function if exists public.admin_reject_refund(uuid, text);
drop function if exists public.admin_retry_refund(uuid);
drop function if exists public.admin_begin_refund_execution(uuid);
drop function if exists public.record_refund_provider_result(uuid, text, text, text, boolean);
drop function if exists public.fail_refund(text, uuid, text);
drop function if exists public.confirm_refund(text, text, uuid);
drop function if exists public.webhook_begin(text, text, jsonb);
drop function if exists public.webhook_finish(text, boolean, text);
drop function if exists public.am_i_full_admin();
drop function if exists public.record_exception(text, text, text, text, jsonb);
drop function if exists private.complete_refund(uuid, text);

drop trigger if exists refunds_guard_total on public.refunds;
drop trigger if exists refunds_normalize_status on public.refunds;
drop trigger if exists set_updated_at on public.refunds;
drop function if exists private.refund_guard_total();
drop function if exists private.refund_normalize_status();
alter table public.refunds drop constraint if exists refunds_no_legacy_pending_chk;
update public.refunds set status = 'pending' where status in ('requested', 'approved', 'submitted_to_provider');
update public.refunds set status = 'failed' where status = 'rejected';
alter table public.refunds alter column status set default 'pending';

drop table if exists public.reconciliation_exceptions;
drop function if exists private.raise_exception_record(text, text, text, text, jsonb);

alter table public.processed_webhook_events drop constraint if exists processed_webhook_events_status_chk;

-- old confirm_refund (idempotent version from 20260923002600)
create or replace function public.confirm_refund(p_razorpay_refund_id text, p_payment_id text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_payment public.payments; v_refund public.refunds;
begin
  select * into v_payment from public.payments where razorpay_payment_id = p_payment_id for update;
  if v_payment.id is null then raise exception 'Payment not found for razorpay_payment_id %', p_payment_id; end if;
  if exists (select 1 from public.refunds where payment_id = v_payment.id and razorpay_refund_id = p_razorpay_refund_id and status = 'processed') then return; end if;
  select * into v_refund from public.refunds where payment_id = v_payment.id and status = 'pending' order by created_at desc limit 1 for update;
  if v_refund.id is null then raise exception 'No pending refund found for payment %', p_payment_id; end if;
  update public.refunds set status = 'processed', razorpay_refund_id = p_razorpay_refund_id, processed_at = now() where id = v_refund.id;
  update public.payments set status = 'refunded' where id = v_payment.id;
  update public.orders set status = 'refunded' where id = v_payment.order_id;
end; $$;
revoke execute on function public.confirm_refund(text, text) from public, anon, authenticated;
grant execute on function public.confirm_refund(text, text) to service_role;

-- old handle_payment_failure (20261002001700)
drop function if exists public.handle_payment_failure(text, text, text);
create or replace function public.handle_payment_failure(p_order_reference text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_booking public.bookings; v_hold_ids uuid[];
begin
  select * into v_order from public.orders where order_reference = p_order_reference for update;
  if v_order.id is null then raise exception 'Order not found: %', p_order_reference; end if;
  if v_order.status in ('paid', 'refunded', 'failed', 'cancelled') then return; end if;
  update public.orders set status = 'failed' where id = v_order.id;
  if v_order.orderable_type = 'booking' then
    select * into v_booking from public.bookings where id = v_order.orderable_id for update;
    with mine as (
      select ts.id, ts.hold_id from public.booking_items bi
      join public.trip_seats ts on ts.id = bi.trip_seat_id
      join public.seat_holds sh on sh.id = ts.hold_id
      where bi.booking_id = v_booking.id and ts.status = 'held' and sh.user_id = v_booking.customer_id and sh.trip_id = ts.trip_id
      for update of ts
    ), freed as (
      update public.trip_seats ts set status = 'available', hold_id = null from mine m where ts.id = m.id returning m.hold_id
    )
    select array_agg(distinct hold_id) into v_hold_ids from freed;
    update public.bookings set status = 'failed' where id = v_booking.id and status = 'payment_pending';
    update public.booking_items set status = 'failed' where booking_id = v_booking.id and status = 'payment_pending';
    if v_hold_ids is not null then update public.seat_holds set status = 'expired' where id = any (v_hold_ids) and status = 'active'; end if;
    insert into public.booking_status_history (booking_id, from_status, to_status) values (v_booking.id, 'payment_pending', 'failed');
  elsif v_order.orderable_type = 'cargo_shipment' then
    update public.cargo_shipments set status = 'failed' where id = v_order.orderable_id;
  end if;
end; $$;
revoke execute on function public.handle_payment_failure(text) from public, anon, authenticated;
grant execute on function public.handle_payment_failure(text) to service_role;

-- NOTE: the previous confirm_booking_after_payment (3 args), cancel_booking and private.do_board
-- bodies are in migrations 20261002000200 / 20261002000300 / 20261002001800: re-run their
-- `create or replace function` statements to restore them, then drop the 5-arg overload:
drop function if exists public.confirm_booking_after_payment(text, text, integer, text, text);

-- restore the original refund filter in private.trip_financials
do $patch$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('private.trip_financials(uuid[])'::regprocedure);
  execute replace(v_def,
    $q$filter (where r.status in ('pending', 'requested', 'approved', 'submitted_to_provider'))$q$,
    $q$filter (where r.status = 'pending')$q$);
end
$patch$;
