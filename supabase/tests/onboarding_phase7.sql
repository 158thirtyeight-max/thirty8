-- =========================================================================
-- Phase 7 checks for 20260926000600_seat_layout.sql
-- Run after pushing migrations (see onboarding_phase2.sql header). Rolled back.
-- Trip-inventory behaviour (only bookable seats become trip_seats, layout
-- versioning when trips exist) needs cities/routes/services and is covered by
-- the end-to-end run in Phase 13.
-- =========================================================================
begin;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'op-a@test.invalid'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'op-b@test.invalid');

create temp table t_ops (tag text, id uuid);
grant all on t_ops to authenticated;
create temp table t_bus (tag text, id uuid);
grant all on t_bus to authenticated;

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'A', (public.register_operator('Op A', 'Op A Pvt Ltd', 'bus', 'a@test.invalid', '9876543210')).id;
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
insert into t_ops select 'B', (public.register_operator('Op B', 'Op B Pvt Ltd', 'bus', 'b@test.invalid', '9876543211')).id;
reset role;
select set_config('request.jwt.claims', '', true);
update public.operators set status = 'approved', application_status = 'approved';

select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
insert into t_bus select 'SEATER', (public.create_bus((select id from t_ops where tag = 'A'), 'Seater', 'AN01A0001', 'ac_seater', 5)).id;
insert into t_bus select 'SLEEPER', (public.create_bus((select id from t_ops where tag = 'A'), 'Sleeper', 'AN01A0002', 'ac_sleeper', 2)).id;

-- ---- 1. no layout yet -> invalid ---------------------------------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'SEATER'); r jsonb;
begin
  r := public.validate_bus_layout(v_bus);
  if (r ->> 'valid')::boolean then raise exception 'FAIL 1: bus without a layout reported valid'; end if;
end $$;

-- ---- 2. a correct seater layout ----------------------------------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'SEATER'); r jsonb;
begin
  r := public.save_bus_layout(v_bus, '{"rows":3,"cols":3,"decks":1,"aisle_cols":[2],"numbering":"row_letter"}'::jsonb, '[
    {"seat_code":"DRV","deck":1,"row_no":1,"col_no":3,"seat_type":"seater","kind":"crew"},
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater","kind":"bookable"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater","kind":"bookable"},
    {"seat_code":"2B","deck":1,"row_no":2,"col_no":3,"seat_type":"seater","kind":"bookable"},
    {"seat_code":"3A","deck":1,"row_no":3,"col_no":1,"seat_type":"seater","kind":"bookable"},
    {"seat_code":"3B","deck":1,"row_no":3,"col_no":3,"seat_type":"seater","kind":"bookable"}
  ]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 2a: valid layout rejected: %', r -> 'errors'; end if;
  if (r -> 'stats' ->> 'bookable')::int <> 5 then raise exception 'FAIL 2b: bookable count %', r -> 'stats'; end if;
  if jsonb_array_length(r -> 'warnings') <> 0 then raise exception 'FAIL 2c: unexpected warnings %', r -> 'warnings'; end if;
end $$;

