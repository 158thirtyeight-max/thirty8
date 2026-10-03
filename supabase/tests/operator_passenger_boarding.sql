-- =========================================================================
-- Checks for 20261002001800_passenger_identity_boarding.sql
--   * identity documents: validated, encrypted at rest, unreadable by every client role
--   * manifest: phone + masked document for the trip's operator only; search and filters
--   * boarding: not_boarded -> verified -> boarded, duplicate blocked, paid != boarded,
--     exceptions, authorized correction, QR rejections persisted
--   * full-number reveal: operator admin only, reason required, audited without the number
--   * service gate (disabled Bus service cannot board; history stays readable)
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

create function pg_temp.item_of(p_code text) returns uuid language sql security definer as $f$
  select bi.id from public.booking_items bi
  join public.trip_seats ts on ts.id = bi.trip_seat_id join public.seats s on s.id = ts.seat_id
  where bi.trip_id = (select id from t_ref where tag = 'TRIP') and s.seat_code = p_code
  order by bi.created_at desc limit 1 $f$;
grant execute on function pg_temp.item_of(text) to authenticated;

create function pg_temp.pay(p_tag text) returns void language plpgsql security definer as $f$
declare o public.orders;
begin
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_' || p_tag, o.amount_cents);
end $f$;
grant execute on function pg_temp.pay(text) to authenticated;

-- an operator staff (non-admin) user
insert into auth.users (id, email) values ('99999999-0000-0000-0000-000000000009', 'staff@test.invalid');
insert into public.user_roles (user_id, role, operator_id)
  values ('99999999-0000-0000-0000-000000000009', 'operator_staff', (select id from t_ops where tag = 'A'));

-- C1 books seat 1 (A1) and C2 books seat 2 (A2); both paid. C1 also leaves seat 3 unpaid.
do $$
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O1', 1);
  perform pg_temp.book('eeeeeeee-0000-0000-0000-00000000000e', 'O2', 2);
  perform pg_temp.as_server();
  perform pg_temp.pay('O1');
  perform pg_temp.pay('O2');
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'O3', 3);   -- stays payment_pending
  perform pg_temp.as_server();
end $$;

-- ---- 1. identity documents -------------------------------------------------
do $$
declare
  v_ref text := (select b.booking_reference from public.bookings b join public.booking_items bi on bi.booking_id = b.id where bi.id = pg_temp.item_of((select seat_code from public.seats s join public.trip_seats ts on ts.seat_id = s.id join public.booking_items bi on bi.trip_seat_id = ts.id join public.bookings b on b.id = bi.booking_id where b.customer_id = 'dddddddd-0000-0000-0000-00000000000d' and bi.status = 'confirmed' limit 1)));
  v_code text := (select s.seat_code from public.seats s join public.trip_seats ts on ts.seat_id = s.id join public.booking_items bi on bi.trip_seat_id = ts.id join public.bookings b on b.id = bi.booking_id where b.customer_id = 'dddddddd-0000-0000-0000-00000000000d' and bi.status = 'confirmed' limit 1);
  v_ref2 text := (select b.booking_reference from public.bookings b where b.customer_id = 'eeeeeeee-0000-0000-0000-00000000000e' limit 1);
  v_code2 text := (select s.seat_code from public.seats s join public.trip_seats ts on ts.seat_id = s.id join public.booking_items bi on bi.trip_seat_id = ts.id join public.bookings b on b.id = bi.booking_id where b.customer_id = 'eeeeeeee-0000-0000-0000-00000000000e' limit 1);
  n int;
begin
  insert into t_ref values ('CODE1', (select id from public.seats where seat_code = v_code limit 1));
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  n := public.attach_passenger_documents(v_ref, jsonb_build_array(jsonb_build_object('seat_code', v_code, 'doc_type', 'aadhaar', 'doc_number', '1234 5678 9012')));
  if n <> 1 then raise exception 'FAIL 1a: one document should be stored'; end if;

  begin
    perform public.attach_passenger_documents(v_ref, jsonb_build_array(jsonb_build_object('seat_code', v_code, 'doc_type', 'aadhaar', 'doc_number', '123')));
    raise exception 'FAIL 1b: invalid aadhaar accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'invalid_document%' then raise exception 'FAIL 1c: wrong error %', sqlerrm; end if;
  end;

  -- another customer cannot attach documents to C1's booking
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  begin
    perform public.attach_passenger_documents(v_ref, '[]'::jsonb);
    raise exception 'FAIL 1d: customer 2 touched customer 1 booking';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  -- customer 2 documents: a PAN
  n := public.attach_passenger_documents(v_ref2, jsonb_build_array(jsonb_build_object('seat_code', v_code2, 'doc_type', 'pan', 'doc_number', 'abcde1234f')));
  perform pg_temp.as_server();
