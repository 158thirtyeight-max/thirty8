-- =========================================================================
-- Phase 11 checks for 20260926001000_bus_approval_activation.sql
-- End-to-end bus workflow, plus the legacy-bus migration path.
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid'),
  ('cccccccc-0000-0000-0000-00000000000c', 'admin@test.invalid');
insert into public.user_roles (user_id, role) values ('cccccccc-0000-0000-0000-00000000000c', 'platform_admin');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;
create temp table t_ref (tag text, id uuid);
grant all on t_ref to authenticated;

insert into public.countries (code, name) values ('ZZ', 'Testland') on conflict (code) do nothing;
with c as (insert into public.cities (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'W Src') returning id)
  insert into t_ref select 'SRC', id from c;
with c as (insert into public.cities (country_id, name) values ((select id from public.countries where code = 'ZZ'), 'W Dst') returning id)
  insert into t_ref select 'DST', id from c;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

-- ---- 1. operator builds a bus, stage by stage ---------------------------
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ref select 'BUS', (public.create_bus((select id from t_ops where tag = 'A'), 'Workflow Bus', 'AN01W0001', 'ac_seater', 2, 'Tata', 'Starbus', 2022, 2022)).id;

do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); r jsonb;
begin
  -- nothing configured: incomplete, cannot be submitted
  r := public.bus_completeness(v_bus);
  if (r ->> 'complete')::boolean then raise exception 'FAIL 1a: empty bus reported complete'; end if;
  begin
    perform public.submit_bus(v_bus);
    raise exception 'FAIL 1b: incomplete bus submitted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  perform public.save_bus_layout(v_bus, '{"rows":1,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":3,"seat_type":"seater"}]'::jsonb);
  perform public.save_bus_route(v_bus, (select id from t_ref where tag = 'SRC'), (select id from t_ref where tag = 'DST'),
    50, '07:00', 120, '{1,2,3,4,5,6,7}', '[
      {"name":"A","is_boarding":true,"is_dropping":false,"arrival_offset_min":0,"departure_offset_min":0},
      {"name":"B","is_boarding":false,"is_dropping":true,"arrival_offset_min":120,"departure_offset_min":120}]'::jsonb);
  perform public.save_bus_fares(v_bus, '[{"seat_type":"seater","base_fare_cents":30000}]'::jsonb, '[]'::jsonb);
  perform public.save_bus_schedule(v_bus, '07:00', '{1,2,3,4,5,6,7}', 30, 30, 10);
  update public.buses set exterior_photo_path = 'x/y/e.jpg', interior_photo_path = 'x/y/i.jpg' where id = v_bus;

  -- documents still missing
  r := public.bus_completeness(v_bus);
  if (r ->> 'complete')::boolean then raise exception 'FAIL 1c: complete without documents'; end if;
  if not (r -> 'missing') ? 'Registration Certificate (RC)' then raise exception 'FAIL 1d: RC not listed as missing: %', r -> 'missing'; end if;

  insert into public.bus_documents (bus_id, doc_type, file_path, expiry_date) values
    (v_bus, 'rc', 'x/y/rc.pdf', null),
    (v_bus, 'insurance', 'x/y/ins.pdf', current_date + 200),
    (v_bus, 'fitness', 'x/y/fit.pdf', current_date + 200),
    (v_bus, 'permit', 'x/y/per.pdf', current_date + 200),
    (v_bus, 'puc', 'x/y/puc.pdf', current_date + 200);

  r := public.bus_completeness(v_bus);
  if not (r ->> 'complete')::boolean then raise exception 'FAIL 1e: fully set up bus not complete: %', r -> 'missing'; end if;
  if (r ->> 'percent')::int <> 100 then raise exception 'FAIL 1f: percent %', r ->> 'percent'; end if;
end $$;

-- ---- 2. submit; operator cannot approve/activate ------------------------
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); b public.buses;
begin
  b := public.submit_bus(v_bus);
  if b.lifecycle_status <> 'submitted' then raise exception 'FAIL 2a: got %', b.lifecycle_status; end if;
  begin perform public.admin_review_bus(v_bus, 'approve'); raise exception 'FAIL 2b: operator approved own bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.activate_bus(v_bus); raise exception 'FAIL 2c: unapproved bus activated';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin update public.buses set total_seats = 5 where id = v_bus; raise exception 'FAIL 2d: core details editable after submit';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.save_bus_layout(v_bus, '{"rows":1,"cols":1,"decks":1}'::jsonb, '[]'::jsonb); raise exception 'FAIL 2e: layout editable after submit';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

-- ---- 3. admin review: docs must be verified, reasons required ----------
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); b public.buses; r record;
begin
  b := public.admin_review_bus(v_bus, 'start_review');
  if b.lifecycle_status <> 'under_review' then raise exception 'FAIL 3a: got %', b.lifecycle_status; end if;

  begin perform public.admin_review_bus(v_bus, 'approve'); raise exception 'FAIL 3b: approved with unverified documents';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_review_bus(v_bus, 'request_changes', ' '); raise exception 'FAIL 3c: changes requested without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- request changes -> operator can edit -> resubmit
  b := public.admin_review_bus(v_bus, 'request_changes', 'Interior photo is unclear');
  if b.lifecycle_status <> 'changes_requested' or b.review_reason <> 'Interior photo is unclear' then
    raise exception 'FAIL 3d: %', b.lifecycle_status;
  end if;
end $$;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); b public.buses;
begin
  update public.buses set interior_photo_path = 'x/y/i2.jpg' where id = v_bus;   -- editable again
  b := public.submit_bus(v_bus);
  if b.lifecycle_status <> 'submitted' or b.review_reason is not null then raise exception 'FAIL 3e: resubmit %', b.lifecycle_status; end if;
