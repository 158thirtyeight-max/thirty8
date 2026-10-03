-- =========================================================================
-- Checks for 20261002001000_route_revisions.sql
--   * one-way and round-trip routes, linked outbound / return journeys
--   * reverse-route generation, independent return schedule
--   * pending revisions never change the live route; approval is atomic
--   * immutability after submission; rejection reason; resubmission
--   * authorization (operator, other operator, admin, self-approval, customer)
--   * both directions searchable; existing bookings keep their points and are flagged
-- Everything is rolled back.
-- =========================================================================
begin;

create function pg_temp.t_seats(p_trip uuid, p_n int, p_skip int default 0, p_avail boolean default false) returns uuid[]
language sql security definer as $f$
  select array_agg(seat_id) from (
    select seat_id from public.trip_seats
    where trip_id = p_trip and (not p_avail or status = 'available')
    order by seat_id offset p_skip limit p_n) x
$f$;
grant execute on function pg_temp.t_seats(uuid, int, int, boolean) to authenticated, anon;

create function pg_temp.t_st(p_city uuid, p_b boolean, p_d boolean, p_arr int, p_dep int) returns jsonb
language sql immutable as $f$
  select jsonb_build_object('city_id', p_city, 'is_boarding', p_b, 'is_dropping', p_d,
                            'arrival_offset_min', p_arr, 'departure_offset_min', p_dep)
$f$;
grant execute on function pg_temp.t_st(uuid, boolean, boolean, int, int) to authenticated, anon;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin1@test.invalid'),
  ('ffffffff-0000-0000-0000-00000000000f', 'admin2@test.invalid'),
  ('dddddddd-0000-0000-0000-00000000000d', 'cust@test.invalid');
insert into public.user_roles (user_id, role) values
  ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin'),
  ('ffffffff-0000-0000-0000-00000000000f', 'platform_admin');

create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;
create function pg_temp.r(p_tag text) returns uuid language sql stable security definer as $f$ select id from t_ref where tag = p_tag $f$;
grant execute on function pg_temp.r(text) to authenticated, anon;

insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Src') returning id)
  insert into t_ref select 'SRC', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Mid') returning id)
  insert into t_ref select 'MID', id from c;
with c as (insert into public.locations (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'T Dst') returning id)
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

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'BUS', (public.create_bus(pg_temp.r('OPA'), 'Rev Bus', 'AN01R0001', 'ac_seater', 3)).id;

do $$
declare r jsonb;
begin
  r := public.save_bus_layout(pg_temp.r('BUS'), '{"rows":2,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"}]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup layout: %', r -> 'errors'; end if;
end $$;

-- ---- 1. setup stage: a one-way route through the revision workflow -----------
do $$
declare
  v_bus uuid := pg_temp.r('BUS');
  v_rev uuid; r jsonb; n int;
begin
  v_rev := public.start_route_revision(v_bus);
  if public.start_route_revision(v_bus) <> v_rev then raise exception 'FAIL 1a: a second start must return the open draft'; end if;

  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'one_way', 'outbound', jsonb_build_object(
    'source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
    'departure_time', '06:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb,
    'stops', jsonb_build_array(pg_temp.t_st(pg_temp.r('SRC'), true, false, 0, 0),
                               pg_temp.t_st(pg_temp.r('MID'), true, true, 120, 125),
                               pg_temp.t_st(pg_temp.r('DST'), false, true, 240, 240)))));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 1b: valid outbound rejected: %', r -> 'errors'; end if;

  r := public.submit_route_revision(v_rev, null);
  if not (r ->> 'ok')::boolean or r ->> 'status' <> 'approved' then raise exception 'FAIL 1c: setup submit should apply directly: %', r; end if;
  if (select active_route_revision_id from public.buses where id = v_bus) <> v_rev then raise exception 'FAIL 1d: active revision not set'; end if;
  select count(*) into n from public.bus_routes where bus_id = v_bus;
  if n <> 1 then raise exception 'FAIL 1e: expected one live route, got %', n; end if;
  select count(*) into n from public.boarding_points where route_id = (select id from public.bus_routes where bus_id = v_bus) and is_active;
  if n <> 2 then raise exception 'FAIL 1f: expected 2 boarding points, got %', n; end if;
  insert into t_ref values ('REV1', v_rev);
end $$;

