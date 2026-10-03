-- =========================================================================
-- Checks for 20261002001300_route_copy_and_admin_publish.sql
--   * copy a round-trip route to another bus: independent rows, no trips / bookings copied
--   * modifying the copy never changes the source; the copy applies on its own
--   * copying onto a bus that already has a route needs confirmation, then goes through approval
--   * authorization (other operator, customer, no source route, same bus)
--   * admin authored revisions: operator cannot touch them, publish is atomic and audited
--   * admin copy + publish, route history (origin, previous revision, responsible user)
-- Everything is rolled back.
-- =========================================================================
begin;

create function pg_temp.t_st(p_city uuid, p_b boolean, p_d boolean, p_arr int, p_dep int) returns jsonb
language sql immutable as $f$
  select jsonb_build_object('city_id', p_city, 'is_boarding', p_b, 'is_dropping', p_d,
                            'arrival_offset_min', p_arr, 'departure_offset_min', p_dep)
$f$;
grant execute on function pg_temp.t_st(uuid, boolean, boolean, int, int) to authenticated, anon;

-- a revision's stops / journey settings as comparable text
create function pg_temp.t_stops(p_rev uuid) returns text language sql stable security definer as $f$
  select coalesce(string_agg(j.direction || ':' || s.sequence_no || ':' || s.city_id || ':' || coalesce(s.arrival_offset_min::text, '-')
         || ':' || coalesce(s.departure_offset_min::text, '-') || ':' || s.is_boarding || ':' || s.is_dropping, ',' order by j.direction, s.sequence_no), '')
  from public.route_revision_journeys j join public.route_revision_stops s on s.journey_id = j.id where j.revision_id = p_rev
$f$;
create function pg_temp.t_jny(p_rev uuid) returns text language sql stable security definer as $f$
  select coalesce(string_agg(j.direction || ':' || coalesce(j.departure_time::text, '-') || ':' || coalesce(j.est_duration_min::text, '-')
         || ':' || j.operating_days::text || ':' || j.departure_day_offset || ':' || j.reverse_generated || ':' || j.source_city_id || ':' || j.destination_city_id,
         ',' order by j.direction), '')
  from public.route_revision_journeys j where j.revision_id = p_rev
$f$;
grant execute on function pg_temp.t_stops(uuid), pg_temp.t_jny(uuid) to authenticated, anon;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin1@test.invalid'),
  ('dddddddd-0000-0000-0000-00000000000d', 'cust@test.invalid');
insert into public.user_roles (user_id, role) values ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin');

create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;
create function pg_temp.r(p_tag text) returns uuid language sql stable security definer as $f$ select id from t_ref where tag = p_tag $f$;
grant execute on function pg_temp.r(text) to authenticated, anon;

insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'C Src') returning id)
  insert into t_ref select 'SRC', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'C Mid') returning id)
  insert into t_ref select 'MID', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'C Dst') returning id)
  insert into t_ref select 'DST', id from c;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'OPA', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'OPB', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

