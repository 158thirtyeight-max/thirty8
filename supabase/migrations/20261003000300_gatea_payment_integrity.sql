-- =========================================================================
-- Gate A (payment integrity), step 2/2
--
--  1. Refund lifecycle   requested -> approved -> submitted_to_provider -> processed | failed (+ rejected)
--     * a cancellation / unapplied payment only ever creates a `requested` refund;
--       nothing moves money without a full-admin approval and an explicit execution
--     * "accepted by Razorpay" is not completion: only a provider-confirmed
--       `processed` (webhook or verified API read) completes a refund
--     * over-refunding a payment is blocked in the database
--     * payments.refunded_cents tracks partial refunds; payment/order are only
--       marked `refunded` when the payment is fully refunded
--  2. Captured payment is the source of truth
--     * confirm_booking_after_payment takes the provider's captured amount AND
--       currency, is idempotent per payment id, and records a duplicate capture
--       (a second real payment for an already-paid order) instead of ignoring it
--     * a detector raises an exception row for captured payments whose booking is
--       still not confirmed (never auto-corrected)
--  3. handle_payment_failure no longer fails the order / frees seats on the first
--     failed attempt: it records the attempt and leaves the order retryable; the
--     existing hold-expiry and stale-booking jobs release the seats.
--  4. Webhook registry: claim/finish RPCs (idempotent, retry-aware) + payload,
--     status, attempts, last_error.
--  5. QR boarding requires a captured payment (like manual verification).
--  6. reconciliation_exceptions queue (extended in Gate E).
--
-- Reversible: supabase/rollbacks/20261003000300_gatea_payment_integrity.down.sql
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. columns
-- ---------------------------------------------------------------------
alter table public.payments
  add column if not exists currency_code text not null default 'INR',
  add column if not exists failure_reason text,
  add column if not exists provider_status text,
  add column if not exists refunded_cents integer not null default 0 check (refunded_cents >= 0);

alter table public.refunds
  add column if not exists requested_by uuid references public.profiles (id),
  add column if not exists approved_by uuid references public.profiles (id),
  add column if not exists approved_at timestamptz,
  add column if not exists rejected_by uuid references public.profiles (id),
  add column if not exists rejected_at timestamptz,
  add column if not exists rejection_reason text,
  add column if not exists executed_by uuid references public.profiles (id),
  add column if not exists submitted_at timestamptz,
  add column if not exists failure_reason text,
  add column if not exists retry_count integer not null default 0,
  add column if not exists idempotency_key uuid not null default gen_random_uuid(),
  add column if not exists updated_at timestamptz not null default now();

create unique index if not exists refunds_idempotency_key_idx on public.refunds (idempotency_key);

alter table public.processed_webhook_events
  add column if not exists payload jsonb,
  add column if not exists signature_valid boolean not null default true,
  add column if not exists status text not null default 'processed',
  add column if not exists attempts integer not null default 1,
  add column if not exists last_error text,
  add column if not exists received_at timestamptz not null default now(),
  add column if not exists last_attempt_at timestamptz not null default now();

alter table public.processed_webhook_events
  add constraint processed_webhook_events_status_chk check (status in ('processing', 'processed', 'failed'));

-- legacy rows: pending -> requested; no row may remain `pending`
alter table public.refunds alter column status set default 'requested';
update public.refunds set status = 'requested' where status = 'pending';
alter table public.refunds add constraint refunds_no_legacy_pending_chk check (status <> 'pending');

update public.payments p
   set refunded_cents = coalesce((select sum(r.amount_cents) from public.refunds r where r.payment_id = p.id and r.status = 'processed'), 0);

create trigger set_updated_at before update on public.refunds
  for each row execute function private.set_updated_at();

-- older SQL (cargo refunds, etc.) may still insert `pending`: that means `requested`
create or replace function private.refund_normalize_status()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'pending' then new.status := 'requested'; end if;
  return new;
end;
$$;
create trigger refunds_normalize_status before insert or update of status on public.refunds
  for each row execute function private.refund_normalize_status();

-- never refund more than was paid (live refunds + processed ones count)
create or replace function private.refund_guard_total()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_paid integer;
  v_other bigint;