end $$;

-- stored encrypted, last4 clear, nothing readable by any client role
do $$
declare v_enc bytea; v_last4 text;
begin
  select doc_number_enc, last4 into v_enc, v_last4 from public.passenger_identity where doc_type = 'aadhaar';
  if v_last4 <> '9012' then raise exception 'FAIL 1e: last4 %', v_last4; end if;
  if position('123456789012'::bytea in v_enc) > 0 or encode(v_enc, 'escape') like '%123456789012%' then
    raise exception 'FAIL 1f: document number stored in clear';
  end if;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform 1 from public.passenger_identity; raise exception 'FAIL 1g: operator read passenger_identity';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform 1 from public.passenger_identity; raise exception 'FAIL 1h: customer read passenger_identity';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  begin perform 1 from public.passenger_identity; raise exception 'FAIL 1i: admin client read passenger_identity';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();
end $$;

-- ---- 2. manifest -------------------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  m jsonb; p jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  m := public.get_trip_manifest(v_trip);
  if jsonb_array_length(m -> 'passengers') <> 2 then raise exception 'FAIL 2a: all = 2 confirmed passengers, got %', jsonb_array_length(m -> 'passengers'); end if;

  select e into p from jsonb_array_elements(m -> 'passengers') e where e ->> 'doc_type' = 'aadhaar';
  if p ->> 'doc_masked' <> 'XXXX-XXXX-9012' then raise exception 'FAIL 2b: aadhaar mask %', p ->> 'doc_masked'; end if;
  if p ->> 'passenger_phone' <> '9876543210' or p ->> 'passenger_name' is null or p ->> 'booking_reference' is null
     or p ->> 'boarding_point' is null or p ->> 'dropping_point' is null then
    raise exception 'FAIL 2c: manifest row incomplete %', p;
  end if;
  if p ->> 'payment_status' <> 'captured' or p ->> 'booking_status' <> 'confirmed' or p ->> 'boarding_status' <> 'not_boarded' then
    raise exception 'FAIL 2d: statuses %', p;
  end if;
  if m::text like '%123456789012%' or m::text like '%ABCDE1234F%' then raise exception 'FAIL 2e: full document number in the manifest'; end if;
  if not exists (select 1 from jsonb_array_elements(m -> 'passengers') e where e ->> 'doc_masked' = 'XXXXXX234F') then
    raise exception 'FAIL 2f: PAN mask';
  end if;

  -- search
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'all', 'Pax 2')) -> 'passengers') <> 1 then raise exception 'FAIL 2g: search by name'; end if;
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'all', (p ->> 'booking_reference'))) -> 'passengers') <> 1 then raise exception 'FAIL 2h: search by reference'; end if;
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'all', (p ->> 'seat_code'))) -> 'passengers') <> 1 then raise exception 'FAIL 2i: search by seat'; end if;
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'all', '9876543210')) -> 'passengers') <> 2 then raise exception 'FAIL 2j: search by phone'; end if;
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'all', 'nobody-here')) -> 'passengers') <> 0 then raise exception 'FAIL 2k: no match'; end if;

  -- filters: the unpaid booking is an exception, not a passenger
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'exceptions')) -> 'passengers') <> 1 then raise exception 'FAIL 2l: payment exception'; end if;
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'yet_to_board')) -> 'passengers') <> 2 then raise exception 'FAIL 2m: yet to board'; end if;
  if jsonb_array_length((public.get_trip_manifest(v_trip, 'boarded')) -> 'passengers') <> 0 then raise exception 'FAIL 2n: boarded'; end if;
  begin perform public.get_trip_manifest(v_trip, 'bogus'); raise exception 'FAIL 2o: unknown filter accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- isolation
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_trip_manifest(v_trip); raise exception 'FAIL 2p: operator B read the manifest';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.get_trip_manifest(v_trip); raise exception 'FAIL 2q: customer read the manifest';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 3. boarding state machine ------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_item uuid := (select bi.id from public.booking_items bi join public.trip_seats ts on ts.id = bi.trip_seat_id join public.seats s on s.id = ts.seat_id join public.passenger_identity pi on pi.passenger_id = bi.passenger_id where pi.doc_type = 'aadhaar');
  v_unpaid uuid := (select bi.id from public.booking_items bi where bi.status = 'payment_pending' limit 1);
  r jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');

  -- paid but not verified: still not boarded, and cannot be confirmed
  r := public.confirm_boarding(v_item);
  if r ->> 'code' <> 'not_verified' then raise exception 'FAIL 3a: confirm before verify %', r; end if;
  if exists (select 1 from jsonb_array_elements((public.get_trip_manifest(v_trip) -> 'passengers')) e where e ->> 'boarding_status' = 'boarded') then
    raise exception 'FAIL 3b: a paid booking was treated as boarded';
  end if;

  -- an unpaid / unconfirmed booking cannot be verified
  r := public.verify_passenger_boarding(v_unpaid, true);
  if r ->> 'code' <> 'not_confirmed' then raise exception 'FAIL 3c: unpaid verified %', r; end if;

  r := public.verify_passenger_boarding(v_item, true, 'manual');
  if r ->> 'status' <> 'verified' then raise exception 'FAIL 3d: verify %', r; end if;
  perform pg_temp.as_server();
  if (select verification_status from public.passenger_identity where doc_type = 'aadhaar') <> 'verified' then
    raise exception 'FAIL 3e: document should be verified after the check';
  end if;
  if (select verified_by from public.passenger_boarding where booking_item_id = v_item) is null then
    raise exception 'FAIL 3f: staff identity not recorded';
  end if;

  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');   -- non-admin staff may verify and confirm
  r := public.confirm_boarding(v_item);
  if r ->> 'status' <> 'boarded' then raise exception 'FAIL 3g: confirm %', r; end if;
  perform pg_temp.as_server();
  if (select status from public.trip_seats where id = (select trip_seat_id from public.booking_items where id = v_item)) <> 'boarded' then
    raise exception 'FAIL 3h: seat should be boarded';
  end if;
  if (select boarded_at from public.passenger_boarding where booking_item_id = v_item) is null then raise exception 'FAIL 3i: boarded_at'; end if;

  -- duplicates are blocked and logged
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  r := public.confirm_boarding(v_item);
  if r ->> 'code' <> 'already_boarded' then raise exception 'FAIL 3j: duplicate confirm %', r; end if;
  r := public.verify_passenger_boarding(v_item, true);
  if r ->> 'code' <> 'already_boarded' then raise exception 'FAIL 3k: verify after boarded %', r; end if;
  perform pg_temp.as_server();
  if (select count(*) from public.boarding_events where booking_item_id = v_item and result = 'rejected_already_used') < 2 then
    raise exception 'FAIL 3l: duplicate attempts must be persisted';
  end if;
  if (select count(*) from public.boarding_events where booking_item_id = v_item and result = 'boarded') <> 1 then
    raise exception 'FAIL 3m: exactly one boarding event';
  end if;
  if not exists (select 1 from public.audit_logs where action = 'boarding.confirm' and entity_id = v_item) then
    raise exception 'FAIL 3n: boarding must be audited';
  end if;
  if not exists (select 1 from realtime.sent_log where topic like '%:ops' and payload ->> 'kind' = 'boarding') then
    raise exception 'FAIL 3o: no boarding ping on the ops channel';
  end if;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if exists (select 1 from jsonb_array_elements((select public.get_trip_manifest(v_trip, 'boarded') -> 'passengers')) e where e ->> 'booking_item_id' <> v_item::text)
     or jsonb_array_length((select public.get_trip_manifest(v_trip, 'boarded') -> 'passengers')) <> 1 then
    raise exception 'FAIL 3p: boarded filter';
  end if;
  perform pg_temp.as_server();