-- base fares so a return service can inherit them; then activate the bus and create an outbound trip
do $$
declare r jsonb;
begin
  r := public.save_bus_fares(pg_temp.r('BUS'), '[{"seat_type":"seater","base_fare_cents":50000}]'::jsonb, '[]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL setup fares: %', r -> 'errors'; end if;
end $$;

insert into t_ref select 'B_ORIGIN', id from public.boarding_points
  where city_id = pg_temp.r('SRC') and route_id = (select route_id from public.bus_services where bus_id = pg_temp.r('BUS'));
insert into t_ref select 'B_MID', id from public.boarding_points
  where city_id = pg_temp.r('MID') and route_id = (select route_id from public.bus_services where bus_id = pg_temp.r('BUS'));
insert into t_ref select 'D_MID', id from public.dropping_points
  where city_id = pg_temp.r('MID') and route_id = (select route_id from public.bus_services where bus_id = pg_temp.r('BUS'));

reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'active' where id = pg_temp.r('BUS');
update public.bus_services set status = 'active', schedule_configured = true where bus_id = pg_temp.r('BUS');
with s as (select id, operator_id, route_id, bus_id from public.bus_services where bus_id = pg_temp.r('BUS')),
     t as (insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at)
           select id, operator_id, route_id, bus_id, current_date + 2, (current_date + 2) + time '06:00', (current_date + 2) + time '10:00' from s
           returning id)
insert into t_ref select 'TRIP', id from t;

-- a customer books SRC -> MID on the outbound trip (the booking that later route changes must not break)
select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_trip uuid := pg_temp.r('TRIP');
  v_seat uuid; h jsonb; bk jsonb;
begin
  v_seat := (pg_temp.t_seats(v_trip, 1, 0, true))[1];
  h := public.create_seat_hold(v_trip, array[v_seat], 300, pg_temp.r('B_ORIGIN'), pg_temp.r('D_MID'));
  bk := public.create_booking((h ->> 'hold_token')::uuid, 'c@test.invalid', '9876543210',
    '[{"full_name":"P","age":30,"gender":"male","phone":"9876543213"}]'::jsonb, pg_temp.r('B_ORIGIN'), pg_temp.r('D_MID'));
  if bk ->> 'booking_id' is null then raise exception 'FAIL 2a: booking setup failed'; end if;
end $$;

-- ---- 3. round trip on an active bus: reverse route, pending, nothing live yet ----
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_bus uuid := pg_temp.r('BUS');
  v_rev uuid; r jsonb; j public.route_revision_journeys; n int;
