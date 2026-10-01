-- =========================================================================
-- Phase 3 repair: booking windows, cutoffs and trip status
--   Before: booking_open_at / booking_close_at / booking_cutoff_min were stored on
--   every trip but never enforced, and none of search, seat map, hold or booking
--   looked at the trip status or departure time. A trip stayed bookable until the
--   hourly roll_trip_status job marked it departed (and trips missed by that job for
--   more than a day never rolled at all).
--
--   Now:
--   * private.trip_is_open_for_booking(trip): status 'scheduled', not departed, sales
--     window open (booking_open_at <= now) and not closed (booking_close_at, i.e.
--     departure minus the service's booking cutoff, > now).
--   * search_trips (direct and both legs of connected), get_trip_seat_map and
--     create_seat_hold require it.
--   * create_booking requires only status 'scheduled' and not departed, so a customer
--     who already holds seats can finish paying within the hold lifetime.
--   * cancel_booking: refreshes the trip's available_seats; customers cannot cancel a
--     trip that has departed (platform admins can); and it frees only seats that still
--     belong to the booking (a stale pending booking can no longer free a resold seat).
--   * roll_trip_status: no longer ignores trips that departed more than a day ago.
--
--   boarding_cutoff_min concerns boarding at the stop, not sales, and is unchanged.
--   booking_open_at is NOT NULL (default now()); a trip with NULL booking_close_at stays open until departure.
--   Rollback: supabase/rollbacks/20261002000300_booking_window_enforcement.down.sql
-- =========================================================================

create or replace function private.trip_is_open_for_booking(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.bus_trips t
    where t.id = p_trip_id
      and t.status = 'scheduled'
      and t.departure_at > now()
      and t.booking_open_at <= now()
      and coalesce(t.booking_close_at, t.departure_at) > now()
  );
$function$;

revoke execute on function private.trip_is_open_for_booking(uuid) from public, anon, authenticated;

create or replace function public.create_seat_hold(
  p_trip_id uuid,
  p_seat_ids uuid[],
  p_ttl_seconds integer default 300,
  p_boarding_point_id uuid default null,
  p_dropping_point_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_hold_id uuid;
  v_expires_at timestamptz := now() + make_interval(secs => least(greatest(coalesce(p_ttl_seconds, 300), 30), 600));
  v_locked_count integer;
  v_seat_count integer := coalesce(array_length(p_seat_ids, 1), 0);
  v_unavailable_count integer;
  v_bus_id uuid;
  v_quote jsonb;
begin
  if v_user_id is null then
    raise exception 'Must be authenticated to hold seats';
  end if;
  if v_seat_count = 0 then
    raise exception 'No seats specified';
  end if;

  select bus_id into v_bus_id from public.bus_trips where id = p_trip_id;
  if v_bus_id is null or not private.is_bus_bookable(v_bus_id) then
    raise exception 'bus_unavailable: this bus is not available for booking';
  end if;
  if not private.trip_is_open_for_booking(p_trip_id) then
    raise exception 'trip_closed: this trip is not open for booking';
  end if;
  perform private.validate_trip_points(p_trip_id, p_boarding_point_id, p_dropping_point_id);

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

  select jsonb_object_agg(sid::text, private.calc_seat_fare(p_trip_id, sid, p_boarding_point_id, p_dropping_point_id))
    into v_quote
  from unnest(p_seat_ids) sid;

  insert into public.seat_holds (trip_id, user_id, expires_at, boarding_point_id, dropping_point_id, quoted_fares)
  values (p_trip_id, v_user_id, v_expires_at, p_boarding_point_id, p_dropping_point_id, v_quote)
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
    'seat_ids', p_seat_ids,
    'quoted_fares', v_quote,
    'total_fare_cents', (select coalesce(sum(value::text::integer), 0) from jsonb_each(v_quote))
  );
end;
$function$;

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
as $function$
declare
  v_user_id uuid := (select auth.uid());
  v_hold public.seat_holds;
  v_bus_id uuid;
  v_booking_id uuid;
  v_booking_reference text;
  v_order_id uuid;
  v_order_reference text;
  v_total_fare integer := 0;
  v_fare integer;
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

  -- The hold row is locked above, so concurrent calls with the same token
  -- serialise here and the second one sees the first one's items. Items are
  -- matched to THIS hold by customer + creation time (booking_items has no hold
  -- id): an older pending item for the same seat, left over from an earlier hold
  -- that expired, must not block this customer from booking the seat.
  if exists (
    select 1
    from public.booking_items bi
    join public.bookings b on b.id = bi.booking_id
    join public.trip_seats ts on ts.id = bi.trip_seat_id
    where ts.hold_id = v_hold.id
      and b.customer_id = v_user_id
      and bi.created_at >= v_hold.created_at
      and bi.status in ('payment_pending', 'confirmed', 'completed')
  ) then
    raise exception 'hold_already_used: a booking already exists for these held seats';
  end if;

  select bus_id into v_bus_id from public.bus_trips where id = v_hold.trip_id;
  if v_bus_id is null or not private.is_bus_bookable(v_bus_id) then
    raise exception 'bus_unavailable: this bus is not available for booking';
  end if;
  -- The sales window is enforced when the hold is created. A customer who already
  -- holds seats may finish paying inside the hold lifetime, but never for a trip
  -- that has been cancelled or has already departed.
  if not exists (
    select 1 from public.bus_trips t
    where t.id = v_hold.trip_id and t.status = 'scheduled' and t.departure_at > now()
  ) then
    raise exception 'trip_closed: this trip is no longer open for booking';
  end if;
  perform private.validate_trip_points(v_hold.trip_id, p_boarding_point_id, p_dropping_point_id);

  if v_hold.boarding_point_id is not null
     and (v_hold.boarding_point_id is distinct from p_boarding_point_id
          or v_hold.dropping_point_id is distinct from p_dropping_point_id) then
    raise exception 'points_changed: the boarding / dropping points differ from the ones the seats were held for';
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
    select ts.id as trip_seat_id, ts.seat_id, (row_number() over (order by ts.id) - 1)::int as rn
    from public.trip_seats ts
    where ts.hold_id = v_hold.id
  loop
    v_passenger := p_passengers -> v_seat.rn;
    v_fare := private.calc_seat_fare(v_hold.trip_id, v_seat.seat_id, p_boarding_point_id, p_dropping_point_id);

    if v_hold.quoted_fares is not null and v_hold.boarding_point_id is not null
       and (v_hold.quoted_fares ->> v_seat.seat_id::text)::integer is distinct from v_fare then
      raise exception 'fare_changed: the fare changed since the seats were held; please review and try again';
    end if;

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
      p_boarding_point_id, p_dropping_point_id, v_fare, 'payment_pending'
    );

    v_total_fare := v_total_fare + v_fare;
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
$function$;