-- buses (layout)
create function pg_temp.t_prep(p_bus uuid) returns void language plpgsql as $f$
declare r jsonb;
begin
  r := public.save_bus_layout(p_bus, '{"rows":2,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"}]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup layout: %', r -> 'errors'; end if;
end $f$;
grant execute on function pg_temp.t_prep(uuid) to authenticated;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'A1', (public.create_bus(pg_temp.r('OPA'), 'Bus A1', 'AN01C0001', 'ac_seater', 3)).id;
insert into t_ref select 'A2', (public.create_bus(pg_temp.r('OPA'), 'Bus A2', 'AN01C0002', 'ac_seater', 3)).id;
insert into t_ref select 'A3', (public.create_bus(pg_temp.r('OPA'), 'Bus A3', 'AN01C0003', 'ac_seater', 3)).id;
insert into t_ref select 'A4', (public.create_bus(pg_temp.r('OPA'), 'Bus A4', 'AN01C0004', 'ac_seater', 3)).id;
select pg_temp.t_prep(pg_temp.r('A1')), pg_temp.t_prep(pg_temp.r('A2')), pg_temp.t_prep(pg_temp.r('A3'));
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'B1', (public.create_bus(pg_temp.r('OPB'), 'Bus B1', 'AN01C0009', 'ac_seater', 3)).id;

-- ---- 1. A1: a round trip, applied at setup, then live with a trip ----------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_rev uuid; r jsonb;
begin
  v_rev := public.start_route_revision(pg_temp.r('A1'));
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip', 'outbound', jsonb_build_object(
    'source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
    'departure_time', '06:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb,
    'stops', jsonb_build_array(pg_temp.t_st(pg_temp.r('SRC'), true, false, 0, 0),
                               pg_temp.t_st(pg_temp.r('MID'), true, true, 120, 125),
                               pg_temp.t_st(pg_temp.r('DST'), false, true, 240, 240)))));
  r := public.generate_reverse_route(v_rev);
  if (r ->> 'valid')::boolean then raise exception 'FAIL 1a: a reverse route needs its own departure time'; end if;
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip',
    'outbound', jsonb_build_object('source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
      'departure_time', '06:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb,
      'stops', public.get_route_revision_diff(v_rev) -> 'outbound' -> 'proposed' -> 'stops'),
    'return', jsonb_build_object('source_city_id', pg_temp.r('DST'), 'destination_city_id', pg_temp.r('SRC'),
      'departure_time', '10:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb, 'reverse_generated', true,
      'stops', public.get_route_revision_diff(v_rev) -> 'return' -> 'proposed' -> 'stops')));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 1a2: %', r -> 'errors'; end if;
  r := public.submit_route_revision(v_rev, null);
  if r ->> 'status' <> 'approved' then raise exception 'FAIL 1b: setup submit did not apply: %', r; end if;
  if (select origin from public.route_revisions where id = v_rev) <> 'operator' then raise exception 'FAIL 1c: origin should be operator'; end if;
  insert into t_ref values ('A1_REV1', v_rev);
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'active' where id = pg_temp.r('A1');
update public.bus_services set status = 'active', schedule_configured = true where bus_id = pg_temp.r('A1');
insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at)
select id, operator_id, route_id, bus_id, current_date + 2, (current_date + 2) + time '06:00', (current_date + 2) + time '10:00'
from public.bus_services where bus_id = pg_temp.r('A1') and direction = 'outbound';

-- ---- 2. copy A1 -> A2 (empty destination, still being set up) --------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb; v_rev uuid; rv public.route_revisions;
begin
  r := public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A2'));
  if not (r ->> 'ok')::boolean then raise exception 'FAIL 2a: copy failed: %', r; end if;
  v_rev := (r ->> 'revision_id')::uuid;
  select * into rv from public.route_revisions where id = v_rev;
  if rv.bus_id <> pg_temp.r('A2') or rv.status <> 'draft' or rv.origin <> 'route_copy' or rv.admin_authored then
    raise exception 'FAIL 2b: wrong revision header: %', to_jsonb(rv);
  end if;
  if rv.source_bus_id <> pg_temp.r('A1') or rv.source_revision_id <> pg_temp.r('A1_REV1') or rv.base_revision_id is not null then
    raise exception 'FAIL 2c: copy metadata wrong';
  end if;
  if rv.trip_type <> 'round_trip' then raise exception 'FAIL 2d: trip type not copied'; end if;
  if pg_temp.t_stops(v_rev) <> pg_temp.t_stops(pg_temp.r('A1_REV1')) then raise exception 'FAIL 2e: stops differ from source'; end if;
  if pg_temp.t_jny(v_rev) <> pg_temp.t_jny(pg_temp.r('A1_REV1')) then raise exception 'FAIL 2f: journey settings differ from source'; end if;
  if (select count(*) from public.route_revision_stops s join public.route_revision_journeys j on j.id = s.journey_id
      where j.revision_id = v_rev) <> 6 then raise exception 'FAIL 2g: expected 3 + 3 copied stops'; end if;
  -- independent rows: no stop / journey id is shared with the source
  if exists (select 1 from public.route_revision_journeys a join public.route_revision_journeys b on a.id = b.id
             where a.revision_id = v_rev and b.revision_id = pg_temp.r('A1_REV1')) then raise exception 'FAIL 2h: journeys shared'; end if;
  if not (r -> 'validation' ->> 'valid')::boolean then raise exception 'FAIL 2i: copy should validate: %', r -> 'validation'; end if;
  if not exists (select 1 from public.route_revision_events where revision_id = v_rev and event = 'copied'
                 and (meta ->> 'source_bus_id')::uuid = pg_temp.r('A1') and (meta ->> 'destination_bus_id')::uuid = pg_temp.r('A2')) then
    raise exception 'FAIL 2j: copied event / audit metadata missing';
  end if;
  -- nothing operational was copied
  if exists (select 1 from public.bus_trips where bus_id = pg_temp.r('A2')) then raise exception 'FAIL 2k: trips were copied'; end if;
  if exists (select 1 from public.bus_routes where bus_id = pg_temp.r('A2')) then raise exception 'FAIL 2l: a draft copy must not create live routes'; end if;
  insert into t_ref values ('A2_COPY', v_rev);