begin
  v_rev := public.start_route_revision(v_bus);
  if (select trip_type from public.route_revisions where id = v_rev) <> 'one_way' then raise exception 'FAIL 3a: clone should be one way'; end if;
  if (select count(*) from public.route_revision_stops s join public.route_revision_journeys jj on jj.id = s.journey_id where jj.revision_id = v_rev) <> 3 then
    raise exception 'FAIL 3b: live route not cloned into the draft';
  end if;

  r := public.generate_reverse_route(v_rev);
  -- the reverse route never copies outbound clock times: its departure is left for the user to set
  if (r ->> 'valid')::boolean or r::text not like '%Departure time is required%' then raise exception 'FAIL 3c: reverse route should await a departure time: %', r; end if;
  if (select departure_time from public.route_revision_journeys where revision_id = v_rev and direction = 'return') is not null then raise exception 'FAIL 3c2: reverse copied a clock time'; end if;
  select * into j from public.route_revision_journeys where revision_id = v_rev and direction = 'return';
  if j.source_city_id <> pg_temp.r('DST') or j.destination_city_id <> pg_temp.r('SRC') then raise exception 'FAIL 3d: reverse endpoints wrong'; end if;
  if (select city_id from public.route_revision_stops where journey_id = j.id and sequence_no = 1) <> pg_temp.r('DST')
     or (select city_id from public.route_revision_stops where journey_id = j.id and sequence_no = 3) <> pg_temp.r('SRC')
     or (select city_id from public.route_revision_stops where journey_id = j.id and sequence_no = 2) <> pg_temp.r('MID') then
    raise exception 'FAIL 3e: reversed stop order wrong';
  end if;
  if not (select is_boarding and not is_dropping from public.route_revision_stops where journey_id = j.id and sequence_no = 1)
     or not (select is_dropping from public.route_revision_stops where journey_id = j.id and sequence_no = 3) then
    raise exception 'FAIL 3f: reversed boarding/dropping flags wrong';
  end if;
  -- mid stop: outbound arrive 120 / depart 125 of 240 -> return arrive 115 / depart 120
  if (select arrival_offset_min from public.route_revision_stops where journey_id = j.id and sequence_no = 2) <> 115
     or (select departure_offset_min from public.route_revision_stops where journey_id = j.id and sequence_no = 2) <> 120 then
    raise exception 'FAIL 3g: reversed times wrong';
  end if;
  -- the return journey is independently editable: a different departure time and days
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip',
    'outbound', jsonb_build_object('source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
      'departure_time', '06:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb,
      'stops', public.get_route_revision_diff(v_rev) -> 'outbound' -> 'proposed' -> 'stops'),
    'return', jsonb_build_object('source_city_id', pg_temp.r('DST'), 'destination_city_id', pg_temp.r('SRC'),
      'departure_time', '15:30', 'duration_min', 240, 'operating_days', '[1,3,5]'::jsonb, 'departure_day_offset', 0,
      'reverse_generated', true,
      'stops', public.get_route_revision_diff(v_rev) -> 'return' -> 'proposed' -> 'stops')));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 3h: edited return rejected: %', r -> 'errors'; end if;

  begin
    perform public.submit_route_revision(v_rev, '   ');
    raise exception 'FAIL 3i: a reason must be required for an active bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  r := public.submit_route_revision(v_rev, 'Add a return journey');
  if r ->> 'status' <> 'pending_approval' then raise exception 'FAIL 3j: expected pending_approval, got %', r; end if;
  select count(*) into n from public.bus_routes where bus_id = v_bus and direction = 'return';
  if n <> 0 then raise exception 'FAIL 3k: pending revision leaked into the live route'; end if;
  if (select active_route_revision_id from public.buses where id = v_bus) <> pg_temp.r('REV1') then raise exception 'FAIL 3l: active revision changed while pending'; end if;
  insert into t_ref values ('REV2', v_rev);
end $$;

-- ---- 4. immutability, authorization -------------------------------------
do $$
declare v_rev uuid := pg_temp.r('REV2');
begin
  begin
    perform public.save_route_revision(v_rev, '{"trip_type":"one_way"}'::jsonb);
    raise exception 'FAIL 4a: a submitted revision was editable';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    update public.route_revisions set status = 'approved' where id = v_rev;
    raise exception 'FAIL 4b: operator wrote route_revisions directly';
  exception when insufficient_privilege then null; end;
  begin
    perform public.admin_review_route_revision(v_rev, 'approve', null);
    raise exception 'FAIL 4c: operator approved a route change';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.start_route_revision(pg_temp.r('BUS'));
    raise exception 'FAIL 4d: second open revision allowed while one is pending';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- the submitted content cannot be changed even by a privileged writer (trigger)
reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  begin
    update public.route_revisions set change_reason = 'tampered' where id = pg_temp.r('REV2');
    raise exception 'FAIL 4e: submitted revision content mutable';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    update public.route_revision_journeys set departure_time = '01:00' where revision_id = pg_temp.r('REV2') and direction = 'return';
    raise exception 'FAIL 4f: submitted journey mutable';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if (select count(*) from public.route_revisions) <> 0 then raise exception 'FAIL 4g: another operator can see the revision'; end if;
  begin
    perform public.start_route_revision(pg_temp.r('BUS'));
    raise exception 'FAIL 4h: another operator started a revision on this bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    perform public.admin_review_route_revision(pg_temp.r('REV2'), 'approve', null);
    raise exception 'FAIL 4i: another operator approved';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

