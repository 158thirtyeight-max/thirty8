-- =========================================================================
-- Concurrency-critical business functions: seat holds, booking lifecycle,
-- cargo pricing/cancellation, payment confirmation/failure, refunds.
--
-- All of these are SECURITY DEFINER and are the ONLY way trip_seats,
-- bookings, orders, payments and cargo_shipments status ever change once
-- created — this is what makes the RLS "no direct mutation" policies on
-- those tables safe. Concurrency safety for seats comes from locking the
-- candidate public.trip_seats rows with SELECT ... FOR UPDATE before
-- checking/changing their status, inside a single transaction.
-- =========================================================================

create or replace function public.create_seat_hold(
  p_trip_id uuid,
  p_seat_ids uuid[],
  p_ttl_seconds integer default 300
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_hold_id uuid;
  v_expires_at timestamptz := now() + make_interval(secs => p_ttl_seconds);
  v_locked_count integer;
  v_seat_count integer := coalesce(array_length(p_seat_ids, 1), 0);
  v_unavailable_count integer;
begin
  if v_user_id is null then
    raise exception 'Must be authenticated to hold seats';
  end if;
  if v_seat_count = 0 then
    raise exception 'No seats specified';
  end if;

  -- Lock the candidate rows first: concurrent callers for the same seats
  -- serialize here, so only one transaction proceeds past this point at a time.
  perform 1
  from public.trip_seats ts
  where ts.trip_id = p_trip_id
    and ts.seat_id = any (p_seat_ids)
  for update;

  select count(*) into v_locked_count
  from public.trip_seats ts
  where ts.trip_id = p_trip_id and ts.seat_id = any (p_seat_ids);

  if v_locked_count <> v_seat_count then
    raise exception 'One or more seats do not exist on this trip';
  end if;

  -- Opportunistically reclaim seats whose hold expired but pg_cron hasn't
  -- swept them yet, so a caller isn't blocked by a stale hold.
  update public.trip_seats ts
  set status = 'available', hold_id = null
  from public.seat_holds sh
  where ts.hold_id = sh.id
    and ts.trip_id = p_trip_id
    and ts.seat_id = any (p_seat_ids)
    and ts.status = 'held'
    and sh.status = 'active'
    and sh.expires_at < now();

  select count(*) into v_unavailable_count
  from public.trip_seats ts
  where ts.trip_id = p_trip_id
    and ts.seat_id = any (p_seat_ids)
    and ts.status <> 'available';

  if v_unavailable_count > 0 then
    raise exception 'seat_unavailable: one or more selected seats are no longer available';
  end if;

  insert into public.seat_holds (trip_id, user_id, expires_at)
  values (p_trip_id, v_user_id, v_expires_at)
  returning id into v_hold_id;

  update public.trip_seats ts
  set status = 'held', hold_id = v_hold_id
  where ts.trip_id = p_trip_id and ts.seat_id = any (p_seat_ids);

  update public.bus_trips t
  set available_seats = (select count(*) from public.trip_seats where trip_id = t.id and status = 'available')
  where t.id = p_trip_id;

  return jsonb_build_object(
    'hold_id', v_hold_id,
    'hold_token', (select hold_token from public.seat_holds where id = v_hold_id),
    'expires_at', v_expires_at,
    'seat_ids', p_seat_ids
  );
end;
$$;

create or replace function public.release_seat_hold(p_hold_token uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hold public.seat_holds;
begin
  select * into v_hold from public.seat_holds where hold_token = p_hold_token for update;
  if v_hold.id is null then
    raise exception 'Hold not found';
  end if;
  if v_hold.user_id <> (select auth.uid()) then
    raise exception 'Not your hold';
  end if;
  if v_hold.status <> 'active' then
    return;
  end if;

  update public.trip_seats set status = 'available', hold_id = null where hold_id = v_hold.id;
  update public.seat_holds set status = 'released' where id = v_hold.id;

  update public.bus_trips t
  set available_seats = (select count(*) from public.trip_seats where trip_id = t.id and status = 'available')
  where t.id = v_hold.trip_id;
end;
$$;

-- Converts an active seat hold into a payment_pending booking + order.
-- p_passengers is a JSON array of {full_name, age, gender, phone}, one per
-- held seat, matched by trip_seat insertion order.
create or replace function public.create_booking(
  p_hold_token uuid,
  p_contact_email text,
  p_contact_phone text,
  p_passengers jsonb,
  p_boarding_point_id uuid,
  p_dropping_point_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_hold public.seat_holds;
  v_booking_id uuid;
  v_booking_reference text;
  v_order_id uuid;
  v_order_reference text;
  v_total_fare integer := 0;
  v_seat record;
  v_passenger jsonb;
  v_passenger_id uuid;
  v_seat_ids uuid[];
begin
  if v_user_id is null then
    raise exception 'Must be authenticated';
  end if;

  select * into v_hold from public.seat_holds where hold_token = p_hold_token for update;
  if v_hold.id is null or v_hold.user_id <> v_user_id then
    raise exception 'Hold not found';
  end if;
  if v_hold.status <> 'active' or v_hold.expires_at < now() then
    raise exception 'Hold has expired';
  end if;

  select array_agg(seat_id) into v_seat_ids from public.trip_seats where hold_id = v_hold.id;
  if v_seat_ids is null or array_length(v_seat_ids, 1) <> jsonb_array_length(p_passengers) then
    raise exception 'Passenger count must match held seat count';
  end if;

  v_booking_reference := 'TH' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  insert into public.bookings (booking_reference, customer_id, contact_email, contact_phone, status)
  values (v_booking_reference, v_user_id, p_contact_email, p_contact_phone, 'payment_pending')
  returning id into v_booking_id;

  for v_seat in
    select ts.id as trip_seat_id, ts.fare_cents, (row_number() over (order by ts.id) - 1)::int as rn
    from public.trip_seats ts
    where ts.hold_id = v_hold.id
  loop
    v_passenger := p_passengers -> v_seat.rn;

    insert into public.passengers (booking_id, full_name, age, gender, phone)
    values (
      v_booking_id,
      v_passenger ->> 'full_name',
      (v_passenger ->> 'age')::smallint,
      (v_passenger ->> 'gender')::public.passenger_gender,
      v_passenger ->> 'phone'
    )
    returning id into v_passenger_id;

    insert into public.booking_items (
      booking_id, trip_id, trip_seat_id, passenger_id,
      boarding_point_id, dropping_point_id, fare_cents, status
    )
    values (
      v_booking_id, v_hold.trip_id, v_seat.trip_seat_id, v_passenger_id,
      p_boarding_point_id, p_dropping_point_id, v_seat.fare_cents, 'payment_pending'
    );

    v_total_fare := v_total_fare + v_seat.fare_cents;
  end loop;

  update public.bookings set total_fare_cents = v_total_fare where id = v_booking_id;

  insert into public.booking_status_history (booking_id, from_status, to_status, changed_by)
  values (v_booking_id, 'draft', 'payment_pending', v_user_id);

  v_order_reference := 'ORD' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  insert into public.orders (order_reference, orderable_type, orderable_id, customer_id, amount_cents, status)
  values (v_order_reference, 'booking', v_booking_id, v_user_id, v_total_fare, 'created')
  returning id into v_order_id;

  return jsonb_build_object(
    'booking_id', v_booking_id,
    'booking_reference', v_booking_reference,
    'order_id', v_order_id,
    'order_reference', v_order_reference,
    'amount_cents', v_total_fare
  );
end;
$$;

-- Called by the Razorpay webhook handler (Phase 5) on payment.captured.
-- Idempotent: calling it twice for an already-paid order is a no-op.
create or replace function public.confirm_booking_after_payment(
  p_order_reference text,
  p_payment_id text,
  p_amount_cents integer
)
returns jsonb
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
$$;

-- Called by the Razorpay webhook handler on payment.failed.
create or replace function public.handle_payment_failure(p_order_reference text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_hold_ids uuid[];
begin
  select * into v_order from public.orders where order_reference = p_order_reference for update;
  if v_order.id is null then
    raise exception 'Order not found: %', p_order_reference;
  end if;

  update public.orders set status = 'failed' where id = v_order.id;

  if v_order.orderable_type = 'booking' then
    select array_agg(distinct ts.hold_id) into v_hold_ids
    from public.booking_items bi
    join public.trip_seats ts on ts.id = bi.trip_seat_id
    where bi.booking_id = v_order.orderable_id and ts.hold_id is not null;

    update public.bookings set status = 'failed' where id = v_order.orderable_id;
    update public.booking_items set status = 'failed' where booking_id = v_order.orderable_id;

    update public.trip_seats ts
    set status = 'available', hold_id = null
    from public.booking_items bi
    where bi.booking_id = v_order.orderable_id and bi.trip_seat_id = ts.id;

    if v_hold_ids is not null then
      update public.seat_holds set status = 'expired' where id = any (v_hold_ids);
    end if;

    insert into public.booking_status_history (booking_id, from_status, to_status)
    values (v_order.orderable_id, 'payment_pending', 'failed');

  elsif v_order.orderable_type = 'cargo_shipment' then
    update public.cargo_shipments set status = 'failed' where id = v_order.orderable_id;
  end if;
end;
$$;

-- Customer- or admin-initiated cancellation of a confirmed/pending booking.
-- Frees the seat immediately for resale and opens a pending refund if the
-- booking was already paid (the actual cancellation-policy fare calculation
-- and Razorpay refund call happen in the Edge Function, Phase 5; this
-- function just records the terminal state and refund intent atomically).
create or replace function public.cancel_booking(p_booking_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
  v_payment public.payments;
  v_refund_id uuid;
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

  update public.bookings set status = 'cancelled' where id = p_booking_id;
  update public.booking_items set status = 'cancelled' where booking_id = p_booking_id;

  update public.trip_seats ts
  set status = 'available', hold_id = null
  from public.booking_items bi
  where bi.booking_id = p_booking_id and bi.trip_seat_id = ts.id;

  insert into public.booking_status_history (booking_id, from_status, to_status, changed_by, note)
  values (p_booking_id, v_booking.status, 'cancelled', (select auth.uid()), p_reason);

  select p.* into v_payment
  from public.payments p
  join public.orders o on o.id = p.order_id
  where o.orderable_type = 'booking' and o.orderable_id = p_booking_id and p.status = 'captured'
  order by p.created_at desc
  limit 1;

  if v_payment.id is not null then
    insert into public.refunds (payment_id, amount_cents, reason, status)
    values (v_payment.id, v_payment.amount_cents, p_reason, 'pending')
    returning id into v_refund_id;
  end if;

  return jsonb_build_object('booking_id', p_booking_id, 'status', 'cancelled', 'refund_id', v_refund_id);
end;
$$;

-- Cargo: cancellation is only allowed before pickup, always a full refund.
create or replace function public.cancel_shipment(p_shipment_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
  v_payment public.payments;
  v_refund_id uuid;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id for update;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if v_shipment.sender_user_id <> (select auth.uid()) and not private.is_platform_admin() then
    raise exception 'Not authorized to cancel this shipment';
  end if;
  if v_shipment.status not in ('draft', 'confirmed') then
    raise exception 'Shipment can only be cancelled before pickup (current status: %)', v_shipment.status;
  end if;

  update public.cargo_shipments set status = 'cancelled' where id = p_shipment_id;
  insert into public.cargo_status_history (shipment_id, from_status, to_status, changed_by, note)
  values (p_shipment_id, v_shipment.status, 'cancelled', (select auth.uid()), p_reason);

  select p.* into v_payment
  from public.payments p
  join public.orders o on o.id = p.order_id
  where o.orderable_type = 'cargo_shipment' and o.orderable_id = p_shipment_id and p.status = 'captured'
  order by p.created_at desc
  limit 1;

  if v_payment.id is not null then
    insert into public.refunds (payment_id, amount_cents, reason, status)
    values (v_payment.id, v_payment.amount_cents, p_reason, 'pending')
    returning id into v_refund_id;
  end if;

  return jsonb_build_object('shipment_id', p_shipment_id, 'status', 'cancelled', 'refund_id', v_refund_id);
end;
$$;

-- Called by the Razorpay webhook handler on refund.processed.
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

-- Cargo price quote: base + per-km*distance + per-kg*weight + surcharge,
-- from the active cargo_pricing_rules row for this route/vehicle/cargo type.
create or replace function public.estimate_cargo_price(
  p_route_id uuid,
  p_vehicle_type_id uuid,
  p_cargo_type_id uuid,
  p_weight_kg numeric
)
returns jsonb
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_rule public.cargo_pricing_rules;
  v_route public.cargo_routes;
  v_distance numeric := 0;
  v_base integer;
  v_distance_fare integer;
  v_weight_fare integer;
  v_total integer;
begin
  select * into v_route from public.cargo_routes where id = p_route_id;
  if v_route.id is null then
    raise exception 'Cargo route not found';
  end if;
  v_distance := coalesce(v_route.distance_km, 0);

  select * into v_rule
  from public.cargo_pricing_rules
  where route_id = p_route_id
    and vehicle_type_id = p_vehicle_type_id
    and cargo_type_id = p_cargo_type_id
    and effective_from <= current_date
    and (effective_to is null or effective_to >= current_date)
  order by effective_from desc
  limit 1;

  if v_rule.id is null then
    raise exception 'No pricing rule found for this route/vehicle/cargo type combination';
  end if;

  v_base := v_rule.base_fare_cents;
  v_distance_fare := round(v_rule.per_km_cents * v_distance)::integer;
  v_weight_fare := round(v_rule.per_kg_cents * p_weight_kg)::integer;
  v_total := v_base + v_distance_fare + v_weight_fare + v_rule.surcharge_cents;

  return jsonb_build_object(
    'base_fare_cents', v_base,
    'distance_fare_cents', v_distance_fare,
    'weight_fare_cents', v_weight_fare,
    'surcharge_cents', v_rule.surcharge_cents,
    'total_fare_cents', v_total,
    'distance_km', v_distance
  );
end;
$$;

-- Customer-facing functions: safe for any authenticated user to call, since
-- each checks auth.uid() ownership internally.
revoke execute on function public.create_seat_hold(uuid, uuid[], integer) from public, anon;
revoke execute on function public.release_seat_hold(uuid) from public, anon;
revoke execute on function public.create_booking(uuid, text, text, jsonb, uuid, uuid) from public, anon;
revoke execute on function public.cancel_booking(uuid, text) from public, anon;
revoke execute on function public.cancel_shipment(uuid, text) from public, anon;

grant execute on function public.create_seat_hold(uuid, uuid[], integer) to authenticated;
grant execute on function public.release_seat_hold(uuid) to authenticated;
grant execute on function public.create_booking(uuid, text, text, jsonb, uuid, uuid) to authenticated;
grant execute on function public.cancel_booking(uuid, text) to authenticated;
grant execute on function public.cancel_shipment(uuid, text) to authenticated;

grant execute on function public.estimate_cargo_price(uuid, uuid, uuid, numeric) to anon, authenticated;

-- Payment-fulfillment functions: NOT callable by ordinary authenticated
-- users — they trust their inputs completely (order_reference + payment id)
-- with no way to verify a real Razorpay charge happened. Only the Edge
-- Functions (Phase 5), calling with the service_role key, may invoke them.
revoke execute on function public.confirm_booking_after_payment(text, text, integer) from public, anon, authenticated;
revoke execute on function public.handle_payment_failure(text) from public, anon, authenticated;
revoke execute on function public.confirm_refund(text, text) from public, anon, authenticated;
grant execute on function public.confirm_booking_after_payment(text, text, integer) to service_role;
grant execute on function public.handle_payment_failure(text) to service_role;
grant execute on function public.confirm_refund(text, text) to service_role;
