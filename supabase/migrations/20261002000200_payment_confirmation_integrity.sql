-- =========================================================================
-- Phase 2 repair: payment confirmation integrity
--   confirm_booking_after_payment used to confirm whatever order it was given:
--   no check that the booking was still waiting for payment, no check that
--   the paid amount matched the order, and seats were forced to `booked`
--   even when they had been released and resold after the hold expired.
--
--   Now, under row locks, a captured payment is confirmed only if
--     * the paid amount equals the order amount,
--     * the booking is still `payment_pending` (cargo: shipment is `draft`),
--     * every seat is still free or still held by the same customer on the
--       same trip (a hold that merely expired and was not resold is honoured).
--   Otherwise the payment is recorded, the order is marked paid (the money
--   was received), the booking/seats are left untouched, and a PENDING refund
--   row is created for the admin refund workflow (admin refunds page + the
--   `refund` edge function). The function returns status `refund_pending`.
--
--   Also: at most one captured payment per order (unique partial index).
--
-- Additive and reversible: see supabase/rollbacks/20261002000200_payment_confirmation_integrity.down.sql.
-- Known remaining gap (not changed here): handle_payment_failure releases the
-- seats on the FIRST failed attempt even though Razorpay lets the customer retry
-- the same order; a later successful retry is therefore refunded, not honoured.
-- =========================================================================

do $$
declare
  n bigint;
begin
  select count(*) into n from (
    select order_id from public.payments where status = 'captured' group by order_id having count(*) > 1
  ) d;
  if n > 0 then
    raise exception 'Phase 2 aborted: % order(s) already have more than one captured payment. Resolve them first.', n;
  end if;
end $$;

create unique index payments_one_captured_per_order_idx
  on public.payments (order_id)
  where status = 'captured';

create or replace function public.confirm_booking_after_payment(
  p_order_reference text,
  p_payment_id text,
  p_amount_cents integer
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
    return jsonb_build_object('already_processed', true);
  end if;

  -- The money is real whatever happens next, so the payment is always recorded.
  insert into public.payments (order_id, razorpay_payment_id, amount_cents, status, captured_at)
  values (v_order.id, p_payment_id, p_amount_cents, 'captured', now())
  returning id into v_payment_uuid;

  update public.orders set status = 'paid' where id = v_order.id;

  -- Decide whether the paid order can still be fulfilled.
  if p_amount_cents is distinct from v_order.amount_cents then
    v_reason := format('amount_mismatch: paid %s, order %s', p_amount_cents, v_order.amount_cents);

  elsif v_order.orderable_type = 'booking' then
    select * into v_booking from public.bookings where id = v_order.orderable_id for update;
    if v_booking.id is null then
      v_reason := 'booking_missing';
    elsif v_booking.status <> 'payment_pending' then
      v_reason := format('booking_not_pending: status is %s', v_booking.status);
    else
      -- Lock the seats, then require each to be free or still held by this customer on this trip.
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

  -- Fulfil. Wrapped so that a late conflict (e.g. the confirmed-seat unique
  -- index) rolls the fulfilment back and takes the refund path instead of
  -- failing the whole payment record.
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
    insert into public.refunds (payment_id, amount_cents, reason, status)
    values (v_payment_uuid, p_amount_cents, 'Payment could not be applied: ' || v_reason, 'pending');

    return jsonb_build_object(
      'order_id', v_order.id,
      'status', 'refund_pending',
      'reason', v_reason
    );
  end if;

  return jsonb_build_object('order_id', v_order.id, 'status', 'confirmed');
end;
$function$;