select set_config('request.jwt.claims', '{"sub":"dddddddd-0000-0000-0000-00000000000d","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if (select count(*) from public.route_revisions) <> 0 then raise exception 'FAIL 4j: a customer can read revisions'; end if;
end $$;
reset role;
set local role anon;
do $$
begin
  begin
    perform 1 from public.route_revisions;
    raise exception 'FAIL 4k: anon can read revisions';
  exception when insufficient_privilege then null; end;
end $$;
reset role;

-- self-approval is blocked: make admin1 the submitter (trigger disabled just for this fixture)
alter table public.route_revisions disable trigger route_revisions_immutable;
update public.route_revisions set submitted_by = 'cccccccc-0000-0000-0000-00000000000c' where id = pg_temp.r('REV2');
alter table public.route_revisions enable trigger route_revisions_immutable;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.admin_review_route_revision(pg_temp.r('REV2'), 'approve', null);
    raise exception 'FAIL 4l: an admin approved their own submission';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
reset role;
alter table public.route_revisions disable trigger route_revisions_immutable;
update public.route_revisions set submitted_by = 'aaaaaaaa-0000-0000-0000-00000000000a' where id = pg_temp.r('REV2');
alter table public.route_revisions enable trigger route_revisions_immutable;

-- ---- 5. admin: diff, reject (reason required), live unchanged ----------------
select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-00000000000f","role":"authenticated"}', true);
set local role authenticated;
do $$
declare d jsonb; v_rev uuid := pg_temp.r('REV2'); rv public.route_revisions;
begin
  d := public.get_route_revision_diff(v_rev);
  if d -> 'trip_type' ->> 'current' <> 'one_way' or d -> 'trip_type' ->> 'proposed' <> 'round_trip' then raise exception 'FAIL 5a: trip type diff wrong: %', d -> 'trip_type'; end if;
  if not (d -> 'return' -> 'changes' ->> 'added_journey')::boolean then raise exception 'FAIL 5b: return journey not reported as added'; end if;
  if jsonb_array_length(d -> 'outbound' -> 'changes' -> 'added_stops') <> 0 then raise exception 'FAIL 5c: outbound should be unchanged'; end if;

  begin
    perform public.admin_review_route_revision(v_rev, 'reject', '  ');
    raise exception 'FAIL 5d: rejection without a reason accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  rv := public.admin_review_route_revision(v_rev, 'reject', 'Return times overlap another bus');
  if rv.status <> 'rejected' or rv.rejection_reason is null or rv.reviewed_by <> 'ffffffff-0000-0000-0000-00000000000f' then
    raise exception 'FAIL 5e: rejection not recorded';
  end if;
  if (select count(*) from public.bus_routes where bus_id = pg_temp.r('BUS') and direction = 'return') <> 0 then raise exception 'FAIL 5f: rejected change went live'; end if;
  if (select active_route_revision_id from public.buses where id = pg_temp.r('BUS')) <> pg_temp.r('REV1') then raise exception 'FAIL 5g: active revision changed on rejection'; end if;
  begin
    perform public.admin_review_route_revision(v_rev, 'approve', null);
    raise exception 'FAIL 5h: a rejected revision was approved';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  if (select rejection_reason from public.route_revisions where id = pg_temp.r('REV2')) is null then raise exception 'FAIL 5i: operator cannot see the rejection reason'; end if;
  if not exists (select 1 from public.notifications where type = 'route_revision_rejected') then raise exception 'FAIL 5j: operator not notified of the rejection'; end if;
end $$;

-- ---- 6. resubmit the corrected revision, approve atomically -------------------
do $$
declare
  v_bus uuid := pg_temp.r('BUS');
  v_rev uuid; r jsonb;
begin
  v_rev := public.start_route_revision(v_bus, pg_temp.r('REV2'));
  if (select trip_type from public.route_revisions where id = v_rev) <> 'round_trip' then raise exception 'FAIL 6a: resubmission lost the round trip'; end if;
  if (select base_revision_id from public.route_revisions where id = v_rev) <> pg_temp.r('REV2') then raise exception 'FAIL 6b: base revision not recorded'; end if;
  -- correction: move the return departure
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip',
    'outbound', public.get_route_revision_diff(v_rev) -> 'outbound' -> 'proposed' || '{"duration_min":240}'::jsonb,
    'return', (public.get_route_revision_diff(v_rev) -> 'return' -> 'proposed') || '{"departure_time":"16:30"}'::jsonb));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 6c: corrected revision invalid: %', r -> 'errors'; end if;
  r := public.submit_route_revision(v_rev, 'Corrected return time');
  if r ->> 'status' <> 'pending_approval' then raise exception 'FAIL 6d: %', r; end if;
  insert into t_ref values ('REV3', v_rev);
end $$;