create or replace function public.search_trips(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date,
  p_pickup_point_id uuid default null,
  p_drop_point_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_direct jsonb;
  v_connected jsonb;
begin
  -- Only active main locations are searchable.
  if not exists (select 1 from public.cities where id = p_source_city_id and is_active and display_order is not null)
     or not exists (select 1 from public.cities where id = p_destination_city_id and is_active and display_order is not null) then
    return jsonb_build_object('direct', '[]'::jsonb, 'connected', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'trip_id', t.id,
    'service_id', sv.id,
    'operator_id', o.id,
    'operator_name', o.name,
    'operator_rating', o.rating,
    'bus_id', bs.id,
    'bus_type', bs.bus_type,
    'amenities', bs.amenities,
    'departure_at', t.departure_at,
    'arrival_at', t.arrival_at,
    'available_seats', t.available_seats,
    'min_fare_cents', fr.min_cents,
    'max_fare_cents', fr.max_cents,
    'currency_code', t.currency_code
  ) order by t.departure_at), '[]'::jsonb)
  into v_direct
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  join public.operators o on o.id = t.operator_id
  join public.buses bs on bs.id = t.bus_id
  join public.bus_routes r on r.id = t.route_id
  cross join lateral private.trip_fare_range(t.id, p_source_city_id, p_destination_city_id, p_pickup_point_id, p_drop_point_id) fr
  where t.travel_date = p_travel_date
    and t.status = 'scheduled'
    and private.trip_is_open_for_booking(t.id)
    and private.is_bus_bookable(t.bus_id)
    and (
      (sv.service_source_city_id = p_source_city_id and sv.service_dest_city_id = p_destination_city_id)
      or exists (
        select 1
        from public.boarding_points b
        join public.dropping_points d on d.route_id = b.route_id
        where b.route_id = t.route_id and b.is_active and d.is_active
          and b.city_id = p_source_city_id and d.city_id = p_destination_city_id
          and r.bus_id is not null and d.sequence_no > b.sequence_no
      )
    )
    -- Exact pickup / drop filter: the route must serve those master points, in order.
    and (
      (p_pickup_point_id is null and p_drop_point_id is null)
      or exists (
        select 1
        from public.boarding_points b
        join public.dropping_points d on d.route_id = b.route_id
        where b.route_id = t.route_id and b.is_active and d.is_active
          and (p_pickup_point_id is null or b.master_point_id = p_pickup_point_id)
          and (p_drop_point_id is null or d.master_point_id = p_drop_point_id)
          and coalesce(b.city_id, sv.service_source_city_id) = p_source_city_id
          and coalesce(d.city_id, sv.service_dest_city_id) = p_destination_city_id
          and d.sequence_no > b.sequence_no
      )
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'transfer_city_id', s1.service_dest_city_id,
    'leg1', jsonb_build_object(
      'trip_id', t1.id, 'service_id', s1.id, 'operator_id', o1.id, 'operator_name', o1.name,
      'departure_at', t1.departure_at, 'arrival_at', t1.arrival_at,
      'min_fare_cents', f1.min_cents, 'available_seats', t1.available_seats
    ),
    'leg2', jsonb_build_object(
      'trip_id', t2.id, 'service_id', s2.id, 'operator_id', o2.id, 'operator_name', o2.name,
      'departure_at', t2.departure_at, 'arrival_at', t2.arrival_at,
      'min_fare_cents', f2.min_cents, 'available_seats', t2.available_seats
    ),
    'total_min_fare_cents', coalesce(f1.min_cents, 0) + coalesce(f2.min_cents, 0)
  ) order by t1.departure_at), '[]'::jsonb)
  into v_connected
  from public.bus_services s1
  join public.bus_trips t1 on t1.service_id = s1.id
    and t1.travel_date = p_travel_date
    and t1.status = 'scheduled'
  join public.operators o1 on o1.id = t1.operator_id
  join public.bus_services s2 on s2.service_source_city_id = s1.service_dest_city_id
    and s2.service_dest_city_id = p_destination_city_id
  join public.bus_trips t2 on t2.service_id = s2.id
    and t2.status = 'scheduled'
    and t2.travel_date between p_travel_date and p_travel_date + 1
  join public.operators o2 on o2.id = t2.operator_id
  cross join lateral private.trip_fare_range(t1.id, s1.service_source_city_id, s1.service_dest_city_id) f1
  cross join lateral private.trip_fare_range(t2.id, s2.service_source_city_id, s2.service_dest_city_id) f2
  where s1.service_source_city_id = p_source_city_id
    and private.is_bus_bookable(t1.bus_id)
    and private.is_bus_bookable(t2.bus_id)
    and private.trip_is_open_for_booking(t1.id)
    and private.trip_is_open_for_booking(t2.id)
    and p_pickup_point_id is null and p_drop_point_id is null
    and t2.departure_at >= t1.arrival_at + interval '15 minutes'
    and t2.departure_at <= t1.arrival_at + interval '6 hours';

  return jsonb_build_object('direct', v_direct, 'connected', v_connected);
