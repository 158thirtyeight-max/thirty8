-- Rollback for 20261002000200_payment_confirmation_integrity.sql
-- Restores the previous confirm_booking_after_payment (captured from the live database
-- before the change) and drops the unique index. No data is changed. Pending refunds
-- already created by the new function are left in place for the admin to process.

drop index if exists public.payments_one_captured_per_order_idx;

create or replace function public.confirm_booking_after_payment(p_order_reference text, p_payment_id text, p_amount_cents integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where order_reference = p_order_reference for update;
  if v_order.id is null then
    raise exception 'Order not found: %', p_order_reference;
  end if;
  if v_order.status = 'paid' then
    return jsonb_build_object('already_processed', true);
  end if;

  insert into public.payments (order_id, razorpay_payment_id, amount_cents, status, captured_at)
  values (v_order.id, p_payment_id, p_amount_cents, 'captured', now());

  update public.orders set status = 'paid' where id = v_order.id;

  if v_order.orderable_type = 'booking' then
    update public.bookings set status = 'confirmed' where id = v_order.orderable_id;
    update public.booking_items set status = 'confirmed' where booking_id = v_order.orderable_id;

    update public.trip_seats ts
    set status = 'booked'
    from public.booking_items bi
    where bi.booking_id = v_order.orderable_id and bi.trip_seat_id = ts.id;

    update public.seat_holds sh
    set status = 'confirmed'
    where sh.id in (
      select ts.hold_id
      from public.booking_items bi
      join public.trip_seats ts on ts.id = bi.trip_seat_id
      where bi.booking_id = v_order.orderable_id and ts.hold_id is not null
    );

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

  return jsonb_build_object('order_id', v_order.id, 'status', 'confirmed');
end;
$function$;