begin
  if new.status not in ('requested', 'approved', 'submitted_to_provider', 'processed') then
    return new;
  end if;
  select amount_cents into v_paid from public.payments where id = new.payment_id for update;
  select coalesce(sum(amount_cents), 0) into v_other
    from public.refunds
   where payment_id = new.payment_id
     and id is distinct from new.id
     and status in ('requested', 'approved', 'submitted_to_provider', 'processed');
  if v_other + new.amount_cents > v_paid then
    raise exception 'refund_exceeds_payment: % already refunded/requested of % paid, cannot add %',
      v_other, v_paid, new.amount_cents using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger refunds_guard_total before insert or update of amount_cents, status on public.refunds
  for each row execute function private.refund_guard_total();

-- ---------------------------------------------------------------------
-- 2. exception queue (never auto-corrected; admin resolves)
-- ---------------------------------------------------------------------
create table public.reconciliation_exceptions (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  severity text not null default 'warning' check (severity in ('info', 'warning', 'critical')),
  entity_type text not null,
  entity_id text not null,
  details jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in ('open', 'resolved', 'ignored')),
  detected_at timestamptz not null default now(),
  resolved_by uuid references public.profiles (id),
  resolved_at timestamptz,
  resolution_note text
);
create unique index reconciliation_exceptions_open_uniq
  on public.reconciliation_exceptions (kind, entity_type, entity_id) where status = 'open';
create index reconciliation_exceptions_status_idx on public.reconciliation_exceptions (status, detected_at desc);

alter table public.reconciliation_exceptions enable row level security;
revoke all on public.reconciliation_exceptions from anon, authenticated;
grant select on public.reconciliation_exceptions to authenticated;
create policy reconciliation_exceptions_admin_select on public.reconciliation_exceptions
  for select to authenticated using (private.is_platform_admin());

create or replace function private.raise_exception_record(
  p_kind text, p_severity text, p_entity_type text, p_entity_id text, p_details jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.reconciliation_exceptions (kind, severity, entity_type, entity_id, details)
  values (p_kind, p_severity, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb))
  on conflict (kind, entity_type, entity_id) where status = 'open' do nothing;
$$;
revoke execute on function private.raise_exception_record(text, text, text, text, jsonb) from public, anon, authenticated;