end $$;

-- ---- 3. modify the copy; the source stays exactly as it was -----------------
do $$
declare
  v_copy uuid := pg_temp.r('A2_COPY');
  v_before_src text := pg_temp.t_stops(pg_temp.r('A1_REV1')) || pg_temp.t_jny(pg_temp.r('A1_REV1'));
  v_diff jsonb := public.get_route_revision_diff(pg_temp.r('A2_COPY'));
  r jsonb; n_trips int;
begin
  -- change the return time and drop the middle stop of the outbound journey
  r := public.save_route_revision(v_copy, jsonb_build_object('trip_type', 'round_trip',
    'outbound', jsonb_build_object('source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
      'departure_time', '07:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5]'::jsonb,
      'stops', jsonb_build_array(pg_temp.t_st(pg_temp.r('SRC'), true, false, 0, 0), pg_temp.t_st(pg_temp.r('DST'), false, true, 240, 240))),
    'return', jsonb_build_object('source_city_id', pg_temp.r('DST'), 'destination_city_id', pg_temp.r('SRC'),
      'departure_time', '16:00', 'duration_min', 240, 'operating_days', '[1,3,5]'::jsonb, 'reverse_generated', true,
      'stops', v_diff -> 'return' -> 'proposed' -> 'stops')));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 3a: edited copy invalid: %', r -> 'errors'; end if;
  if pg_temp.t_stops(pg_temp.r('A1_REV1')) || pg_temp.t_jny(pg_temp.r('A1_REV1')) <> v_before_src then
    raise exception 'FAIL 3b: editing the copy changed the source revision';
  end if;
  if (select count(*) from public.boarding_points where route_id in (select id from public.bus_routes where bus_id = pg_temp.r('A1')) and is_active) <> 4 then
    raise exception 'FAIL 3c: source live points changed';
  end if;
  select count(*) into n_trips from public.bus_trips where bus_id = pg_temp.r('A1');
  if n_trips <> 1 then raise exception 'FAIL 3d: source trips changed'; end if;

  -- A2 is still in setup: submitting applies the copy as A2's own route
  r := public.submit_route_revision(v_copy, null);
  if r ->> 'status' <> 'approved' then raise exception 'FAIL 3e: %', r; end if;
  if (select active_route_revision_id from public.buses where id = pg_temp.r('A2')) <> v_copy then raise exception 'FAIL 3f: A2 active revision'; end if;
  if (select active_route_revision_id from public.buses where id = pg_temp.r('A1')) <> pg_temp.r('A1_REV1') then raise exception 'FAIL 3g: A1 active revision changed'; end if;
  -- separate live routes / services / points; each bus keeps its own schedule
  if exists (select 1 from public.bus_routes a join public.bus_routes b on a.id = b.id
             where a.bus_id = pg_temp.r('A1') and b.bus_id = pg_temp.r('A2')) then raise exception 'FAIL 3h: live routes shared'; end if;
  if (select default_departure_time::text from public.bus_services where bus_id = pg_temp.r('A2') and direction = 'outbound') <> '07:00:00'
     or (select default_departure_time::text from public.bus_services where bus_id = pg_temp.r('A1') and direction = 'outbound') <> '06:00:00' then
    raise exception 'FAIL 3i: schedules not independent';
  end if;
  if (select count(*) from public.boarding_points where route_id in (select id from public.bus_routes where bus_id = pg_temp.r('A2')) and is_active) <> 3 then
    raise exception 'FAIL 3j: A2 should have 1 + 2 boarding points (outbound origin, return origin + mid)';
  end if;
  if exists (select 1 from public.boarding_points p join public.bus_routes rt on rt.id = p.route_id
             where rt.bus_id = pg_temp.r('A1') and p.id in (select p2.id from public.boarding_points p2 join public.bus_routes r2 on r2.id = p2.route_id where r2.bus_id = pg_temp.r('A2'))) then
    raise exception 'FAIL 3k: boarding points shared';
  end if;
