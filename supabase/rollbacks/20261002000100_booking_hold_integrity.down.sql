-- Rollback for 20261002000100_booking_hold_integrity.sql
-- Restores the previous function bodies (captured from the live database before the change)
-- and drops the unique index. Safe to run at any time; no data is changed.

drop index if exists public.booking_items_one_confirmed_per_seat_idx;

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
  v_expires_at timestamptz := now() + make_interval(secs => p_ttl_seconds);
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

  select bus_id into v_bus_id from public.bus_trips where id = v_hold.trip_id;
  if v_bus_id is null or not private.is_bus_bookable(v_bus_id) then
    raise exception 'bus_unavailable: this bus is not available for booking';
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
