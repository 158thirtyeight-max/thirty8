-- =========================================================================
-- Operator manifest, and QR ticket issuance/verification.
--
-- QR payload format: "<booking_item_id>.<hex hmac-sha256>", signed with the
-- server-only key in private.app_secrets. Verification recomputes the HMAC
-- (never trusts the client-supplied signature) and is the only way a
-- booking_item's trip_seat can move to 'boarded'.
-- =========================================================================

create or replace function public.generate_manifest(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_operator_id uuid;
  v_result jsonb;
begin
  select operator_id into v_operator_id from public.bus_trips where id = p_trip_id;
  if v_operator_id is null then
    raise exception 'Trip not found';
  end if;
  if not private.is_operator_staff(v_operator_id) and not private.is_platform_admin() then
    raise exception 'Not authorized to view this manifest';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'booking_item_id', bi.id,
    'booking_reference', b.booking_reference,
    'seat_code', s.seat_code,
    'seat_status', ts.status,
    'passenger_name', p.full_name,
    'passenger_age', p.age,
    'passenger_gender', p.gender,
    'passenger_phone', p.phone,
    'boarding_point', bp.name,
    'dropping_point', dp.name
  ) order by s.deck, s.row_no, s.col_no), '[]'::jsonb)
  into v_result
  from public.booking_items bi
  join public.bookings b on b.id = bi.booking_id
  join public.trip_seats ts on ts.id = bi.trip_seat_id
  join public.seats s on s.id = ts.seat_id
  left join public.passengers p on p.id = bi.passenger_id
  join public.boarding_points bp on bp.id = bi.boarding_point_id
  join public.dropping_points dp on dp.id = bi.dropping_point_id
  where bi.trip_id = p_trip_id
    and bi.status = 'confirmed';

  return jsonb_build_object('trip_id', p_trip_id, 'passengers', v_result);
end;
$$;

-- Customer generates their own QR code payload to display; the operator app
-- never needs to call this, only render a QR image from the returned string.
create or replace function public.generate_ticket_qr(p_booking_item_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_status public.booking_status;
  v_secret text;
  v_sig text;
begin
  select b.customer_id, bi.status into v_owner, v_status
  from public.booking_items bi
  join public.bookings b on b.id = bi.booking_id
  where bi.id = p_booking_item_id;

  if v_owner is null then
    raise exception 'Ticket not found';
  end if;
  if v_owner <> (select auth.uid()) and not private.is_platform_admin() then
    raise exception 'Not authorized';
  end if;
  if v_status <> 'confirmed' then
    raise exception 'Ticket is not in a boardable state (status: %)', v_status;
  end if;

  select value into v_secret from private.app_secrets where key = 'qr_hmac_key';
  v_sig := encode(extensions.hmac(p_booking_item_id::text, v_secret, 'sha256'), 'hex');

  return p_booking_item_id::text || '.' || v_sig;
end;
$$;

-- Operator scans a passenger's QR code. Validates the signature, checks the
-- seat hasn't already been boarded, marks it boarded, and logs every scan
-- attempt (including rejections) to boarding_events for the operator's audit trail.
create or replace function public.verify_ticket_qr(p_qr_payload text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parts text[];
  v_booking_item_id uuid;
  v_sig text;
  v_secret text;
  v_expected_sig text;
  v_item record;
  v_result jsonb;
begin
  v_parts := regexp_split_to_array(p_qr_payload, '\.');
  if array_length(v_parts, 1) <> 2 then
    raise exception 'Malformed ticket code';
  end if;

  begin
    v_booking_item_id := v_parts[1]::uuid;
  exception when others then
    raise exception 'Malformed ticket code';
  end;
  v_sig := v_parts[2];

  select value into v_secret from private.app_secrets where key = 'qr_hmac_key';
  v_expected_sig := encode(extensions.hmac(v_parts[1], v_secret, 'sha256'), 'hex');

  if v_sig <> v_expected_sig then
    raise exception 'Invalid or tampered ticket code';
  end if;

  select bi.id, bi.trip_id, bi.status as item_status, ts.id as trip_seat_id,
         ts.status as seat_status, t.operator_id
  into v_item
  from public.booking_items bi
  join public.trip_seats ts on ts.id = bi.trip_seat_id
  join public.bus_trips t on t.id = bi.trip_id
  where bi.id = v_booking_item_id
  for update of ts;

  if v_item.id is null then
    raise exception 'Ticket not found';
  end if;

  if not private.is_operator_staff(v_item.operator_id) and not private.is_platform_admin() then
    raise exception 'Not authorized to scan tickets for this operator';
  end if;

  if v_item.seat_status = 'boarded' then
    insert into public.boarding_events (booking_item_id, trip_id, scanned_by, result)
    values (v_booking_item_id, v_item.trip_id, (select auth.uid()), 'rejected_already_used');
    raise exception 'Ticket already used';
  end if;

  if v_item.item_status <> 'confirmed' then
    insert into public.boarding_events (booking_item_id, trip_id, scanned_by, result)
    values (v_booking_item_id, v_item.trip_id, (select auth.uid()), 'rejected_invalid');
    raise exception 'Ticket is not valid for boarding (status: %)', v_item.item_status;
  end if;

  update public.trip_seats set status = 'boarded' where id = v_item.trip_seat_id;

  insert into public.boarding_events (booking_item_id, trip_id, scanned_by, result)
  values (v_booking_item_id, v_item.trip_id, (select auth.uid()), 'boarded');

  select jsonb_build_object(
    'booking_item_id', bi.id,
    'passenger_name', p.full_name,
    'seat_code', s.seat_code,
    'boarding_point', bp.name,
    'dropping_point', dp.name
  )
  into v_result
  from public.booking_items bi
  left join public.passengers p on p.id = bi.passenger_id
  join public.trip_seats ts on ts.id = bi.trip_seat_id
  join public.seats s on s.id = ts.seat_id
  join public.boarding_points bp on bp.id = bi.boarding_point_id
  join public.dropping_points dp on dp.id = bi.dropping_point_id
  where bi.id = v_booking_item_id;

  return v_result;
end;
$$;

revoke execute on function public.generate_manifest(uuid) from public, anon;
revoke execute on function public.generate_ticket_qr(uuid) from public, anon;
revoke execute on function public.verify_ticket_qr(text) from public, anon;
grant execute on function public.generate_manifest(uuid) to authenticated;
grant execute on function public.generate_ticket_qr(uuid) to authenticated;
grant execute on function public.verify_ticket_qr(text) to authenticated;