end $$;

-- ---- 4. copy onto a bus that already has a route: confirmation, then approval ----
reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'active' where id = pg_temp.r('A2');
update public.bus_services set status = 'active', schedule_configured = true where bus_id = pg_temp.r('A2');
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb; v_rev uuid; v_live_before text;
begin
  r := public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A2'));
  if (r ->> 'ok')::boolean or not (r ->> 'needs_confirmation')::boolean or not (r ->> 'destination_has_route')::boolean then
    raise exception 'FAIL 4a: copy onto a bus with a route must ask for confirmation: %', r;
  end if;
  if exists (select 1 from public.route_revisions where bus_id = pg_temp.r('A2') and status = 'draft') then
    raise exception 'FAIL 4b: nothing may be created before confirmation';
  end if;
  v_live_before := pg_temp.t_stops(pg_temp.r('A2_COPY'));

  r := public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A2'), true);
  if not (r ->> 'ok')::boolean then raise exception 'FAIL 4c: confirmed copy failed: %', r; end if;
  v_rev := (r ->> 'revision_id')::uuid;
  if (select base_revision_id from public.route_revisions where id = v_rev) <> pg_temp.r('A2_COPY') then raise exception 'FAIL 4d: base revision should be A2''s active one'; end if;
  if (select active_route_revision_id from public.buses where id = pg_temp.r('A2')) <> pg_temp.r('A2_COPY') then raise exception 'FAIL 4e: approved route replaced silently'; end if;

  -- a second copy while the first is an open draft needs confirmation too (and replaces that draft)
  r := public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A2'));
  if not (r ->> 'needs_confirmation')::boolean or not (r ->> 'destination_has_draft')::boolean then raise exception 'FAIL 4f: %', r; end if;

  -- an active bus: the operator submits it for approval, the live route stays
  r := public.submit_route_revision(v_rev, 'Match the other bus');
  if r ->> 'status' <> 'pending_approval' then raise exception 'FAIL 4g: %', r; end if;
  if pg_temp.t_stops(pg_temp.r('A2_COPY')) <> v_live_before
     or (select default_departure_time::text from public.bus_services where bus_id = pg_temp.r('A2') and direction = 'outbound') <> '07:00:00' then
    raise exception 'FAIL 4h: live route changed while pending';
  end if;
  begin
    perform public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A2'), true);
    raise exception 'FAIL 4i: copying onto a pending revision must be refused';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  insert into t_ref values ('A2_REV3', v_rev);
end $$;

select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  perform public.admin_review_route_revision(pg_temp.r('A2_REV3'), 'approve', null);
  if (select default_departure_time::text from public.bus_services where bus_id = pg_temp.r('A2') and direction = 'outbound') <> '06:00:00' then
    raise exception 'FAIL 4j: approved copy not live on A2';
  end if;
  if (select replaced_revision_id from public.route_revisions where id = pg_temp.r('A2_REV3')) <> pg_temp.r('A2_COPY') then
    raise exception 'FAIL 4k: replaced revision not recorded';
  end if;
end $$;