end;
$$;

create or replace function public.get_trip_seat_map(
  p_trip_id uuid,
  p_boarding_point_id uuid default null,
  p_dropping_point_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_result jsonb;
begin
  perform private.validate_trip_points(p_trip_id, p_boarding_point_id, p_dropping_point_id);

  select jsonb_build_object(
    'trip_id', t.id,
    'bus_id', t.bus_id,
    'layout', bl.layout_json,
    'deck_count', bl.deck_count,
    'boarding_point_id', p_boarding_point_id,
    'dropping_point_id', p_dropping_point_id,
    'seats', coalesce(jsonb_agg(jsonb_build_object(
      'trip_seat_id', ts.id,
      'seat_id', s.id,
      'seat_code', s.seat_code,
      'deck', s.deck,
      'row_no', s.row_no,
      'col_no', s.col_no,
      'seat_type', s.seat_type,
      'berth', s.berth,
      'category', s.category,
      'gender_restriction', s.gender_restriction,
      'status', ts.status,
      'fare_cents', private.resolve_seat_fare(t.service_id, t.travel_date, s.id, p_boarding_point_id, p_dropping_point_id, ts.fare_cents)
    ) order by s.deck, s.row_no, s.col_no), '[]'::jsonb)
  )
  into v_result
  from public.bus_trips t
  join public.bus_layouts bl on bl.bus_id = t.bus_id and bl.is_active
  join public.trip_seats ts on ts.trip_id = t.id
  join public.seats s on s.id = ts.seat_id
  where t.id = p_trip_id
    and private.is_bus_bookable(t.bus_id)
    and private.trip_is_open_for_booking(t.id)
  group by t.id, t.bus_id, t.service_id, t.travel_date, bl.layout_json, bl.deck_count;

  return v_result;
end;
$function$;

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

  -- Customers cannot cancel (and be refunded for) a trip that has already left.
  -- Platform admins can, for exceptional cases.
  if v_departure is not null and v_departure <= now() and not private.is_platform_admin() then
    raise exception 'trip_departed: this trip has already departed and can no longer be cancelled';
  end if;

  update public.bookings set status = 'cancelled' where id = p_booking_id;
  update public.booking_items set status = 'cancelled' where booking_id = p_booking_id;

  -- Free only seats that still belong to this booking. A pending booking whose hold
  -- expired may have had its seat resold; that seat must not be freed from its new owner.
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

  if v_payment.id is not null then
    insert into public.refunds (payment_id, amount_cents, reason, status)
    values (v_payment.id, v_payment.amount_cents, p_reason, 'pending')
    returning id into v_refund_id;
  end if;

  return jsonb_build_object('booking_id', p_booking_id, 'status', 'cancelled', 'refund_id', v_refund_id);
end;
$function$;

create or replace function private.roll_trip_status()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  -- No lower bound: trips that were missed (e.g. cron downtime) must still roll over.
  update public.bus_trips
  set status = 'departed'
  where status in ('scheduled', 'boarding')
    and departure_at < now();

  update public.bus_trips
  set status = 'arrived'
  where status = 'departed'
    and arrival_at is not null
    and arrival_at < now();
end;
$function$;
