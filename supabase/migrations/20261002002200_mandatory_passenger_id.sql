-- =========================================================================
-- Mandatory passenger ID (type + number only) and the boarding-list export.
--   * create_booking now requires an ID type and number per passenger (validated, stored encrypted,
--     masked for operators). The rule is the platform setting passenger_id_required (default ON).
--     Only the type and the number are collected: no document image is ever uploaded.
--   * get_trip_manifest also says whether booking is closed for the trip.
--   * log_manifest_export: the passenger list can be downloaded/shared only after booking has closed;
--     every export is audited (who, which trip, how many passengers, download/share/print).
-- =========================================================================
insert into public.platform_settings (key, value) values ('passenger_id_required', 'true')
on conflict (key) do nothing;

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
  v_id_required boolean := private.setting_bool('passenger_id_required', true);
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

    -- Identity document (type + number only, never an image): required for every passenger unless an
    -- admin switched the rule off. The number is validated and stored encrypted; a missing or invalid
    -- document raises, which rolls the whole booking back (the seat hold is untouched).
    if coalesce(btrim(v_passenger ->> 'doc_number'), '') <> '' and coalesce(btrim(v_passenger ->> 'doc_type'), '') <> '' then
      perform private.store_passenger_identity(v_passenger_id, v_passenger ->> 'doc_type', v_passenger ->> 'doc_number');
    elsif v_id_required or coalesce(btrim(v_passenger ->> 'doc_number'), '') <> '' or coalesce(btrim(v_passenger ->> 'doc_type'), '') <> '' then
      raise exception 'document_required: an ID type and number are required for every passenger';
    end if;

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

create or replace function public.get_trip_manifest(
  p_trip_id uuid,
  p_filter text default 'all',
  p_search text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips := private.trip_for_staff(p_trip_id, false);
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_rows jsonb;
begin
  if p_filter not in ('all', 'yet_to_board', 'boarded', 'cancelled', 'exceptions') then
    raise exception 'Unknown filter %', p_filter;
  end if;

  select coalesce(jsonb_agg(m.j order by m.deck, m.row_no, m.col_no), '[]'::jsonb) into v_rows
  from (
    select s.deck, s.row_no, s.col_no,
      jsonb_build_object(
        'booking_item_id', bi.id,
        'booking_reference', b.booking_reference,
        'seat_code', s.seat_code,
        'passenger_name', p.full_name,
        'passenger_age', p.age,
        'passenger_gender', p.gender,
        'passenger_phone', p.phone,
        'boarding_point', bp.name,
        'dropping_point', dp.name,
        'booking_status', bi.status,
        'payment_status', coalesce(pay.status::text, 'pending'),
        'refund_status', rf.status,
        'doc_type', pi.doc_type,
        'doc_label', case when pi.passenger_id is null then null else private.document_label(pi.doc_type) end,
        'doc_masked', case when pi.passenger_id is null then null else private.mask_document(pi.doc_type, pi.last4) end,
        'doc_verification', pi.verification_status,
        'boarding_status', case when ts.status = 'boarded' then 'boarded' else coalesce(pb.status, 'not_boarded') end,
        'verified_at', pb.verified_at,
        'boarded_at', pb.boarded_at,
        'exception_reason', pb.exception_reason
      ) as j,
      bi.status as item_status,
      case when ts.status = 'boarded' then 'boarded' else coalesce(pb.status, 'not_boarded') end as board_status,
      (rf.status = 'pending' or coalesce(pay.status::text, 'pending') in ('pending', 'failed')) as money_exception
    from public.booking_items bi
    join public.bookings b on b.id = bi.booking_id
    join public.trip_seats ts on ts.id = bi.trip_seat_id
    join public.seats s on s.id = ts.seat_id
    left join public.passengers p on p.id = bi.passenger_id
    left join public.passenger_identity pi on pi.passenger_id = p.id
    left join public.passenger_boarding pb on pb.booking_item_id = bi.id
    join public.boarding_points bp on bp.id = bi.boarding_point_id
    join public.dropping_points dp on dp.id = bi.dropping_point_id
    left join lateral (
      select py.status from public.orders o join public.payments py on py.order_id = o.id
      where o.orderable_type = 'booking' and o.orderable_id = b.id
      order by py.created_at desc limit 1) pay on true
    left join lateral (
      select r.status from public.orders o join public.payments py on py.order_id = o.id
      join public.refunds r on r.payment_id = py.id
      where o.orderable_type = 'booking' and o.orderable_id = b.id
      order by r.created_at desc limit 1) rf on true
    where bi.trip_id = p_trip_id
      and (
        v_search is null
        or p.full_name ilike '%' || v_search || '%'
        or b.booking_reference ilike '%' || v_search || '%'
        or s.seat_code ilike v_search
        or p.phone like '%' || v_search || '%'
      )
  ) m
  where case p_filter
    when 'all' then m.item_status in ('confirmed', 'completed')
    when 'yet_to_board' then m.item_status in ('confirmed', 'completed') and m.board_status in ('not_boarded', 'verified')
    when 'boarded' then m.board_status = 'boarded'
    when 'cancelled' then m.item_status in ('cancelled', 'expired', 'failed')
    else m.board_status = 'exception' or m.item_status = 'payment_pending' or coalesce(m.money_exception, false)
  end;

  return jsonb_build_object(
    'trip_id', v_trip.id, 'trip_status', v_trip.status, 'filter', p_filter, 'passengers', v_rows,
    'departure_at', v_trip.departure_at,
    'booking_close_at', coalesce(v_trip.booking_close_at, v_trip.departure_at),
    -- booking is closed once the trip is no longer open for sale (cut-off passed, boarding/departed, cancelled)
    'booking_closed', not private.trip_is_open_for_booking(p_trip_id));
end;
$$;
revoke execute on function public.get_trip_manifest(uuid, text, text) from public, anon;
grant execute on function public.get_trip_manifest(uuid, text, text) to authenticated;

create or replace function public.log_manifest_export(p_trip_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips := private.trip_for_staff(p_trip_id, false);
  v_count int;
begin
  if p_action not in ('download', 'share', 'print') then raise exception 'Unknown action %', p_action; end if;
  if private.trip_is_open_for_booking(p_trip_id) then
    raise exception 'booking_not_closed: the passenger list can be exported once booking has closed for this trip';
  end if;
  select count(*) into v_count from public.booking_items where trip_id = p_trip_id and status in ('confirmed', 'completed');
  perform private.write_audit('manifest.export', 'bus_trip', p_trip_id, null,
    jsonb_build_object('action', p_action, 'passengers', v_count, 'trip_status', v_trip.status));
  return jsonb_build_object('ok', true, 'passengers', v_count);
end;
$$;
revoke execute on function public.log_manifest_export(uuid, text) from public, anon;
grant execute on function public.log_manifest_export(uuid, text) to authenticated;