-- service-role wrapper so edge functions can queue an exception (e.g. webhook for an unknown order)
create or replace function public.record_exception(
  p_kind text, p_severity text, p_entity_type text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  select private.raise_exception_record(p_kind, p_severity, p_entity_type, p_entity_id, p_details);
$$;
revoke execute on function public.record_exception(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.record_exception(text, text, text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------
-- 3. confirm_booking_after_payment (captured amount + currency, duplicate capture)
-- ---------------------------------------------------------------------
drop function if exists public.confirm_booking_after_payment(text, text, integer);

create or replace function public.confirm_booking_after_payment(
  p_order_reference text,
  p_payment_id text,
  p_amount_cents integer,
  p_currency text default 'INR',
  p_method text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_order public.orders;
  v_booking public.bookings;
  v_payment_uuid uuid;
  v_reason text;
  v_bad integer;
begin
  select * into v_order from public.orders where order_reference = p_order_reference for update;
  if v_order.id is null then
    raise exception 'Order not found: %', p_order_reference;
  end if;

  if v_order.status in ('paid', 'refunded') then
    -- the same payment again: a plain replay
    if exists (select 1 from public.payments
                where order_id = v_order.id and razorpay_payment_id = p_payment_id) then
      return jsonb_build_object('already_processed', true);
    end if;
    -- a DIFFERENT real payment for an already-paid order: money was received twice.
    insert into public.payments (order_id, razorpay_payment_id, amount_cents, currency_code, method, status, captured_at)
    values (v_order.id, p_payment_id, p_amount_cents, upper(coalesce(p_currency, 'INR')), p_method, 'duplicate_captured', now())
    on conflict (razorpay_payment_id) do nothing
    returning id into v_payment_uuid;
    if v_payment_uuid is null then
      return jsonb_build_object('already_processed', true);
    end if;
    insert into public.refunds (payment_id, amount_cents, reason, status)
    values (v_payment_uuid, p_amount_cents, 'Duplicate capture for an already paid order', 'requested');
    perform private.raise_exception_record('duplicate_capture', 'critical', 'payment', p_payment_id,
      jsonb_build_object('order_reference', p_order_reference, 'amount_cents', p_amount_cents));
    return jsonb_build_object('order_id', v_order.id, 'status', 'duplicate_refund_pending');
  end if;

  -- The money is real whatever happens next, so the payment is always recorded
  -- (a previously failed attempt row for this payment id is upgraded).
  insert into public.payments (order_id, razorpay_payment_id, amount_cents, currency_code, method, status, captured_at)
  values (v_order.id, p_payment_id, p_amount_cents, upper(coalesce(p_currency, 'INR')), p_method, 'captured', now())
  on conflict (razorpay_payment_id) do update
    set status = 'captured', amount_cents = excluded.amount_cents, currency_code = excluded.currency_code,
        method = coalesce(excluded.method, public.payments.method), captured_at = now(), failure_reason = null
    where public.payments.status in ('pending', 'failed')
  returning id into v_payment_uuid;
  if v_payment_uuid is null then
    return jsonb_build_object('already_processed', true);
  end if;

  update public.orders set status = 'paid' where id = v_order.id;

  -- Decide whether the paid order can still be fulfilled.
  if p_amount_cents is distinct from v_order.amount_cents then
    v_reason := format('amount_mismatch: paid %s, order %s', p_amount_cents, v_order.amount_cents);

  elsif upper(coalesce(p_currency, 'INR')) <> upper(v_order.currency_code) then
    v_reason := format('currency_mismatch: paid %s, order %s', p_currency, v_order.currency_code);

  elsif v_order.orderable_type = 'booking' then
    select * into v_booking from public.bookings where id = v_order.orderable_id for update;
    if v_booking.id is null then
      v_reason := 'booking_missing';
    elsif v_booking.status <> 'payment_pending' then
      v_reason := format('booking_not_pending: status is %s', v_booking.status);
    else
      perform 1
      from public.booking_items bi
      join public.trip_seats ts on ts.id = bi.trip_seat_id
      where bi.booking_id = v_booking.id
      for update of ts;

      select count(*) into v_bad
      from public.booking_items bi
      join public.trip_seats ts on ts.id = bi.trip_seat_id
      where bi.booking_id = v_booking.id
        and not (
          ts.status = 'available'
          or (ts.status = 'held' and exists (
                select 1 from public.seat_holds sh
                where sh.id = ts.hold_id
                  and sh.user_id = v_booking.customer_id
                  and sh.trip_id = bi.trip_id))
        );
      if v_bad > 0 then
        v_reason := format('seat_unavailable: %s seat(s) no longer available', v_bad);
      end if;
    end if;

  elsif v_order.orderable_type = 'cargo_shipment' then
    if not exists (select 1 from public.cargo_shipments where id = v_order.orderable_id and status = 'draft') then
      v_reason := 'shipment_not_draft';
    end if;
  end if;

  if v_reason is null then
    begin
      if v_order.orderable_type = 'booking' then
        update public.bookings set status = 'confirmed' where id = v_order.orderable_id;
        update public.booking_items set status = 'confirmed' where booking_id = v_order.orderable_id;

        update public.seat_holds sh
        set status = 'confirmed'
        where sh.id in (
          select ts.hold_id
          from public.booking_items bi
          join public.trip_seats ts on ts.id = bi.trip_seat_id
          where bi.booking_id = v_order.orderable_id and ts.hold_id is not null
        );

        update public.trip_seats ts
        set status = 'booked'
        from public.booking_items bi
        where bi.booking_id = v_order.orderable_id and bi.trip_seat_id = ts.id;

        update public.bus_trips t
        set available_seats = (select count(*) from public.trip_seats where trip_id = t.id and status = 'available')
        where t.id = (select trip_id from public.booking_items where booking_id = v_order.orderable_id limit 1);

        insert into public.booking_status_history (booking_id, from_status, to_status)
        values (v_order.orderable_id, 'payment_pending', 'confirmed');

      elsif v_order.orderable_type = 'cargo_shipment' then
        update public.cargo_shipments set status = 'confirmed' where id = v_order.orderable_id;
        insert into public.cargo_status_history (shipment_id, from_status, to_status)
        values (v_order.orderable_id, 'draft', 'confirmed');
      end if;
    exception when unique_violation then
      v_reason := 'seat_conflict: seat already confirmed for another booking';
    end;
  end if;

  if v_reason is not null then
    -- the customer paid and did not get the ticket: queue a refund request for the
    -- admin workflow (nothing is executed automatically) and flag it.
    insert into public.refunds (payment_id, amount_cents, reason, status)
    values (v_payment_uuid, p_amount_cents, 'Payment could not be applied: ' || v_reason, 'requested');
    perform private.raise_exception_record('captured_not_applied', 'critical', 'payment', p_payment_id,
      jsonb_build_object('order_reference', p_order_reference, 'reason', v_reason));

    return jsonb_build_object('order_id', v_order.id, 'status', 'refund_pending', 'reason', v_reason);
  end if;

  return jsonb_build_object('order_id', v_order.id, 'status', 'confirmed');
end;
$function$;

revoke execute on function public.confirm_booking_after_payment(text, text, integer, text, text) from public, anon, authenticated;
grant execute on function public.confirm_booking_after_payment(text, text, integer, text, text) to service_role;

-- ---------------------------------------------------------------------
-- 4. retry-safe payment failure
-- ---------------------------------------------------------------------
drop function if exists public.handle_payment_failure(text);

create or replace function public.handle_payment_failure(
  p_order_reference text,
  p_razorpay_payment_id text default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where order_reference = p_order_reference for update;
  if v_order.id is null then
    raise exception 'Order not found: %', p_order_reference;
  end if;

  -- stale event for an order that is already paid / refunded / closed
  if v_order.status in ('paid', 'refunded', 'failed', 'cancelled') then
    return;
  end if;

  -- Razorpay lets the customer retry the same order, so one failed attempt must
  -- not kill the order or free the seats. Record the attempt only; the hold-expiry
  -- and stale-booking jobs release the seats if the customer never succeeds.
  if p_razorpay_payment_id is not null then
    insert into public.payments (order_id, razorpay_payment_id, amount_cents, currency_code, status, failure_reason)
    values (v_order.id, p_razorpay_payment_id, v_order.amount_cents, v_order.currency_code, 'failed', p_reason)
    on conflict (razorpay_payment_id) do update
      set failure_reason = excluded.failure_reason
      where public.payments.status in ('pending', 'failed');
  end if;
end;
$$;

revoke execute on function public.handle_payment_failure(text, text, text) from public, anon, authenticated;
grant execute on function public.handle_payment_failure(text, text, text) to service_role;

-- ---------------------------------------------------------------------
-- 5. detector: captured payments whose booking never got confirmed
-- ---------------------------------------------------------------------
create or replace function private.detect_captured_unconfirmed()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select p.razorpay_payment_id, o.order_reference, b.status as booking_status, p.amount_cents
    from public.payments p
    join public.orders o on o.id = p.order_id and o.orderable_type = 'booking'
    join public.bookings b on b.id = o.orderable_id
    where p.status = 'captured'
      and p.captured_at < now() - interval '10 minutes'
      and b.status not in ('confirmed', 'completed')
      and not exists (select 1 from public.refunds rf
                      where rf.payment_id = p.id and rf.status in ('requested', 'approved', 'submitted_to_provider', 'processed'))
  loop
    perform private.raise_exception_record('captured_without_confirmed_booking', 'critical', 'payment',
      r.razorpay_payment_id,
      jsonb_build_object('order_reference', r.order_reference, 'booking_status', r.booking_status, 'amount_cents', r.amount_cents));
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function private.detect_captured_unconfirmed() from public, anon, authenticated;

select cron.schedule('detect-captured-unconfirmed', '*/15 * * * *', $$select private.detect_captured_unconfirmed();$$);

-- ---------------------------------------------------------------------
-- 6. webhook registry: claim / finish
-- ---------------------------------------------------------------------
create or replace function public.webhook_begin(p_event_id text, p_event_type text, p_payload jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.processed_webhook_events;
  v_inserted uuid;
begin
  insert into public.processed_webhook_events (event_id, event_type, payload, status, attempts)
  values (p_event_id, p_event_type, p_payload, 'processing', 1)
  on conflict (event_id) do nothing
  returning id into v_inserted;
  if v_inserted is not null then
    return 'process';
  end if;

  select * into v from public.processed_webhook_events where event_id = p_event_id for update;
  if v.status = 'processed' then
    return 'duplicate';
  end if;
  -- a delivery still being processed by another worker: tell the caller to retry later
  if v.status = 'processing' and v.last_attempt_at > now() - interval '2 minutes' then
    return 'in_progress';
  end if;
  update public.processed_webhook_events
     set status = 'processing', attempts = attempts + 1, last_attempt_at = now(),
         payload = coalesce(payload, p_payload)
   where id = v.id;
  return 'process';
end;
$$;

create or replace function public.webhook_finish(p_event_id text, p_ok boolean, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.processed_webhook_events
     set status = case when p_ok then 'processed' else 'failed' end,
         processed_at = now(),
         last_error = case when p_ok then null else left(p_error, 1000) end
   where event_id = p_event_id;
$$;

revoke execute on function public.webhook_begin(text, text, jsonb), public.webhook_finish(text, boolean, text)
  from public, anon, authenticated;
grant execute on function public.webhook_begin(text, text, jsonb), public.webhook_finish(text, boolean, text)
  to service_role;

-- ---------------------------------------------------------------------
-- 7. refund lifecycle
-- ---------------------------------------------------------------------
create or replace function public.am_i_full_admin()
returns boolean language sql stable set search_path = '' as $$
  select private.is_full_admin();
$$;
revoke execute on function public.am_i_full_admin() from public, anon;
grant execute on function public.am_i_full_admin() to authenticated;

create or replace function private.complete_refund(p_refund_id uuid, p_razorpay_refund_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_refund public.refunds;
  v_payment public.payments;
begin
  select * into v_refund from public.refunds where id = p_refund_id for update;
  if v_refund.status = 'processed' then return; end if;
  select * into v_payment from public.payments where id = v_refund.payment_id for update;

  update public.refunds
     set status = 'processed',
         razorpay_refund_id = coalesce(p_razorpay_refund_id, razorpay_refund_id),
         processed_at = now(), failure_reason = null
   where id = v_refund.id;

  update public.payments
     set refunded_cents = refunded_cents + v_refund.amount_cents,
         status = case when refunded_cents + v_refund.amount_cents >= amount_cents then 'refunded' else status end
   where id = v_payment.id;

  update public.orders set status = 'refunded'
   where id = v_payment.order_id
     and (select refunded_cents from public.payments where id = v_payment.id) >= v_payment.amount_cents;
end;
$$;
revoke execute on function private.complete_refund(uuid, text) from public, anon, authenticated;

create or replace function public.admin_approve_refund(p_refund_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v public.refunds;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;
  if v.status <> 'requested' then raise exception 'refund_not_requested: status is %', v.status; end if;
  update public.refunds set status = 'approved', approved_by = (select auth.uid()), approved_at = now() where id = v.id;
  perform private.write_audit('refund.approve', 'refund', v.id,
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'approved', 'amount_cents', v.amount_cents));
end;
$$;

create or replace function public.admin_reject_refund(p_refund_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v public.refunds;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_reason), '') is null then raise exception 'A rejection reason is required'; end if;
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;
  if v.status not in ('requested', 'approved') then raise exception 'refund_not_rejectable: status is %', v.status; end if;
  update public.refunds
     set status = 'rejected', rejected_by = (select auth.uid()), rejected_at = now(), rejection_reason = btrim(p_reason)
   where id = v.id;
  perform private.write_audit('refund.reject', 'refund', v.id,
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'rejected', 'reason', btrim(p_reason)));
end;
$$;

-- A failed refund goes back to `approved` for another execution attempt. The edge
-- function asks Razorpay first whether a refund for this row already exists, so a
-- retry can never refund twice.
create or replace function public.admin_retry_refund(p_refund_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v public.refunds;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;
  if v.status <> 'failed' then raise exception 'refund_not_failed: status is %', v.status; end if;
  update public.refunds set status = 'approved', retry_count = retry_count + 1, approved_by = (select auth.uid()), approved_at = now()
   where id = v.id;
  perform private.write_audit('refund.retry', 'refund', v.id,
    jsonb_build_object('status', 'failed', 'failure_reason', v.failure_reason),
    jsonb_build_object('status', 'approved', 'retry_count', v.retry_count + 1));
end;
$$;

-- Called by the `refund` edge function with the ADMIN's JWT: claims the refund for
-- execution under a row lock, so two clicks / two tabs can never both reach Razorpay.
create or replace function public.admin_begin_refund_execution(p_refund_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.refunds;
  v_payment public.payments;
  v_resume boolean := false;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;

  if v.status = 'submitted_to_provider' then
    -- possibly a timed-out earlier call: allow a resume (provider state is checked first) after a grace period
    if v.submitted_at > now() - interval '2 minutes' then
      raise exception 'refund_in_flight: submitted less than 2 minutes ago';
    end if;
    v_resume := true;
  elsif v.status <> 'approved' then
    raise exception 'refund_not_executable: status is % (must be approved)', v.status;
  end if;

  select * into v_payment from public.payments where id = v.payment_id for update;
  if v_payment.razorpay_payment_id is null or v_payment.status not in ('captured', 'duplicate_captured') then
    raise exception 'refund_payment_not_refundable: payment status %', v_payment.status;
  end if;

  update public.refunds
     set status = 'submitted_to_provider', submitted_at = now(), executed_by = (select auth.uid())
   where id = v.id;
  perform private.write_audit('refund.execute', 'refund', v.id,
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'submitted_to_provider', 'resume', v_resume));

  return jsonb_build_object(
    'refund_id', v.id, 'amount_cents', v.amount_cents, 'razorpay_payment_id', v_payment.razorpay_payment_id,
    'razorpay_refund_id', v.razorpay_refund_id, 'resume', v_resume);
end;
$$;

-- Service role: record what the provider said. Only a provider-confirmed
-- `processed` completes the refund.
create or replace function public.record_refund_provider_result(
  p_refund_id uuid,
  p_razorpay_refund_id text,
  p_provider_status text,
  p_failure text default null,
  p_definitive_failure boolean default false
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v public.refunds;
begin
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;
  if v.status in ('processed', 'rejected') then return v.status::text; end if;

  if p_razorpay_refund_id is not null and v.razorpay_refund_id is null then
    update public.refunds set razorpay_refund_id = p_razorpay_refund_id where id = v.id;
  end if;

  if p_provider_status = 'processed' then
    perform private.complete_refund(v.id, p_razorpay_refund_id);
    return 'processed';
  elsif p_definitive_failure or p_provider_status = 'failed' then
    update public.refunds set status = 'failed', failure_reason = left(coalesce(p_failure, 'provider rejected the refund'), 1000)
     where id = v.id and status in ('submitted_to_provider', 'approved');
    return 'failed';
  end if;
  return v.status::text;   -- accepted but not yet processed: wait for the webhook
end;
$$;

-- Webhook: refund.processed
drop function if exists public.confirm_refund(text, text);
create or replace function public.confirm_refund(
  p_razorpay_refund_id text,
  p_payment_id text,
  p_refund_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments;
  v public.refunds;
begin
  select * into v_payment from public.payments where razorpay_payment_id = p_payment_id for update;
  if v_payment.id is null then
    raise exception 'Payment not found for razorpay_payment_id %', p_payment_id;
  end if;

  select * into v from public.refunds where razorpay_refund_id = p_razorpay_refund_id for update;
  if v.id is null and p_refund_id is not null then
    select * into v from public.refunds where id = p_refund_id and payment_id = v_payment.id for update;
  end if;

  if v.id is null then
    -- a refund we never issued (e.g. from the Razorpay dashboard): never guess, queue it
    perform private.raise_exception_record('unmatched_refund_event', 'critical', 'refund', p_razorpay_refund_id,
      jsonb_build_object('razorpay_payment_id', p_payment_id));
    return;
  end if;
  if v.status = 'processed' then return; end if;

  if v.status in ('submitted_to_provider', 'approved') then
    perform private.complete_refund(v.id, p_razorpay_refund_id);
  elsif v.status = 'failed' then
    -- the provider says the money moved although we recorded a failure: provider truth wins
    perform private.complete_refund(v.id, p_razorpay_refund_id);
    perform private.raise_exception_record('refund_processed_after_failure', 'warning', 'refund', v.id::text,
      jsonb_build_object('razorpay_refund_id', p_razorpay_refund_id));
  else
    perform private.raise_exception_record('refund_state_conflict', 'critical', 'refund', v.id::text,
      jsonb_build_object('status', v.status, 'razorpay_refund_id', p_razorpay_refund_id));
  end if;
end;
$$;

-- Webhook: refund.failed
create or replace function public.fail_refund(p_razorpay_refund_id text, p_refund_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v public.refunds;
begin
  select * into v from public.refunds where razorpay_refund_id = p_razorpay_refund_id for update;
  if v.id is null and p_refund_id is not null then
    select * into v from public.refunds where id = p_refund_id for update;
  end if;
  if v.id is null then
    perform private.raise_exception_record('unmatched_refund_event', 'critical', 'refund', p_razorpay_refund_id,
      jsonb_build_object('event', 'refund.failed'));
    return;
  end if;
  if v.status = 'submitted_to_provider' then
    update public.refunds
       set status = 'failed', failure_reason = left(coalesce(p_reason, 'refund failed at provider'), 1000),
           razorpay_refund_id = coalesce(razorpay_refund_id, p_razorpay_refund_id)
     where id = v.id;
  end if;
end;
$$;

revoke execute on function
  public.admin_approve_refund(uuid), public.admin_reject_refund(uuid, text), public.admin_retry_refund(uuid),
  public.admin_begin_refund_execution(uuid),
  public.record_refund_provider_result(uuid, text, text, text, boolean),
  public.confirm_refund(text, text, uuid), public.fail_refund(text, uuid, text)
  from public, anon, authenticated;
grant execute on function
  public.admin_approve_refund(uuid), public.admin_reject_refund(uuid, text), public.admin_retry_refund(uuid),
  public.admin_begin_refund_execution(uuid) to authenticated;
grant execute on function
  public.record_refund_provider_result(uuid, text, text, text, boolean),
  public.confirm_refund(text, text, uuid), public.fail_refund(text, uuid, text) to service_role;

-- ---------------------------------------------------------------------
-- 8. cancel_booking: create a `requested` refund only, and never a second live one
-- ---------------------------------------------------------------------
create or replace function public.cancel_booking(
  p_booking_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_booking public.bookings;
  v_payment public.payments;
  v_refund_id uuid;
  v_trip_id uuid;
  v_departure timestamptz;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'Booking not found';
  end if;
  if v_booking.customer_id <> (select auth.uid()) and not private.is_platform_admin() then
    raise exception 'Not authorized to cancel this booking';
  end if;
  if v_booking.status not in ('confirmed', 'payment_pending') then
    raise exception 'Booking cannot be cancelled from status %', v_booking.status;
  end if;

  select bi.trip_id, t.departure_at into v_trip_id, v_departure
  from public.booking_items bi
  join public.bus_trips t on t.id = bi.trip_id
  where bi.booking_id = p_booking_id
  limit 1;

  if v_departure is not null and v_departure <= now() and not private.is_platform_admin() then
    raise exception 'trip_departed: this trip has already departed and can no longer be cancelled';
  end if;

  update public.bookings set status = 'cancelled' where id = p_booking_id;
  update public.booking_items set status = 'cancelled' where booking_id = p_booking_id;

  update public.trip_seats ts
  set status = 'available', hold_id = null
  from public.booking_items bi
  where bi.booking_id = p_booking_id
    and bi.trip_seat_id = ts.id
    and (
      (v_booking.status = 'confirmed' and ts.status = 'booked')
      or (v_booking.status = 'payment_pending' and ts.status = 'held' and exists (
            select 1 from public.seat_holds sh
            where sh.id = ts.hold_id
              and sh.user_id = v_booking.customer_id
              and sh.trip_id = bi.trip_id))
    );

  if v_trip_id is not null then
    update public.bus_trips t
    set available_seats = (select count(*) from public.trip_seats where trip_id = t.id and status = 'available')
    where t.id = v_trip_id;
  end if;

  insert into public.booking_status_history (booking_id, from_status, to_status, changed_by, note)
  values (p_booking_id, v_booking.status, 'cancelled', (select auth.uid()), p_reason);

  select p.* into v_payment
  from public.payments p
  join public.orders o on o.id = p.order_id
  where o.orderable_type = 'booking' and o.orderable_id = p_booking_id and p.status = 'captured'
  order by p.created_at desc
  limit 1;

  -- A refund REQUEST only. The admin reviews, approves and executes it; no money moves here.
  -- (a payment that could not be applied already has a live request: do not add a second one)
  if v_payment.id is not null and not exists (
       select 1 from public.refunds rf
        where rf.payment_id = v_payment.id
          and rf.status in ('requested', 'approved', 'submitted_to_provider', 'processed')) then
    insert into public.refunds (payment_id, amount_cents, reason, status, requested_by)
    values (v_payment.id, v_payment.amount_cents, p_reason, 'requested', (select auth.uid()))
    returning id into v_refund_id;
  end if;

  return jsonb_build_object('booking_id', p_booking_id, 'status', 'cancelled', 'refund_id', v_refund_id);
end;
$function$;

-- ---------------------------------------------------------------------
-- 9. QR boarding requires a captured payment (manual verification already did)
-- ---------------------------------------------------------------------
create or replace function private.do_board(p_item uuid, p_via text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v record;
begin
  select * into v from private.lock_boarding_item(p_item);
  perform private.trip_for_staff(v.trip_id, true);

  if v.seat_status = 'boarded' then
    perform private.log_boarding(v.item_id, v.trip_id, 'rejected_already_used');
    return jsonb_build_object('ok', false, 'code', 'already_boarded', 'message', 'Ticket already used');
  end if;
  if v.item_status <> 'confirmed' then
    perform private.log_boarding(v.item_id, v.trip_id, 'rejected_invalid');
    return jsonb_build_object('ok', false, 'code', 'not_confirmed', 'message', 'Ticket is not valid for boarding (status: ' || v.item_status || ')');
  end if;
  if not exists (
    select 1 from public.booking_items bi
    join public.orders o on o.orderable_type = 'booking' and o.orderable_id = bi.booking_id
    join public.payments py on py.order_id = o.id and py.status = 'captured'
    where bi.id = v.item_id) then
    perform private.log_boarding(v.item_id, v.trip_id, 'rejected_invalid');
    return jsonb_build_object('ok', false, 'code', 'not_paid', 'message', 'No captured payment was found for this booking.');
  end if;

  update public.trip_seats set status = 'boarded' where id = v.trip_seat_id;
  insert into public.passenger_boarding (booking_item_id, status, boarded_by, boarded_at, verified_by, verified_at)
  values (v.item_id, 'boarded', (select auth.uid()), now(), (select auth.uid()), now())
  on conflict (booking_item_id) do update
    set status = 'boarded', boarded_by = (select auth.uid()), boarded_at = now(), exception_reason = null,
        verified_by = coalesce(public.passenger_boarding.verified_by, (select auth.uid())),
        verified_at = coalesce(public.passenger_boarding.verified_at, now());
  perform private.log_boarding(v.item_id, v.trip_id, 'boarded');
  perform private.write_audit('boarding.confirm', 'booking_item', v.item_id, null, jsonb_build_object('via', p_via));
  return jsonb_build_object('ok', true, 'status', 'boarded');
end;
$$;
revoke execute on function private.do_board(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. trip_financials: "refunds initiated" now means any live, not-yet-completed
--     refund state (requested / approved / submitted_to_provider, plus legacy pending).
--     The function body is patched in place (single filter) so the rest of the
--     calculation, shared by every earnings/settlement RPC, is untouched.
-- ---------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_old constant text := $q$filter (where r.status = 'pending')$q$;
  v_new constant text := $q$filter (where r.status in ('pending', 'requested', 'approved', 'submitted_to_provider'))$q$;
begin
  v_def := pg_get_functiondef('private.trip_financials(uuid[])'::regprocedure);
  if position(v_old in v_def) = 0 then
    raise exception 'Gate A: expected refund filter not found in private.trip_financials';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;
