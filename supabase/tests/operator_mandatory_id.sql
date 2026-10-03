-- =========================================================================
-- Checks for 20261002002200_mandatory_passenger_id.sql
--   * a booking needs an ID type + number for EVERY passenger (type + number only, no image)
--   * invalid numbers are refused and nothing is left behind; the seat hold survives
--   * the number is stored encrypted and reaches operators masked
--   * the rule can be switched off by a platform admin only
--   * the passenger list can be exported only after booking has closed, and every export is audited
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

create function pg_temp.pay(p_tag text) returns void language plpgsql security definer as $f$
declare o public.orders;
begin
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, 'pay_' || p_tag, o.amount_cents);
end $f$;
grant execute on function pg_temp.pay(text) to authenticated;

create function pg_temp.hold(p_user uuid, p_seats int, p_skip int default 0) returns uuid language plpgsql as $f$
declare h jsonb; v_trip uuid := (select id from t_ref where tag = 'TRIP');
begin
  perform pg_temp.as_user(p_user);
  h := public.create_seat_hold(v_trip, pg_temp.t_seats(v_trip, p_seats, p_skip), 300,
        (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'));
  return (h ->> 'hold_token')::uuid;
end $f$;
grant execute on function pg_temp.hold(uuid, int, int) to authenticated;

create function pg_temp.book_with(p_token uuid, p_passengers jsonb) returns jsonb language sql as $f$
  select public.create_booking(p_token, 'c@test.invalid', '9876543210', p_passengers,
    (select id from t_ref where tag = 'B_ORIGIN'), (select id from t_ref where tag = 'D_MID'))
$f$;
grant execute on function pg_temp.book_with(uuid, jsonb) to authenticated;

-- ---- 1. the rule is ON by default and refuses incomplete passengers ---------------------------------
do $$
declare t uuid; r jsonb;
begin
  if (select value from public.platform_settings where key = 'passenger_id_required') <> 'true'::jsonb then
    raise exception 'FAIL 1a: passenger_id_required must default to ON';
  end if;

  t := pg_temp.hold('dddddddd-0000-0000-0000-00000000000d', 2);

  begin
    perform pg_temp.book_with(t, '[{"full_name":"A","age":30,"gender":"male"},{"full_name":"B","age":28,"gender":"female"}]'::jsonb);
    raise exception 'FAIL 1b: booked without any ID';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'document_required%' then raise exception 'FAIL 1c: %', sqlerrm; end if;
  end;

  -- the second passenger is missing the number: still refused
  begin
    perform pg_temp.book_with(t, '[{"full_name":"A","age":30,"gender":"male","doc_type":"aadhaar","doc_number":"1234 5678 9012"},{"full_name":"B","age":28,"gender":"female","doc_type":"aadhaar"}]'::jsonb);
    raise exception 'FAIL 1d: one passenger without a number was accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'document_required%' then raise exception 'FAIL 1e: %', sqlerrm; end if;
  end;

  begin
    perform pg_temp.book_with(t, '[{"full_name":"A","age":30,"gender":"male","doc_type":"aadhaar","doc_number":"123"},{"full_name":"B","age":28,"gender":"female","doc_type":"driving_licence","doc_number":"AN01 2020 0012345"}]'::jsonb);
    raise exception 'FAIL 1f: a malformed Aadhaar number was accepted';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'invalid_document%' then raise exception 'FAIL 1g: %', sqlerrm; end if;
  end;

  perform pg_temp.as_server();
  -- every refusal rolled back: no booking, no passenger, no document; the hold is still there
  if exists (select 1 from public.bookings) or exists (select 1 from public.passengers) or exists (select 1 from public.passenger_identity) then
    raise exception 'FAIL 1h: a refused booking left rows behind';
  end if;
  if (select status from public.seat_holds order by created_at desc limit 1) <> 'active' then raise exception 'FAIL 1i: the hold was lost'; end if;

  -- the same hold can still be booked once the IDs are right (Aadhaar + Driving licence)
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  r := pg_temp.book_with(t, '[{"full_name":"A","age":30,"gender":"male","doc_type":"aadhaar","doc_number":"1234 5678 9012"},{"full_name":"B","age":28,"gender":"female","doc_type":"driving_licence","doc_number":"an01 2020 0012345"}]'::jsonb);
  insert into t_ref values ('B1', (r ->> 'order_id')::uuid);
  perform pg_temp.as_server();
  if (select count(*) from public.passenger_identity) <> 2 then raise exception 'FAIL 1j: both IDs must be stored'; end if;
  if not exists (select 1 from public.passenger_identity where doc_type = 'aadhaar' and last4 = '9012')
     or not exists (select 1 from public.passenger_identity where doc_type = 'driving_licence' and last4 = '2345') then
    raise exception 'FAIL 1k: ID type/last4';
  end if;
  if exists (select 1 from public.passenger_identity where encode(doc_number_enc, 'escape') like '%123456789012%' or encode(doc_number_enc, 'escape') like '%AN0120200012345%') then
    raise exception 'FAIL 1l: ID number stored in clear';
  end if;
end $$;

-- ---- 2. the operator sees only masked numbers -------------------------------------------------------
do $$
declare m jsonb;
begin
  perform pg_temp.pay('B1');
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  m := public.get_trip_manifest((select id from t_ref where tag = 'TRIP'));
  if jsonb_array_length(m -> 'passengers') <> 2 then raise exception 'FAIL 2a: %', m; end if;
  if not exists (select 1 from jsonb_array_elements(m -> 'passengers') e where e ->> 'doc_masked' = 'XXXX-XXXX-9012' and e ->> 'doc_label' = 'Aadhaar')
     or not exists (select 1 from jsonb_array_elements(m -> 'passengers') e where e ->> 'doc_masked' = 'XXXX2345' and e ->> 'doc_label' = 'Driving licence') then
    raise exception 'FAIL 2b: masked documents %', m -> 'passengers';
  end if;
  if m::text like '%123456789012%' or m::text like '%AN0120200012345%' then raise exception 'FAIL 2c: full number in the manifest'; end if;
  perform pg_temp.as_server();
end $$;

-- ---- 3. only a platform admin can switch the rule off ------------------------------------------------
do $$
declare t uuid;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.admin_set_platform_setting('passenger_id_required', 'false'::jsonb); raise exception 'FAIL 3a: an operator switched the rule off';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_platform_setting('passenger_id_required', 'false'::jsonb);
  t := pg_temp.hold('eeeeeeee-0000-0000-0000-00000000000e', 1, 2);
  perform pg_temp.book_with(t, '[{"full_name":"C","age":40,"gender":"male"}]'::jsonb);   -- allowed while off
  perform pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f');
  perform public.admin_set_platform_setting('passenger_id_required', 'true'::jsonb);
  perform pg_temp.as_server();
end $$;

-- ---- 4. export of the passenger list: only after booking has closed, always audited ------------------
do $$
declare v_trip uuid := (select id from t_ref where tag = 'TRIP'); m jsonb; r jsonb;
begin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  m := public.get_trip_manifest(v_trip);
  if (m ->> 'booking_closed')::boolean then raise exception 'FAIL 4a: booking is still open'; end if;
  begin perform public.log_manifest_export(v_trip, 'download'); raise exception 'FAIL 4b: exported while booking was open';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like 'booking_not_closed%' then raise exception 'FAIL 4c: %', sqlerrm; end if;
  end;

  -- booking closes (cut-off passed, trip still ahead)
  perform pg_temp.as_server();
  update public.bus_trips set booking_close_at = now() - interval '5 minutes' where id = v_trip;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  m := public.get_trip_manifest(v_trip);
  if not (m ->> 'booking_closed')::boolean then raise exception 'FAIL 4d: booking should read closed after the cut-off'; end if;
  if m ->> 'booking_close_at' is null or m ->> 'departure_at' is null then raise exception 'FAIL 4e'; end if;

  begin perform public.log_manifest_export(v_trip, 'email'); raise exception 'FAIL 4f: unknown export action accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  r := public.log_manifest_export(v_trip, 'download');
  if (r ->> 'passengers')::int <> 2 then raise exception 'FAIL 4g: %', r; end if;
  perform public.log_manifest_export(v_trip, 'share');

  perform pg_temp.as_server();
  if (select count(*) from public.audit_logs where action = 'manifest.export') <> 2 then raise exception 'FAIL 4h: exports must be audited'; end if;
  if (select after ->> 'action' from public.audit_logs where action = 'manifest.export' order by created_at desc limit 1) is null then raise exception 'FAIL 4i'; end if;
  if (select string_agg(after::text, ' ') from public.audit_logs where action = 'manifest.export') like '%9012%' then raise exception 'FAIL 4j: audit must not contain ID numbers'; end if;

  -- other operators and customers cannot export
  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.log_manifest_export(v_trip, 'download'); raise exception 'FAIL 4k: operator B exported';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.log_manifest_export(v_trip, 'download'); raise exception 'FAIL 4l: a customer exported';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- boarding/departed also counts as closed
  perform pg_temp.as_server();
  update public.bus_trips set booking_close_at = null, status = 'boarding' where id = v_trip;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  if not (public.get_trip_manifest(v_trip) ->> 'booking_closed')::boolean then raise exception 'FAIL 4m: boarding means closed'; end if;
  perform pg_temp.as_server();
end $$;

rollback;