-- ---- 5. authorization / invalid requests ------------------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin perform public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('B1'), true); raise exception 'FAIL 5a: copied to another operator''s bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A1'), true); raise exception 'FAIL 5b: copied a bus onto itself';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.copy_route_to_bus(pg_temp.r('A4'), pg_temp.r('A3')); raise exception 'FAIL 5c: copied a route that does not exist';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_publish_route_revision(pg_temp.r('A2_REV3'), 'x'); raise exception 'FAIL 5d: operator published';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin perform public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('B1'), true); raise exception 'FAIL 5e: copied another operator''s route';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.get_route_history(pg_temp.r('A1')); raise exception 'FAIL 5f: read another operator''s history';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin perform public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A2'), true); raise exception 'FAIL 5g: a customer copied a route';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.get_route_history(null); raise exception 'FAIL 5h: a customer read route history';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- ---- 6. admin edits an active route and publishes it ----------------------------
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_rev uuid; r jsonb; v_diff jsonb; v_live_dep text;
begin
  v_rev := public.start_route_revision(pg_temp.r('A1'));
  if (select origin || ':' || admin_authored::text from public.route_revisions where id = v_rev) <> 'admin:true' then
    raise exception 'FAIL 6a: admin revision header wrong';
  end if;
  if (select base_revision_id from public.route_revisions where id = v_rev) <> pg_temp.r('A1_REV1') then raise exception 'FAIL 6b: base should be the active revision'; end if;
  v_diff := public.get_route_revision_diff(v_rev);
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip',
    'outbound', jsonb_build_object('source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
      'departure_time', '05:30', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb,
      'stops', v_diff -> 'outbound' -> 'proposed' -> 'stops'),
    'return', jsonb_build_object('source_city_id', pg_temp.r('DST'), 'destination_city_id', pg_temp.r('SRC'),
      'departure_time', '15:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb, 'reverse_generated', true,
      'stops', v_diff -> 'return' -> 'proposed' -> 'stops')));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 6c: %', r -> 'errors'; end if;
  -- the before / after preview shows the change; saving a draft leaves the live route alone
  if not (public.get_route_revision_diff(v_rev) -> 'outbound' -> 'changes' -> 'schedule_changes') @> '"departure_time"'::jsonb then raise exception 'FAIL 6d: diff missing the time change'; end if;
  select default_departure_time::text into v_live_dep from public.bus_services where bus_id = pg_temp.r('A1') and direction = 'outbound';
  if v_live_dep <> '06:00:00' then raise exception 'FAIL 6e: draft changed the live route'; end if;
  insert into t_ref values ('A1_REV2', v_rev);
end $$;

-- the operator can neither edit, withdraw nor start over an admin draft
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin perform public.save_route_revision(pg_temp.r('A1_REV2'), '{"trip_type":"one_way"}'::jsonb); raise exception 'FAIL 6f: operator edited an admin draft';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.withdraw_route_revision(pg_temp.r('A1_REV2')); raise exception 'FAIL 6g: operator withdrew an admin draft';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.start_route_revision(pg_temp.r('A1')); raise exception 'FAIL 6h: operator started over an admin draft';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare r jsonb; v_rev uuid := pg_temp.r('A1_REV2');
begin
  begin perform public.admin_publish_route_revision(v_rev, '  '); raise exception 'FAIL 6i: publish without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  r := public.admin_publish_route_revision(v_rev, 'Earlier departure');
  if not (r ->> 'ok')::boolean then raise exception 'FAIL 6j: publish failed: %', r; end if;
  if (select active_route_revision_id from public.buses where id = pg_temp.r('A1')) <> v_rev then raise exception 'FAIL 6k: active reference not updated'; end if;
  if (select status from public.route_revisions where id = pg_temp.r('A1_REV1')) <> 'superseded' then raise exception 'FAIL 6l: previous revision not superseded'; end if;
  if (select default_departure_time::text from public.bus_services where bus_id = pg_temp.r('A1') and direction = 'outbound') <> '05:30:00' then
    raise exception 'FAIL 6m: published time not live';
  end if;
  if not exists (select 1 from public.route_revisions where id = v_rev and status = 'approved' and published_by = 'cccccccc-0000-0000-0000-00000000000c'
                 and replaced_revision_id = pg_temp.r('A1_REV1') and change_reason = 'Earlier departure' and published_at is not null) then
    raise exception 'FAIL 6n: publish audit columns wrong';
  end if;
  if not exists (select 1 from public.audit_logs where action = 'route.published' and entity_id = v_rev
                 and actor_profile_id = 'cccccccc-0000-0000-0000-00000000000c'
                 and (before ->> 'previous_revision_id')::uuid = pg_temp.r('A1_REV1')) then
    raise exception 'FAIL 6o: audit log entry missing';
  end if;
  begin perform public.admin_publish_route_revision(v_rev, 'again'); raise exception 'FAIL 6p: published twice';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- an operator draft cannot be published by an admin (it must be submitted and approved)
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_rev uuid;
begin
  v_rev := public.start_route_revision(pg_temp.r('A1'));
  insert into t_ref values ('A1_OPDRAFT', v_rev);