select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-00000000000f","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_bus uuid := pg_temp.r('BUS');
  rv public.route_revisions;
  v_out uuid; v_ret uuid; n int;
begin
  rv := public.admin_review_route_revision(pg_temp.r('REV3'), 'approve', null);
  if rv.status <> 'approved' then raise exception 'FAIL 6e: not approved'; end if;
  if (select active_route_revision_id from public.buses where id = v_bus) <> pg_temp.r('REV3') then raise exception 'FAIL 6f: bus active revision not updated'; end if;
  if (select status from public.route_revisions where id = pg_temp.r('REV1')) <> 'superseded' then raise exception 'FAIL 6g: previous revision not superseded'; end if;
  if (select status from public.route_revisions where id = pg_temp.r('REV2')) <> 'rejected' then raise exception 'FAIL 6h: rejected revision changed'; end if;

  select id into v_out from public.bus_routes where bus_id = v_bus and direction = 'outbound';
  select id into v_ret from public.bus_routes where bus_id = v_bus and direction = 'return';
  if v_ret is null then raise exception 'FAIL 6i: return route not created'; end if;
  if (select linked_route_id from public.bus_routes where id = v_out) <> v_ret or (select linked_route_id from public.bus_routes where id = v_ret) <> v_out then
    raise exception 'FAIL 6j: routes not linked both ways';
  end if;
  if (select source_city_id from public.bus_routes where id = v_ret) <> pg_temp.r('DST') then raise exception 'FAIL 6k: return starts at the wrong place'; end if;

  -- independent service configuration per direction
  if (select default_departure_time from public.bus_services where route_id = v_out) <> time '06:00'
     or (select default_departure_time from public.bus_services where route_id = v_ret) <> time '16:30' then
    raise exception 'FAIL 6l: directions do not keep their own departure times';
  end if;
  if (select operating_days from public.bus_services where route_id = v_ret) <> '{1,3,5}'::smallint[] then raise exception 'FAIL 6m: return operating days wrong'; end if;
  if (select direction from public.bus_services where route_id = v_ret) <> 'return' then raise exception 'FAIL 6n: return service direction'; end if;
  if (select status::text from public.bus_services where route_id = v_ret) <> 'active' then raise exception 'FAIL 6o: return service should follow the active bus'; end if;
  select count(*) into n from public.fare_rules where service_id = (select id from public.bus_services where route_id = v_ret);
  if n <> 1 then raise exception 'FAIL 6p: return service did not inherit the base fare'; end if;
  select count(*) into n from public.boarding_points where route_id = v_ret and is_active;
  if n <> 2 then raise exception 'FAIL 6q: return boarding points %', n; end if;
  if not exists (select 1 from public.notifications where type = 'route_revision_approved') then raise exception 'FAIL 6r: operator not notified'; end if;
  if (select count(*) from public.route_revision_events where revision_id = pg_temp.r('REV3')) < 3 then raise exception 'FAIL 6s: history events missing'; end if;
  insert into t_ref values ('OUT', v_out), ('RET', v_ret);
end $$;

-- ---- 7. both directions generate trips and are searchable; the old booking is intact ----
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare n int;
begin
  n := public.generate_bus_trips(pg_temp.r('BUS'), current_date + 1, current_date + 7);
  if (select count(*) from public.bus_trips where route_id = pg_temp.r('RET')) = 0 then raise exception 'FAIL 7a: no return trips generated'; end if;
  if (select count(*) from public.bus_trips where route_id = pg_temp.r('OUT')) = 0 then raise exception 'FAIL 7b: no outbound trips generated'; end if;
  if exists (select 1 from public.bus_trips t join public.bus_services s on s.id = t.service_id
             where t.route_id = pg_temp.r('RET') and not (extract(isodow from t.travel_date)::smallint = any (s.operating_days))) then
    raise exception 'FAIL 7c: return trips ignore the return operating days';
  end if;
end $$;
reset role;
select set_config('t.out_date', (select min(travel_date)::text from public.bus_trips where route_id = pg_temp.r('OUT') and departure_at > now()), true),
       set_config('t.ret_date', (select min(travel_date)::text from public.bus_trips where route_id = pg_temp.r('RET') and departure_at > now()), true);