end $$;

select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); b public.buses; d record;
begin
  perform public.admin_review_bus(v_bus, 'start_review');
  for d in select id from public.bus_documents where bus_id = v_bus loop
    perform public.admin_review_bus_document(d.id, 'verify');
  end loop;
  b := public.admin_review_bus(v_bus, 'approve');
  if b.lifecycle_status <> 'approved' or b.approved_by <> 'cccccccc-0000-0000-0000-00000000000c' or b.approved_at is null then
    raise exception 'FAIL 3f: approval not recorded: %', b.lifecycle_status;
  end if;
  if public.bus_verification_state(v_bus) <> 'verified' then raise exception 'FAIL 3g: state %', public.bus_verification_state(v_bus); end if;
end $$;

-- ---- 4. approved is not yet bookable; activation re-checks -------------
reset role;
select set_config('request.jwt.claims', '', true);
with s as (select id, operator_id, route_id, bus_id from public.bus_services where bus_id = (select id from t_ref where tag = 'BUS'))
insert into public.bus_trips (service_id, operator_id, route_id, bus_id, travel_date, departure_at)
select id, operator_id, route_id, bus_id, current_date + 3, (current_date + 3) + time '07:00' from s;

do $$
begin
  if private.is_bus_bookable((select id from t_ref where tag = 'BUS')) then raise exception 'FAIL 4a: approved-but-inactive bus is bookable'; end if;
end $$;

-- an expired required document blocks activation
update public.bus_documents set expiry_date = current_date - 1
where bus_id = (select id from t_ref where tag = 'BUS') and doc_type = 'puc';

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); r jsonb; b public.buses;
begin
  r := public.bus_activation_readiness(v_bus);
  if (r ->> 'ready')::boolean or not (r ->> 'blockers') like '%Pollution Under Control (PUC) has expired%' then
    raise exception 'FAIL 4b: expired PUC not a blocker: %', r;
  end if;
  begin perform public.activate_bus(v_bus); raise exception 'FAIL 4c: activated with an expired document';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;

  -- renew the document; renewal resets verification, so it must be re-verified
  update public.bus_documents set expiry_date = current_date + 300 where bus_id = v_bus and doc_type = 'puc';
  begin perform public.activate_bus(v_bus); raise exception 'FAIL 4d: activated with an unverified renewal';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
select public.admin_review_bus_document((select id from public.bus_documents where doc_type = 'puc' and bus_id = (select id from t_ref where tag = 'BUS')), 'verify');

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); b public.buses;
begin
  b := public.activate_bus(v_bus);
  if b.lifecycle_status <> 'active' or b.activated_at is null then raise exception 'FAIL 4e: not active'; end if;
  if (select status::text from public.bus_services where bus_id = v_bus) <> 'active' then raise exception 'FAIL 4f: service not activated'; end if;
end $$;

reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  if not private.is_bus_bookable((select id from t_ref where tag = 'BUS')) then raise exception 'FAIL 5a: active bus not bookable'; end if;
end $$;

-- ---- 5. operator B cannot touch A's bus; suspension hides it ----------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS');
begin
  begin perform public.deactivate_bus(v_bus); raise exception 'FAIL 5b: operator B deactivated A bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.submit_bus(v_bus); raise exception 'FAIL 5c: operator B submitted A bus';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.bus_completeness(v_bus); raise exception 'FAIL 5d: operator B read A checklist';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;

select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-0000-0000-00000000000c","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'BUS'); b public.buses;
begin
  begin perform public.admin_review_bus(v_bus, 'suspend'); raise exception 'FAIL 6a: suspended without a reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  b := public.admin_review_bus(v_bus, 'suspend', 'Safety complaint');
  if b.lifecycle_status <> 'suspended' then raise exception 'FAIL 6b: %', b.lifecycle_status; end if;
  if (select status::text from public.bus_services where bus_id = v_bus) <> 'paused' then raise exception 'FAIL 6c: service still active'; end if;
  b := public.admin_review_bus(v_bus, 'reinstate');
  if b.lifecycle_status <> 'active' then raise exception 'FAIL 6d: reinstated to %', b.lifecycle_status; end if;
end $$;

-- ---- 7. legacy migration path ------------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
-- a pre-existing bus: active, flagged legacy, never reviewed (as the Phase 5 backfill leaves them)
with b as (
  insert into public.buses (operator_id, registration_number, bus_type, total_seats, lifecycle_status, is_legacy)
  values ((select id from t_ops where tag = 'A'), 'AN01L0001', 'ac_seater', 2, 'active', true) returning id)
insert into t_ref select 'LEGACY', id from b;

do $$
declare v_bus uuid := (select id from t_ref where tag = 'LEGACY');
begin
  if (select lifecycle_status::text from public.buses where id = v_bus) <> 'active' then raise exception 'FAIL 7a'; end if;
  if (select approved_by from public.buses where id = v_bus) is not null then raise exception 'FAIL 7b: legacy bus stamped as approved'; end if;
end $$;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_ref where tag = 'LEGACY');
begin
  if public.bus_verification_state(v_bus) <> 'legacy' then raise exception 'FAIL 7c: expected legacy, got %', public.bus_verification_state(v_bus); end if;
  -- incomplete legacy bus cannot be submitted, and stays active while incomplete
  begin perform public.submit_bus(v_bus); raise exception 'FAIL 7d: incomplete legacy bus submitted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  if (select lifecycle_status::text from public.buses where id = v_bus) <> 'active' then raise exception 'FAIL 7e: legacy bus went offline'; end if;
end $$;

rollback;
select 'onboarding_phase11: all assertions passed' as result;