end $$;

-- ---- 4. exceptions and correction ---------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_item1 uuid := (select bi.id from public.booking_items bi join public.passenger_identity pi on pi.passenger_id = bi.passenger_id where pi.doc_type = 'aadhaar');
  v_item2 uuid := (select bi.id from public.booking_items bi join public.passenger_identity pi on pi.passenger_id = bi.passenger_id where pi.doc_type = 'pan');
  r jsonb;
begin
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  begin perform public.mark_boarding_exception(v_item2, ''); raise exception 'FAIL 4a: exception without reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  r := public.mark_boarding_exception(v_item2, 'ID does not match the ticket');
  if r ->> 'status' <> 'exception' then raise exception 'FAIL 4b: %', r; end if;
  if jsonb_array_length(public.get_trip_manifest(v_trip, 'exceptions') -> 'passengers') <> 2 then
    raise exception 'FAIL 4c: exceptions filter should list the exception and the unpaid booking';
  end if;

  -- corrections are admin only
  begin perform public.correct_boarding(v_item1, 'scanned by mistake'); raise exception 'FAIL 4d: non-admin staff corrected boarding';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  r := public.correct_boarding(v_item1, 'scanned by mistake');
  if r ->> 'status' <> 'not_boarded' then raise exception 'FAIL 4e: %', r; end if;
  perform pg_temp.as_server();
  if (select status from public.trip_seats where id = (select trip_seat_id from public.booking_items where id = v_item1)) <> 'booked' then
    raise exception 'FAIL 4f: corrected seat must return to booked';
  end if;
  if not exists (select 1 from public.boarding_events where booking_item_id = v_item1 and result = 'corrected') then raise exception 'FAIL 4g'; end if;
  if not exists (select 1 from public.audit_logs where action = 'boarding.correct' and entity_id = v_item1) then raise exception 'FAIL 4h'; end if;

  -- other operator / customer cannot touch boarding at all
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.verify_passenger_boarding(v_item1, true); raise exception 'FAIL 4i: operator B verified';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.confirm_boarding(v_item1); raise exception 'FAIL 4j: customer boarded';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 5. full-number reveal ----------------------------------------------------------
do $$
declare
  v_item uuid := (select bi.id from public.booking_items bi join public.passenger_identity pi on pi.passenger_id = bi.passenger_id where pi.doc_type = 'aadhaar');
  r jsonb; v_audit jsonb;