set local role anon;
do $$
declare d jsonb; r jsonb;
begin
  r := public.search_trips(pg_temp.r('DST'), pg_temp.r('SRC'), current_setting('t.ret_date')::date);
  if jsonb_array_length(r -> 'direct') = 0 then raise exception 'FAIL 7d: return journey not found by customer search'; end if;
  if r -> 'direct' -> 0 ->> 'direction' <> 'return' then raise exception 'FAIL 7d2: search result missing the return direction'; end if;
  if public.get_trip_points((r -> 'direct' -> 0 ->> 'trip_id')::uuid) ->> 'direction' <> 'return' then raise exception 'FAIL 7d3: trip points missing direction'; end if;
  r := public.search_trips(pg_temp.r('SRC'), pg_temp.r('DST'), current_setting('t.out_date')::date);
  if jsonb_array_length(r -> 'direct') = 0 then raise exception 'FAIL 7e: outbound journey not found by customer search'; end if;
end $$;
reset role;

-- ---- 8. remove the middle stop from the OUTBOUND only; booking points survive and are flagged ----
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare
  v_bus uuid := pg_temp.r('BUS');
  v_rev uuid; r jsonb; d jsonb;
begin
  v_rev := public.start_route_revision(v_bus);
  d := public.get_route_revision_diff(v_rev);
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip',
    'outbound', jsonb_build_object('source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
      'departure_time', '06:00', 'duration_min', 240, 'operating_days', '[1,2,3,4,5,6,7]'::jsonb,
      'stops', jsonb_build_array(pg_temp.t_st(pg_temp.r('SRC'), true, false, 0, 0), pg_temp.t_st(pg_temp.r('DST'), false, true, 240, 240))),
    'return', d -> 'return' -> 'proposed'));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 8a: %', r -> 'errors'; end if;
  r := public.submit_route_revision(v_rev, 'Skip the middle stop');
  insert into t_ref values ('REV4', v_rev);
end $$;

select set_config('request.jwt.claims', '{"sub":"ffffffff-0000-0000-0000-00000000000f","role":"authenticated"}', true);
set local role authenticated;
do $$
declare d jsonb; n_before int; n_after int; rv public.route_revisions;
begin
  d := public.get_route_revision_diff(pg_temp.r('REV4'));
  if jsonb_array_length(d -> 'outbound' -> 'changes' -> 'removed_stops') <> 1 then raise exception 'FAIL 8b: removed stop not highlighted'; end if;
  if jsonb_array_length(d -> 'return' -> 'changes' -> 'removed_stops') <> 0 then raise exception 'FAIL 8c: return wrongly changed'; end if;
  select count(*) into n_before from public.boarding_points where route_id = pg_temp.r('OUT');
  rv := public.admin_review_route_revision(pg_temp.r('REV4'), 'approve', null);
  select count(*) into n_after from public.boarding_points where route_id = pg_temp.r('OUT');
  if n_before <> n_after then raise exception 'FAIL 8d: points were deleted (% -> %)', n_before, n_after; end if;
  if (select is_active from public.dropping_points where id = pg_temp.r('D_MID')) then raise exception 'FAIL 8e: removed stop still active'; end if;
  if (select count(*) from public.boarding_points where route_id = pg_temp.r('RET') and is_active) <> 2 then raise exception 'FAIL 8f: return route changed by an outbound edit'; end if;
  if not exists (select 1 from public.booking_items bi join public.dropping_points dp on dp.id = bi.dropping_point_id where dp.id = pg_temp.r('D_MID')) then
    raise exception 'FAIL 8g: existing booking lost its dropping point';
  end if;
  if not exists (select 1 from public.route_change_flags f join public.booking_items bi on bi.id = f.booking_item_id
                 where f.revision_id = pg_temp.r('REV4') and f.reason = 'point_removed' and bi.dropping_point_id = pg_temp.r('D_MID')) then
    raise exception 'FAIL 8h: affected booking not flagged';
  end if;
  if (select dropping_point_id from public.booking_items limit 1) <> pg_temp.r('D_MID') then raise exception 'FAIL 8i: booking silently changed'; end if;
end $$;