end $$;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin perform public.admin_publish_route_revision(pg_temp.r('A1_OPDRAFT'), 'x'); raise exception 'FAIL 6q: admin published an operator draft';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.start_route_revision(pg_temp.r('A1')); raise exception 'FAIL 6r: admin started over an operator draft';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.withdraw_route_revision(pg_temp.r('A1_OPDRAFT'));  -- an admin may clear it
end $$;

-- ---- 7. admin copies A1 -> A3 (still being set up) and publishes -------------------
do $$
declare r jsonb; v_rev uuid;
begin
  r := public.copy_route_to_bus(pg_temp.r('A1'), pg_temp.r('A3'));
  if not (r ->> 'ok')::boolean then raise exception 'FAIL 7a: %', r; end if;
  v_rev := (r ->> 'revision_id')::uuid;
  if (select origin || ':' || admin_authored::text from public.route_revisions where id = v_rev) <> 'route_copy:true' then raise exception 'FAIL 7b: header'; end if;
  r := public.admin_publish_route_revision(v_rev, 'Copied from A1');
  if not (r ->> 'ok')::boolean then raise exception 'FAIL 7c: %', r; end if;
  if (select default_departure_time::text from public.bus_services where bus_id = pg_temp.r('A3') and direction = 'outbound') <> '05:30:00' then
    raise exception 'FAIL 7d: copied route not live on A3';
  end if;
  insert into t_ref values ('A3_REV1', v_rev);
end $$;

-- ---- 8. history -------------------------------------------------------------------
do $$
declare h jsonb; row_ jsonb;
begin
  h := public.get_route_history(pg_temp.r('A1'));
  if jsonb_array_length(h) <> 3 then raise exception 'FAIL 8a: expected 3 A1 revisions (setup, admin publish, withdrawn operator draft), got %', jsonb_array_length(h); end if;
  select e into row_ from jsonb_array_elements(h) e where (e ->> 'revision_no')::int = 2;
  if row_ ->> 'origin' <> 'admin' or (row_ ->> 'previous_revision_no')::int <> 1 or not (row_ ->> 'is_active')::boolean
     or not (row_ ->> 'is_published')::boolean or row_ ->> 'published_by_id' <> 'cccccccc-0000-0000-0000-00000000000c' then
    raise exception 'FAIL 8b: admin revision history wrong: %', row_;
  end if;
  h := public.get_route_history(pg_temp.r('A3'));
  if h -> 0 ->> 'origin' <> 'route_copy' or h -> 0 ->> 'source_registration_number' <> 'AN01C0001' then raise exception 'FAIL 8c: copy history wrong: %', h -> 0; end if;
  if jsonb_array_length(public.get_route_history(null)) < 5 then raise exception 'FAIL 8d: admin all-bus history'; end if;
end $$;
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare h jsonb; row_ jsonb;
begin
  h := public.get_route_history(pg_temp.r('A1'));
  select e into row_ from jsonb_array_elements(h) e where (e ->> 'revision_no')::int = 2;
  if row_ ->> 'created_by_name' <> 'Platform admin' or row_ ? 'published_by_id' and row_ ->> 'published_by_id' is not null then
    raise exception 'FAIL 8e: operators must not see admin identities: %', row_;
  end if;
  begin perform public.get_route_history(null); raise exception 'FAIL 8f: operator read all-bus history';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

rollback;