begin
  perform pg_temp.as_user('99999999-0000-0000-0000-000000000009');
  begin perform public.reveal_passenger_document(v_item, 'legal check at boarding'); raise exception 'FAIL 5a: staff revealed a document';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.reveal_passenger_document(v_item, 'x'); raise exception 'FAIL 5b: reveal without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  r := public.reveal_passenger_document(v_item, 'police verification request');
  if r ->> 'doc_number' <> '123456789012' then raise exception 'FAIL 5c: decrypted number %', r; end if;

  perform pg_temp.as_server();
  select after into v_audit from public.audit_logs where action = 'passenger_document.reveal' order by created_at desc limit 1;
  if v_audit is null or v_audit ->> 'reason' <> 'police verification request' then raise exception 'FAIL 5d: reveal not audited %', v_audit; end if;
  if (select string_agg(coalesce(before::text, '') || coalesce(after::text, ''), ' ') from public.audit_logs) like '%123456789012%'
     or (select string_agg(coalesce(before::text, '') || coalesce(after::text, ''), ' ') from public.audit_logs) like '%ABCDE1234F%' then
    raise exception 'FAIL 5e: a document number reached the audit log';
  end if;

  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.reveal_passenger_document(v_item, 'trying another operator data'); raise exception 'FAIL 5f: operator B revealed';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 6. QR: rejections are persisted ---------------------------------------------------
do $$
declare
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_item uuid := (select bi.id from public.booking_items bi join public.passenger_identity pi on pi.passenger_id = bi.passenger_id where pi.doc_type = 'pan');
  v_qr text; r jsonb;
begin
  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  v_qr := public.generate_ticket_qr(v_item);

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  r := public.verify_ticket_qr(v_qr);
  if (r ->> 'ok')::boolean is not true or r ->> 'seat_code' is null then raise exception 'FAIL 6a: first scan %', r; end if;

  r := public.verify_ticket_qr(v_qr);
  if (r ->> 'ok')::boolean is not false or r ->> 'code' <> 'already_boarded' then raise exception 'FAIL 6b: second scan %', r; end if;
  perform pg_temp.as_server();
  if (select count(*) from public.boarding_events where booking_item_id = v_item and result = 'rejected_already_used') <> 1 then
    raise exception 'FAIL 6c: the rejected scan must be kept in the audit trail';
  end if;
  if (select count(*) from public.boarding_events where booking_item_id = v_item and result = 'boarded') <> 1 then raise exception 'FAIL 6d'; end if;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.verify_ticket_qr(split_part(v_qr, '.', 1) || '.deadbeef'); raise exception 'FAIL 6e: tampered code accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.verify_ticket_qr(v_qr); raise exception 'FAIL 6f: operator B scanned operator A ticket';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 7. disabled Bus service: no boarding actions, history still readable -------------------
do $$
declare
  v_a uuid := (select id from t_ops where tag = 'A');
  v_trip uuid := (select id from t_ref where tag = 'TRIP');
  v_item uuid := (select bi.id from public.booking_items bi join public.passenger_identity pi on pi.passenger_id = bi.passenger_id where pi.doc_type = 'aadhaar');
begin
  perform pg_temp.as_server();
  update public.operator_services set state = 'disabled' where operator_id = v_a and service_type = 'bus';
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.verify_passenger_boarding(v_item, true); raise exception 'FAIL 7a: boarded while the service is disabled';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'service_inactive%' then raise exception 'FAIL 7b: %', sqlerrm; end if;
  end;
  if jsonb_array_length(public.get_trip_manifest(v_trip) -> 'passengers') <> 2 then raise exception 'FAIL 7c: history must stay readable'; end if;
  perform pg_temp.as_server();
end $$;

rollback;