-- ---- 9. incomplete round trip cannot be submitted; withdraw ---------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_rev uuid; r jsonb; d jsonb;
begin
  v_rev := public.start_route_revision(pg_temp.r('BUS'));
  d := public.get_route_revision_diff(v_rev);
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip', 'outbound', d -> 'outbound' -> 'proposed'));
  if (r ->> 'valid')::boolean then raise exception 'FAIL 9a: round trip without a return validated'; end if;
  r := public.submit_route_revision(v_rev, 'Incomplete');
  if (r ->> 'ok')::boolean then raise exception 'FAIL 9b: incomplete round trip submitted'; end if;
  if (select status from public.route_revisions where id = v_rev) <> 'draft' then raise exception 'FAIL 9c: failed submit changed status'; end if;
  -- a return that does not start where the outbound ends is refused
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'round_trip', 'outbound', d -> 'outbound' -> 'proposed',
        'return', (d -> 'outbound' -> 'proposed')));
  if (r ->> 'valid')::boolean then raise exception 'FAIL 9d: return identical to outbound validated'; end if;
  perform public.withdraw_route_revision(v_rev);
  if (select status from public.route_revisions where id = v_rev) <> 'withdrawn' then raise exception 'FAIL 9e: withdraw'; end if;
end $$;

-- ---- 10. switching back to one way retires the return journey (not deleted) ----------
do $$
declare v_rev uuid; r jsonb; d jsonb;
begin
  v_rev := public.start_route_revision(pg_temp.r('BUS'));
  d := public.get_route_revision_diff(v_rev);
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'one_way', 'outbound', d -> 'outbound' -> 'proposed'));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 10a: %', r -> 'errors'; end if;
  perform public.submit_route_revision(v_rev, 'Drop the return service');
  insert into t_ref values ('REV5', v_rev);
end $$;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  perform public.admin_review_route_revision(pg_temp.r('REV5'), 'approve', null);
  if (select status::text from public.bus_services where route_id = pg_temp.r('RET')) <> 'retired' then raise exception 'FAIL 10b: return service not retired'; end if;
  if (select active from public.bus_routes where id = pg_temp.r('RET')) then raise exception 'FAIL 10c: return route still active'; end if;
  if (select count(*) from public.boarding_points where route_id = pg_temp.r('RET')) = 0 then raise exception 'FAIL 10d: return points deleted'; end if;
  if (select linked_route_id from public.bus_routes where id = pg_temp.r('OUT')) is not null then raise exception 'FAIL 10e: stale link'; end if;
end $$;
reset role;

-- ---- 11. operator staff can apply a route while the bus is still being set up; a driver cannot ----
select set_config('request.jwt.claims', '', true);
insert into auth.users (id, email) values
  ('11111111-0000-0000-0000-000000000011', 'staff@test.invalid'),
  ('22222222-0000-0000-0000-000000000022', 'driver@test.invalid');
insert into public.user_roles (user_id, role, operator_id) values
  ('11111111-0000-0000-0000-000000000011', 'operator_staff', pg_temp.r('OPA')),
  ('22222222-0000-0000-0000-000000000022', 'driver', pg_temp.r('OPA'));
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'BUS2', (public.create_bus(pg_temp.r('OPA'), 'Staff Bus', 'AN01R0002', 'ac_seater', 3)).id;
select set_config('request.jwt.claims', '{"sub":"22222222-0000-0000-0000-000000000022","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
  begin
    perform public.start_route_revision(pg_temp.r('BUS2'));
    raise exception 'FAIL 11a: a driver started a route revision';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
select set_config('request.jwt.claims', '{"sub":"11111111-0000-0000-0000-000000000011","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_rev uuid; r jsonb;
begin
  v_rev := public.start_route_revision(pg_temp.r('BUS2'));
  r := public.save_route_revision(v_rev, jsonb_build_object('trip_type', 'one_way', 'outbound', jsonb_build_object(
    'source_city_id', pg_temp.r('SRC'), 'destination_city_id', pg_temp.r('DST'),
    'departure_time', '07:00', 'duration_min', 240, 'operating_days', '[1,2,3]'::jsonb,
    'stops', jsonb_build_array(pg_temp.t_st(pg_temp.r('SRC'), true, false, 0, 0), pg_temp.t_st(pg_temp.r('DST'), false, true, 240, 240)))));
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 11b: %', r -> 'errors'; end if;
  r := public.submit_route_revision(v_rev, null);
  if r ->> 'status' <> 'approved' then raise exception 'FAIL 11c: staff could not apply the setup route: %', r; end if;
end $$;
reset role;

rollback;
