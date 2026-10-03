-- =========================================================================
-- Passenger identity + boarding verification.
--
--   * passenger_identity: document type + number per passenger. The number is stored
--     ENCRYPTED (pgcrypto, key in private.app_secrets); only the last 4 characters are kept
--     in clear for masking. No role can read the table: access is through definer RPCs.
--   * get_trip_manifest: name, seat, reference, points, phone, statuses, MASKED document,
--     verification and boarding status; search + filters. Operators see only their trips.
--   * reveal_passenger_document: operator_admin only, reason required, audited (the audit row
--     never contains the number).
--   * boarding: not_boarded -> verified -> boarded, plus exception; duplicate boarding is
--     blocked under a row lock; a paid booking is NOT boarded until someone verifies it;
--     every action is in boarding_events + audit_logs; correction is operator_admin only.
--   * verify_ticket_qr: rejected scans are now PERSISTED (they used to roll back with the error).
--   * customers attach documents to their own booking (attach_passenger_documents).
-- =========================================================================

insert into private.app_secrets (key, value)
values ('id_doc_key', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- tables
-- ---------------------------------------------------------------------
create table public.passenger_identity (
  passenger_id uuid primary key references public.passengers (id) on delete cascade,
  doc_type text not null check (doc_type in ('aadhaar', 'pan', 'passport', 'driving_licence', 'voter_id', 'other')),
  doc_number_enc bytea not null,
  last4 text not null,
  verification_status text not null default 'unverified'
    check (verification_status in ('unverified', 'verified', 'mismatch', 'exception')),
  verified_by uuid references public.profiles (id),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger set_updated_at before update on public.passenger_identity
  for each row execute function private.set_updated_at();
alter table public.passenger_identity enable row level security;
revoke all on public.passenger_identity from anon, authenticated;

create table public.passenger_boarding (
  booking_item_id uuid primary key references public.booking_items (id) on delete cascade,
  status text not null default 'not_boarded' check (status in ('not_boarded', 'verified', 'boarded', 'exception')),
  doc_checked boolean not null default false,
  verified_by uuid references public.profiles (id),
  verified_at timestamptz,
  boarded_by uuid references public.profiles (id),
  boarded_at timestamptz,
  exception_reason text,
  updated_at timestamptz not null default now()
);
create trigger set_updated_at before update on public.passenger_boarding
  for each row execute function private.set_updated_at();
alter table public.passenger_boarding enable row level security;
revoke all on public.passenger_boarding from anon, authenticated;

alter table public.boarding_events drop constraint boarding_events_result_check;
alter table public.boarding_events add constraint boarding_events_result_check check (result in (
  'boarded', 'rejected_already_used', 'rejected_invalid', 'rejected_wrong_trip',
  'verified', 'exception', 'corrected'));

-- ---------------------------------------------------------------------
-- document helpers
-- ---------------------------------------------------------------------
create or replace function private.normalize_document(p_type text, p_number text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := upper(regexp_replace(coalesce(p_number, ''), '[\s-]', '', 'g'));
begin
  if (p_type = 'aadhaar' and v !~ '^[0-9]{12}$')
     or (p_type = 'pan' and v !~ '^[A-Z]{5}[0-9]{4}[A-Z]$')
     or (p_type = 'passport' and v !~ '^[A-Z][0-9]{7}$')
     or (p_type = 'voter_id' and v !~ '^[A-Z]{3}[0-9]{7}$')
     or (p_type in ('driving_licence', 'other') and v !~ '^[A-Z0-9/]{4,20}$')
     or p_type not in ('aadhaar', 'pan', 'passport', 'driving_licence', 'voter_id', 'other') then
    raise exception 'invalid_document: the % number is not in a valid format', coalesce(p_type, 'document');
  end if;
  return v;
end;
$$;

create or replace function private.mask_document(p_type text, p_last4 text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
    when 'aadhaar' then 'XXXX-XXXX-' || p_last4
    when 'pan' then 'XXXXXX' || p_last4
    else 'XXXX' || p_last4
  end;
$$;

create or replace function private.document_label(p_type text)
returns text language sql immutable set search_path = '' as $$
  select case p_type
    when 'aadhaar' then 'Aadhaar' when 'pan' then 'PAN' when 'passport' then 'Passport'
    when 'driving_licence' then 'Driving licence' when 'voter_id' then 'Voter ID' else 'Other ID' end;
$$;

revoke execute on function private.normalize_document(text, text) from public, anon, authenticated;
revoke execute on function private.mask_document(text, text) from public, anon, authenticated;
revoke execute on function private.document_label(text) from public, anon, authenticated;

create or replace function private.store_passenger_identity(p_passenger_id uuid, p_type text, p_number text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_norm text := private.normalize_document(p_type, p_number);
  v_key text;
begin
  select value into v_key from private.app_secrets where key = 'id_doc_key';
  insert into public.passenger_identity (passenger_id, doc_type, doc_number_enc, last4)
  values (p_passenger_id, p_type, extensions.pgp_sym_encrypt(v_norm, v_key), right(v_norm, 4))
  on conflict (passenger_id) do update
    set doc_type = excluded.doc_type,
        doc_number_enc = excluded.doc_number_enc,
        last4 = excluded.last4,
        verification_status = 'unverified', verified_by = null, verified_at = null;
end;
$$;
revoke execute on function private.store_passenger_identity(uuid, text, text) from public, anon, authenticated;

-- Customer attaches documents to their own booking: [{"seat_code":"1A","doc_type":"aadhaar","doc_number":"..."}]
create or replace function public.attach_passenger_documents(p_booking_reference text, p_docs jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_booking public.bookings;
  d jsonb;
  v_pid uuid;
  n integer := 0;
begin
  select * into v_booking from public.bookings where booking_reference = p_booking_reference;
  if v_booking.id is null or v_booking.customer_id <> (select auth.uid()) then
    raise exception 'Booking not found';
  end if;
  if v_booking.status not in ('payment_pending', 'confirmed') then
    raise exception 'Documents can only be added to a pending or confirmed booking';
  end if;

  for d in select * from jsonb_array_elements(coalesce(p_docs, '[]'::jsonb)) loop
    select bi.passenger_id into v_pid
    from public.booking_items bi
    join public.trip_seats ts on ts.id = bi.trip_seat_id
    join public.seats s on s.id = ts.seat_id
    where bi.booking_id = v_booking.id and s.seat_code = d ->> 'seat_code' and bi.passenger_id is not null;
    if v_pid is null then raise exception 'No passenger on seat %', d ->> 'seat_code'; end if;
    perform private.store_passenger_identity(v_pid, d ->> 'doc_type', d ->> 'doc_number');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.attach_passenger_documents(text, jsonb) from public, anon;
grant execute on function public.attach_passenger_documents(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- access helper
-- ---------------------------------------------------------------------
create or replace function private.trip_for_staff(p_trip_id uuid, p_write boolean default false)
returns public.bus_trips
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  if not (private.is_operator_staff(v_trip.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  if p_write then
    if not private.is_platform_admin() and not private.operator_service_active(v_trip.operator_id, 'bus') then
      raise exception 'service_inactive: the Bus service is not active for this operator';
    end if;
    if v_trip.status not in ('scheduled', 'boarding', 'departed') then
      raise exception 'trip_not_boardable: this trip is % and cannot be boarded', v_trip.status;
    end if;
  end if;
  return v_trip;
end;
$$;
revoke execute on function private.trip_for_staff(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- manifest
-- ---------------------------------------------------------------------
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

  return jsonb_build_object('trip_id', v_trip.id, 'trip_status', v_trip.status, 'filter', p_filter, 'passengers', v_rows);
end;
$$;
revoke execute on function public.get_trip_manifest(uuid, text, text) from public, anon;
grant execute on function public.get_trip_manifest(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- boarding state machine
-- ---------------------------------------------------------------------
create or replace function private.log_boarding(p_item uuid, p_trip uuid, p_result text)
returns void language sql security definer set search_path = '' as $$
  insert into public.boarding_events (booking_item_id, trip_id, scanned_by, result)
  values (p_item, p_trip, (select auth.uid()), p_result);
$$;
revoke execute on function private.log_boarding(uuid, uuid, text) from public, anon, authenticated;

-- Locks the seat and returns the item; raises if the item is not on this operator's trips.
create or replace function private.lock_boarding_item(p_item uuid)
returns table (item_id uuid, trip_id uuid, trip_seat_id uuid, item_status public.booking_status, seat_status public.trip_seat_status, passenger_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
    select bi.id, bi.trip_id, bi.trip_seat_id, bi.status, ts.status, bi.passenger_id
    from public.booking_items bi join public.trip_seats ts on ts.id = bi.trip_seat_id
    where bi.id = p_item for update of ts;
  if not found then raise exception 'Ticket not found'; end if;
end;
$$;
revoke execute on function private.lock_boarding_item(uuid) from public, anon, authenticated;

create or replace function public.verify_passenger_boarding(
  p_booking_item_id uuid,
  p_doc_checked boolean default false,
  p_via text default 'manual'
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v record;
  v_trip public.bus_trips;
begin
  select * into v from private.lock_boarding_item(p_booking_item_id);
  v_trip := private.trip_for_staff(v.trip_id, true);

  if v.seat_status = 'boarded' then
    perform private.log_boarding(v.item_id, v.trip_id, 'rejected_already_used');
    return jsonb_build_object('ok', false, 'code', 'already_boarded', 'message', 'This passenger has already boarded.');
  end if;
  if v.item_status <> 'confirmed' then
    perform private.log_boarding(v.item_id, v.trip_id, 'rejected_invalid');
    return jsonb_build_object('ok', false, 'code', 'not_confirmed', 'message', 'This booking is not confirmed (' || v.item_status || ').');
  end if;
  -- paid is a precondition, never a substitute for verification
  if not exists (
    select 1 from public.booking_items bi
    join public.orders o on o.orderable_type = 'booking' and o.orderable_id = bi.booking_id
    join public.payments py on py.order_id = o.id and py.status = 'captured'
    where bi.id = v.item_id) then
    perform private.log_boarding(v.item_id, v.trip_id, 'rejected_invalid');
    return jsonb_build_object('ok', false, 'code', 'not_paid', 'message', 'No captured payment was found for this booking.');
  end if;

  insert into public.passenger_boarding (booking_item_id, status, doc_checked, verified_by, verified_at)
  values (v.item_id, 'verified', coalesce(p_doc_checked, false), (select auth.uid()), now())
  on conflict (booking_item_id) do update
    set status = 'verified', doc_checked = coalesce(p_doc_checked, false),
        verified_by = (select auth.uid()), verified_at = now(), exception_reason = null;

  if p_doc_checked and v.passenger_id is not null then
    update public.passenger_identity
       set verification_status = 'verified', verified_by = (select auth.uid()), verified_at = now()
     where passenger_id = v.passenger_id;
  end if;

  perform private.log_boarding(v.item_id, v.trip_id, 'verified');
  perform private.write_audit('boarding.verify', 'booking_item', v.item_id, null,
    jsonb_build_object('via', p_via, 'doc_checked', coalesce(p_doc_checked, false)));
  return jsonb_build_object('ok', true, 'status', 'verified');
end;
$$;

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

-- manual confirmation requires the verification step first
create or replace function public.confirm_boarding(p_booking_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state text;
  v record;
begin
  select * into v from private.lock_boarding_item(p_booking_item_id);
  perform private.trip_for_staff(v.trip_id, true);
  select status into v_state from public.passenger_boarding where booking_item_id = p_booking_item_id;
  if v.seat_status <> 'boarded' and coalesce(v_state, 'not_boarded') <> 'verified' then
    return jsonb_build_object('ok', false, 'code', 'not_verified', 'message', 'Verify the passenger before confirming boarding.');
  end if;
  return private.do_board(p_booking_item_id, 'manual');
end;
$$;

create or replace function public.mark_boarding_exception(p_booking_item_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v record;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into v from private.lock_boarding_item(p_booking_item_id);
  perform private.trip_for_staff(v.trip_id, true);
  if v.seat_status = 'boarded' then
    return jsonb_build_object('ok', false, 'code', 'already_boarded', 'message', 'This passenger has already boarded.');
  end if;
  insert into public.passenger_boarding (booking_item_id, status, exception_reason, verified_by, verified_at)
  values (v.item_id, 'exception', p_reason, (select auth.uid()), now())
  on conflict (booking_item_id) do update
    set status = 'exception', exception_reason = p_reason, verified_by = (select auth.uid()), verified_at = now();
  if v.passenger_id is not null then
    update public.passenger_identity set verification_status = 'exception', verified_by = (select auth.uid()), verified_at = now()
     where passenger_id = v.passenger_id;
  end if;
  perform private.log_boarding(v.item_id, v.trip_id, 'exception');
  perform private.write_audit('boarding.exception', 'booking_item', v.item_id, null, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'status', 'exception');
end;
$$;

-- an authorized correction (operator admin only): boarded -> back to booked, verification cleared
create or replace function public.correct_boarding(p_booking_item_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v record;
  v_trip public.bus_trips;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required'; end if;
  select * into v from private.lock_boarding_item(p_booking_item_id);
  v_trip := private.trip_for_staff(v.trip_id, true);
  if not (private.is_operator_admin(v_trip.operator_id) or private.is_platform_admin()) then
    raise exception 'Only the operator admin can correct boarding';
  end if;
  if v.seat_status = 'boarded' then
    update public.trip_seats set status = 'booked' where id = v.trip_seat_id;
  end if;
  insert into public.passenger_boarding (booking_item_id, status) values (v.item_id, 'not_boarded')
  on conflict (booking_item_id) do update
    set status = 'not_boarded', doc_checked = false, boarded_at = null, boarded_by = null,
        verified_at = null, verified_by = null, exception_reason = null;
  perform private.log_boarding(v.item_id, v.trip_id, 'corrected');
  perform private.write_audit('boarding.correct', 'booking_item', v.item_id, null, jsonb_build_object('reason', p_reason));
  return jsonb_build_object('ok', true, 'status', 'not_boarded');
end;
$$;

-- QR scan: same checks as before, but a rejected scan is RETURNED (and its event kept),
-- instead of raising and rolling the event back. Malformed/tampered codes still raise.
create or replace function public.verify_ticket_qr(p_qr_payload text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_parts text[];
  v_item_id uuid;
  v_secret text;
  v_result jsonb;
  v_board jsonb;
begin
  v_parts := regexp_split_to_array(p_qr_payload, '\.');
  if array_length(v_parts, 1) <> 2 then raise exception 'Malformed ticket code'; end if;
  begin
    v_item_id := v_parts[1]::uuid;
  exception when others then
    raise exception 'Malformed ticket code';
  end;
  select value into v_secret from private.app_secrets where key = 'qr_hmac_key';
  if v_parts[2] <> encode(extensions.hmac(v_parts[1], v_secret, 'sha256'), 'hex') then
    raise exception 'Invalid or tampered ticket code';
  end if;

  perform 1 from public.booking_items where id = v_item_id;
  if not found then raise exception 'Ticket not found'; end if;

  v_board := private.do_board(v_item_id, 'qr');
  if (v_board ->> 'ok')::boolean is not true then
    return v_board;
  end if;

  select jsonb_build_object(
    'ok', true,
    'booking_item_id', bi.id,
    'passenger_name', p.full_name,
    'seat_code', s.seat_code,
    'boarding_point', bp.name,
    'dropping_point', dp.name
  ) into v_result
  from public.booking_items bi
  left join public.passengers p on p.id = bi.passenger_id
  join public.trip_seats ts on ts.id = bi.trip_seat_id
  join public.seats s on s.id = ts.seat_id
  join public.boarding_points bp on bp.id = bi.boarding_point_id
  join public.dropping_points dp on dp.id = bi.dropping_point_id
  where bi.id = v_item_id;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------
-- audited full-number reveal (operator admin only)
-- ---------------------------------------------------------------------
create or replace function public.reveal_passenger_document(p_booking_item_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item record;
  v_trip public.bus_trips;
  v_pi public.passenger_identity;
  v_key text;
begin
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'A reason of at least 5 characters is required';
  end if;
  select bi.id, bi.trip_id, bi.passenger_id into v_item from public.booking_items bi where bi.id = p_booking_item_id;
  if v_item.id is null then raise exception 'Ticket not found'; end if;
  v_trip := private.trip_for_staff(v_item.trip_id, false);
  if not (private.is_operator_admin(v_trip.operator_id) or private.is_platform_admin()) then
    raise exception 'Only the operator admin can view the full document number';
  end if;
  select * into v_pi from public.passenger_identity where passenger_id = v_item.passenger_id;
  if v_pi.passenger_id is null then raise exception 'No document on file'; end if;

  select value into v_key from private.app_secrets where key = 'id_doc_key';
  -- the audit row records who/why/which passenger — never the number itself
  perform private.write_audit('passenger_document.reveal', 'passenger', v_item.passenger_id, null,
    jsonb_build_object('reason', p_reason, 'booking_item_id', v_item.id, 'doc_type', v_pi.doc_type));
  return jsonb_build_object(
    'doc_type', v_pi.doc_type,
    'doc_label', private.document_label(v_pi.doc_type),
    'doc_number', extensions.pgp_sym_decrypt(v_pi.doc_number_enc, v_key));
end;
$$;

revoke execute on function public.verify_passenger_boarding(uuid, boolean, text) from public, anon;
revoke execute on function public.confirm_boarding(uuid) from public, anon;
revoke execute on function public.mark_boarding_exception(uuid, text) from public, anon;
revoke execute on function public.correct_boarding(uuid, text) from public, anon;
revoke execute on function public.reveal_passenger_document(uuid, text) from public, anon;
revoke execute on function public.verify_ticket_qr(text) from public, anon;
grant execute on function public.verify_passenger_boarding(uuid, boolean, text) to authenticated;
grant execute on function public.confirm_boarding(uuid) to authenticated;
grant execute on function public.mark_boarding_exception(uuid, text) to authenticated;
grant execute on function public.correct_boarding(uuid, text) to authenticated;
grant execute on function public.reveal_passenger_document(uuid, text) to authenticated;
grant execute on function public.verify_ticket_qr(text) to authenticated;

-- operators' ops channel also hears about verification changes
create or replace function private.ping_trip_ops_boarding()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip uuid;
begin
  for v_trip in
    select distinct bi.trip_id from new_rows n join public.booking_items bi on bi.id = n.booking_item_id
  loop
    begin
      perform realtime.send(jsonb_build_object('kind', 'boarding', 'at', now()), 'changed', 'trip:' || v_trip || ':ops', true);
    exception when others then null; end;
  end loop;
  return null;
end;
$$;
revoke execute on function private.ping_trip_ops_boarding() from public, anon, authenticated;
create trigger ping_ops_pboarding_ins after insert on public.passenger_boarding
  referencing new table as new_rows for each statement execute function private.ping_trip_ops_boarding();
create trigger ping_ops_pboarding_upd after update on public.passenger_boarding
  referencing new table as new_rows for each statement execute function private.ping_trip_ops_boarding();