-- ---- 3. structural errors ----------------------------------------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'SEATER'); r jsonb;
begin
  -- duplicate cell + duplicate number
  r := public.save_bus_layout(v_bus, '{"rows":3,"cols":3,"decks":1,"aisle_cols":[2],"numbering":"row_letter"}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"1B","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3A","deck":1,"row_no":3,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3B","deck":1,"row_no":3,"col_no":3,"seat_type":"seater"}
  ]'::jsonb);
  if (r ->> 'valid')::boolean or not (r ->> 'errors') like '%more than one seat%' then
    raise exception 'FAIL 3a: duplicate cell not reported: %', r -> 'errors';
  end if;

  -- capacity mismatch (4 bookable vs capacity 5)
  r := public.save_bus_layout(v_bus, '{"rows":3,"cols":3,"decks":1,"aisle_cols":[2],"numbering":"row_letter"}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3A","deck":1,"row_no":3,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3B","deck":1,"row_no":3,"col_no":3,"seat_type":"seater"}
  ]'::jsonb);
  if (r ->> 'valid')::boolean or not (r ->> 'errors') like '%do not match the bus capacity%' then
    raise exception 'FAIL 3b: capacity mismatch not reported: %', r -> 'errors';
  end if;

  -- seat on the aisle, outside the grid
  r := public.save_bus_layout(v_bus, '{"rows":3,"cols":3,"decks":1,"aisle_cols":[2],"numbering":"row_letter"}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":2,"seat_type":"seater"},
    {"seat_code":"9Z","deck":1,"row_no":9,"col_no":1,"seat_type":"seater"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3A","deck":1,"row_no":3,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3B","deck":1,"row_no":3,"col_no":3,"seat_type":"seater"}
  ]'::jsonb);
  if not (r ->> 'errors') like '%on the aisle%' or not (r ->> 'errors') like '%outside the layout grid%' then
    raise exception 'FAIL 3c: aisle/out-of-grid not reported: %', r -> 'errors';
  end if;

  -- berth on a seater bus
  r := public.save_bus_layout(v_bus, '{"rows":3,"cols":3,"decks":1,"aisle_cols":[2],"numbering":"row_letter"}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater","berth":"lower"},
    {"seat_code":"2A","deck":1,"row_no":2,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3A","deck":1,"row_no":3,"col_no":1,"seat_type":"seater"},
    {"seat_code":"3B","deck":1,"row_no":3,"col_no":3,"seat_type":"seater"},
    {"seat_code":"2B","deck":1,"row_no":2,"col_no":3,"seat_type":"seater"}
  ]'::jsonb);
  if (r ->> 'valid')::boolean or not (r ->> 'errors') like '%berth assigned%' then
    raise exception 'FAIL 3d: berth on seater not reported: %', r -> 'errors';
  end if;

  -- no bookable seats at all
  r := public.save_bus_layout(v_bus, '{"rows":3,"cols":3,"decks":1,"aisle_cols":[2],"numbering":"row_letter"}'::jsonb, '[
    {"seat_code":"1A","deck":1,"row_no":1,"col_no":1,"seat_type":"seater","kind":"unavailable"}
  ]'::jsonb);
  if not (r ->> 'errors') like '%At least one seat must be available%' then
    raise exception 'FAIL 3e: zero bookable seats not reported: %', r -> 'errors';
  end if;
end $$;

-- ---- 4. sleeper bus berth rules ----------------------------------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'SLEEPER'); r jsonb;
begin
  -- sleeper without berth assignment
  r := public.save_bus_layout(v_bus, '{"rows":1,"cols":3,"decks":2,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"L1","deck":1,"row_no":1,"col_no":1,"seat_type":"sleeper"},
    {"seat_code":"L2","deck":1,"row_no":1,"col_no":3,"seat_type":"sleeper"}
  ]'::jsonb);
  if not (r ->> 'errors') like '%no upper/lower assignment%' then
    raise exception 'FAIL 4a: sleeper without berth not reported: %', r -> 'errors';
  end if;

  -- upper berth without a lower beneath it; wrong deck
  r := public.save_bus_layout(v_bus, '{"rows":1,"cols":3,"decks":2,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"U1","deck":2,"row_no":1,"col_no":1,"seat_type":"sleeper","berth":"upper"},
    {"seat_code":"L2","deck":2,"row_no":1,"col_no":3,"seat_type":"sleeper","berth":"lower"}
  ]'::jsonb);
  if not (r ->> 'errors') like '%no lower berth in the same position%' or not (r ->> 'errors') like '%wrong deck%' then
    raise exception 'FAIL 4b: berth pairing/deck not reported: %', r -> 'errors';
  end if;

  -- correct: two lower + no uppers on a 2-deck config must complain about the empty upper deck
  r := public.save_bus_layout(v_bus, '{"rows":1,"cols":3,"decks":2,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"L1","deck":1,"row_no":1,"col_no":1,"seat_type":"sleeper","berth":"lower"},
    {"seat_code":"L2","deck":1,"row_no":1,"col_no":3,"seat_type":"sleeper","berth":"lower"}
  ]'::jsonb);
  if not (r ->> 'errors') like '%upper deck has no seats%' then
    raise exception 'FAIL 4c: empty upper deck not reported: %', r -> 'errors';
  end if;

  -- fully valid single-deck sleeper (bus capacity 2)
  r := public.save_bus_layout(v_bus, '{"rows":1,"cols":3,"decks":1,"aisle_cols":[2]}'::jsonb, '[
    {"seat_code":"L1","deck":1,"row_no":1,"col_no":1,"seat_type":"sleeper","berth":"lower"},
    {"seat_code":"L2","deck":1,"row_no":1,"col_no":3,"seat_type":"sleeper","berth":"lower"}
  ]'::jsonb);
  if not (r ->> 'valid')::boolean then raise exception 'FAIL 4d: valid sleeper layout rejected: %', r -> 'errors'; end if;
end $$;

-- ---- 5. direct table writes are closed ---------------------------------
do $$
declare v_bus uuid := (select id from t_bus where tag = 'SEATER'); v_layout uuid;
begin
  select id into v_layout from public.bus_layouts where bus_id = v_bus and is_active;
  begin
    insert into public.seats (bus_layout_id, seat_code, deck, row_no, col_no) values (v_layout, 'HACK', 1, 1, 1);
    raise exception 'FAIL 5a: operator inserted a seat directly';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    insert into public.bus_layouts (bus_id) values (v_bus);
    raise exception 'FAIL 5b: operator inserted a layout directly';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 6. another operator cannot edit A's layout ------------------------
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-0000-0000-00000000000b","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_bus where tag = 'SEATER');
begin
  begin
    perform public.save_bus_layout(v_bus, '{"rows":1,"cols":1,"decks":1}'::jsonb, '[]'::jsonb);
    raise exception 'FAIL 6a: operator B saved A layout';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
  begin
    perform public.validate_bus_layout(v_bus);
    raise exception 'FAIL 6b: operator B validated A layout';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

-- ---- 7. layout locked once the bus is in review ------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.buses set lifecycle_status = 'under_review' where registration_number = 'AN01A0001';
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated;
do $$
declare v_bus uuid := (select id from t_bus where tag = 'SEATER');
begin
  begin
    perform public.save_bus_layout(v_bus, '{"rows":1,"cols":1,"decks":1}'::jsonb, '[]'::jsonb);
    raise exception 'FAIL 7: layout editable while under review';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;

rollback;
select 'onboarding_phase7: all assertions passed' as result;
