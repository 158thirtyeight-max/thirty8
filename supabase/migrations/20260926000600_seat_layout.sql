-- =========================================================================
-- Per-bus seat layout (Phase 7)
--
-- Reuses bus_layouts / seats (already one layout per bus). Adds seat kind
-- (bookable / unavailable / reserved / crew / other) and berth (upper /
-- lower), a structural validator, an atomic save RPC, and makes trip seat
-- generation skip non-bookable seats.
--
-- layout_json shape written by the editor:
--   { "rows": int, "cols": int, "decks": 1|2, "aisle_cols": [int...],
--     "numbering": "row_letter" | "sequential" }
-- =========================================================================

alter table public.seats
  add column kind text not null default 'bookable'
    check (kind in ('bookable', 'unavailable', 'reserved', 'crew', 'other')),
  add column berth text check (berth in ('upper', 'lower'));

-- Existing seats are all bookable seats (default), so current trips/bookings are unaffected.

-- Only bookable seats become trip inventory.
create or replace function private.generate_trip_seats()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.trip_seats (trip_id, seat_id, status, fare_cents)
  select
    new.id,
    s.id,
    'available',
    coalesce(
      (
        select fr.base_fare_cents
        from public.fare_rules fr
        where fr.service_id = new.service_id
          and fr.seat_type = s.seat_type
          and fr.effective_from <= new.travel_date
          and (fr.effective_to is null or fr.effective_to >= new.travel_date)
        order by fr.effective_from desc
        limit 1
      ),
      new.min_fare_cents,
      0
    )
  from public.seats s
  join public.bus_layouts bl on bl.id = s.bus_layout_id
  where bl.bus_id = new.bus_id
    and bl.is_active
    and s.kind = 'bookable';

  update public.bus_trips
  set available_seats = (select count(*) from public.trip_seats where trip_id = new.id and status = 'available')
  where id = new.id;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Layout changes only go through save_bus_layout(): no direct operator
-- writes to layouts/seats (they could otherwise edit an approved bus).
-- ---------------------------------------------------------------------
drop policy bus_layouts_operator_manage on public.bus_layouts;
drop policy seats_operator_manage on public.seats;

create policy bus_layouts_operator_select on public.bus_layouts
  for select to authenticated
  using (private.is_operator_staff(private.bus_operator_id(bus_id)));

-- ---------------------------------------------------------------------
-- Structural validation. Returns {valid, errors[], warnings[], stats}.
-- ---------------------------------------------------------------------
create or replace function public.validate_bus_layout(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_layout public.bus_layouts;
  v_active_count integer;
  v_errors text[] := '{}';
  v_warnings text[] := '{}';
  v_rows integer;
  v_cols integer;
  v_decks integer;
  v_aisles integer[] := '{}';
  v_total integer;
  v_bookable integer;
  v_n integer;
  v_seat_type_kind text;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then
    raise exception 'Bus not found';
  end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  select count(*) into v_active_count from public.bus_layouts where bus_id = p_bus_id and is_active;
  if v_active_count = 0 then
    return jsonb_build_object('valid', false, 'errors', jsonb_build_array('No seat layout has been configured'),
                              'warnings', '[]'::jsonb, 'stats', jsonb_build_object('total', 0, 'bookable', 0));
  elsif v_active_count > 1 then
    v_errors := array_append(v_errors, 'More than one active layout exists for this bus');
  end if;

  select * into v_layout from public.bus_layouts where bus_id = p_bus_id and is_active order by version desc limit 1;

  -- layout_json dimensions
  if jsonb_typeof(v_layout.layout_json -> 'rows') = 'number'
     and jsonb_typeof(v_layout.layout_json -> 'cols') = 'number' then
    v_rows := (v_layout.layout_json ->> 'rows')::integer;
    v_cols := (v_layout.layout_json ->> 'cols')::integer;
  end if;
  if v_rows is null or v_cols is null or v_rows < 1 or v_cols < 1 or v_rows > 40 or v_cols > 8 then
    v_errors := array_append(v_errors, 'Layout dimensions are missing or invalid (rows 1-40, columns 1-8)');
  end if;
  v_decks := coalesce((v_layout.layout_json ->> 'decks')::integer, v_layout.deck_count);
  if v_decks <> v_layout.deck_count then
    v_errors := array_append(v_errors, 'Layout deck count does not match the saved layout');
  end if;
  if jsonb_typeof(v_layout.layout_json -> 'aisle_cols') = 'array' then
    select coalesce(array_agg(x::integer), '{}') into v_aisles from jsonb_array_elements_text(v_layout.layout_json -> 'aisle_cols') x;
  end if;

  select count(*), count(*) filter (where kind = 'bookable')
    into v_total, v_bookable
  from public.seats where bus_layout_id = v_layout.id;

  if v_total = 0 then
    v_errors := array_append(v_errors, 'The layout has no seats');
  end if;
  if v_bookable = 0 then
    v_errors := array_append(v_errors, 'At least one seat must be available for booking');
  end if;

  -- duplicate seat numbers (codes are unique by constraint; also catch case/space variants)
  select count(*) into v_n from (
    select upper(btrim(seat_code)) from public.seats where bus_layout_id = v_layout.id
    group by 1 having count(*) > 1
  ) d;
  if v_n > 0 then v_errors := v_errors || format('%s duplicate seat number(s)', v_n); end if;

  -- two seats in the same cell
  select count(*) into v_n from (
    select 1 from public.seats where bus_layout_id = v_layout.id
    group by deck, row_no, col_no having count(*) > 1
  ) d;
  if v_n > 0 then v_errors := v_errors || format('%s cell(s) contain more than one seat', v_n); end if;

  -- blank code / missing position
  select count(*) into v_n from public.seats
  where bus_layout_id = v_layout.id and (btrim(seat_code) = '' or row_no is null or col_no is null);
  if v_n > 0 then v_errors := v_errors || format('%s seat(s) have no number or position', v_n); end if;

  -- outside the grid / on an aisle / wrong deck
  if v_rows is not null and v_cols is not null then
    select count(*) into v_n from public.seats
    where bus_layout_id = v_layout.id and (row_no < 1 or row_no > v_rows or col_no < 1 or col_no > v_cols);
    if v_n > 0 then v_errors := v_errors || format('%s seat(s) are outside the layout grid', v_n); end if;
  end if;
  select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and col_no = any (v_aisles);
  if v_n > 0 then v_errors := v_errors || format('%s seat(s) are placed on the aisle', v_n); end if;
  select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and deck > v_layout.deck_count;
  if v_n > 0 then v_errors := v_errors || format('%s seat(s) are on a deck that does not exist', v_n); end if;

  -- capacity consistency
  if v_bookable <> v_bus.total_seats then
    v_errors := v_errors || format('Bookable seats (%s) do not match the bus capacity (%s)', v_bookable, v_bus.total_seats);
  end if;

  -- seating type vs bus type, and berth configuration
  v_seat_type_kind := case
    when v_bus.bus_type like '%semi_sleeper' then 'semi'
    when v_bus.bus_type like '%sleeper' then 'sleeper'
    else 'seater' end;

  if v_seat_type_kind = 'seater' then
    select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and kind <> 'crew' and (seat_type <> 'seater' or berth is not null);
    if v_n > 0 then v_errors := v_errors || format('%s seat(s) are sleeper berths but this is a seater bus', v_n); end if;
  elsif v_seat_type_kind = 'sleeper' then
    select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and kind <> 'crew' and seat_type <> 'sleeper';
    if v_n > 0 then v_errors := v_errors || format('%s seat(s) are not sleeper berths but this is a sleeper bus', v_n); end if;
  end if;

  select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and kind <> 'crew' and seat_type = 'sleeper' and berth is null;
  if v_n > 0 then v_errors := v_errors || format('%s sleeper berth(s) have no upper/lower assignment', v_n); end if;
  select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and seat_type = 'seater' and berth is not null;
  if v_n > 0 then v_errors := v_errors || format('%s seater seat(s) have a berth assigned', v_n); end if;

  -- lower berths live on deck 1, upper berths on deck 2, and every upper has a lower beneath it
  select count(*) into v_n from public.seats
  where bus_layout_id = v_layout.id and ((berth = 'lower' and deck <> 1) or (berth = 'upper' and deck <> 2));
  if v_n > 0 then v_errors := v_errors || format('%s berth(s) are on the wrong deck (lower = deck 1, upper = deck 2)', v_n); end if;

  select count(*) into v_n from public.seats u
  where u.bus_layout_id = v_layout.id and u.berth = 'upper'
    and not exists (
      select 1 from public.seats l
      where l.bus_layout_id = v_layout.id and l.berth = 'lower' and l.row_no = u.row_no and l.col_no = u.col_no
    );
  if v_n > 0 then v_errors := v_errors || format('%s upper berth(s) have no lower berth in the same position', v_n); end if;

  if v_layout.deck_count = 2 and not exists (
       select 1 from public.seats where bus_layout_id = v_layout.id and deck = 2) then
    v_errors := array_append(v_errors, 'Two decks are configured but the upper deck has no seats');
  end if;

  if not exists (select 1 from public.seats where bus_layout_id = v_layout.id and kind = 'crew') then
    v_warnings := array_append(v_warnings, 'No driver / crew position is marked');
  end if;

  return jsonb_build_object(
    'valid', coalesce(array_length(v_errors, 1), 0) = 0,
    'errors', to_jsonb(v_errors),
    'warnings', to_jsonb(v_warnings),
    'stats', jsonb_build_object(
      'total', v_total, 'bookable', v_bookable, 'capacity', v_bus.total_seats,
      'layout_id', v_layout.id, 'version', v_layout.version
    )
  );
end;
$$;

revoke execute on function public.validate_bus_layout(uuid) from public, anon;
grant execute on function public.validate_bus_layout(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- save_bus_layout: atomically replaces a bus's layout.
--  * operator staff of an approved operator, bus draft/changes_requested/legacy
--  * if trips already reference the active layout's seats, the old layout is
--    kept (inactive) and a new version is created, so existing trips and
--    bookings stay intact; otherwise the layout is rewritten in place.
-- Returns validate_bus_layout(); saving an invalid draft is allowed so work
-- can be saved and continued later, but submission/approval/activation
-- re-run the validator and refuse invalid layouts.
-- ---------------------------------------------------------------------
create or replace function public.save_bus_layout(
  p_bus_id uuid,
  p_layout jsonb,
  p_seats jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_old public.bus_layouts;
  v_layout_id uuid;
  v_decks integer := coalesce((p_layout ->> 'decks')::integer, 1);
  v_in_use boolean := false;
  v_version integer := 1;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then
    raise exception 'Bus not found';
  end if;
  if not private.is_operator_staff(v_bus.operator_id) then
    raise exception 'Not authorized';
  end if;
  if not private.operator_is_approved(v_bus.operator_id) then
    raise exception 'The operator account is not approved';
  end if;
  if not (v_bus.lifecycle_status in ('draft', 'changes_requested') or v_bus.is_legacy) then
    raise exception 'The seat layout is locked while the bus is %', v_bus.lifecycle_status;
  end if;
  if v_decks not in (1, 2) then
    raise exception 'Decks must be 1 or 2';
  end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) > 200 then
    raise exception 'Seats must be an array of at most 200 entries';
  end if;

  select * into v_old from public.bus_layouts where bus_id = p_bus_id and is_active order by version desc limit 1;

  if v_old.id is not null then
    select exists (
      select 1 from public.trip_seats ts join public.seats s on s.id = ts.seat_id
      where s.bus_layout_id = v_old.id
    ) into v_in_use;
    v_version := v_old.version;
  end if;

  if v_old.id is not null and not v_in_use then
    delete from public.seats where bus_layout_id = v_old.id;
    update public.bus_layouts set layout_json = p_layout, deck_count = v_decks where id = v_old.id;
    v_layout_id := v_old.id;
  else
    if v_old.id is not null then
      update public.bus_layouts set is_active = false where id = v_old.id;
      v_version := v_old.version + 1;
    end if;
    insert into public.bus_layouts (bus_id, name, deck_count, layout_json, version, is_active)
    values (p_bus_id, 'Layout v' || v_version, v_decks, p_layout, v_version, true)
    returning id into v_layout_id;
  end if;

  insert into public.seats (bus_layout_id, seat_code, deck, row_no, col_no, seat_type, berth, kind)
  select
    v_layout_id,
    btrim(e ->> 'seat_code'),
    (e ->> 'deck')::smallint,
    (e ->> 'row_no')::smallint,
    (e ->> 'col_no')::smallint,
    (e ->> 'seat_type')::public.seat_type,
    nullif(e ->> 'berth', ''),
    coalesce(nullif(e ->> 'kind', ''), 'bookable')
  from jsonb_array_elements(p_seats) e;

  perform private.write_audit(
    'bus.layout_saved', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'layout_id', v_layout_id, 'version', v_version,
                       'seats', jsonb_array_length(p_seats), 'versioned', v_in_use)
  );
  return public.validate_bus_layout(p_bus_id);
end;
$$;

revoke execute on function public.save_bus_layout(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.save_bus_layout(uuid, jsonb, jsonb) to authenticated;

-- Convenience: set the declared capacity from the layout's bookable seats.
create or replace function public.sync_bus_capacity_from_layout(p_bus_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_n integer;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null or not private.is_operator_staff(v_bus.operator_id) then
    raise exception 'Not authorized';
  end if;
  if not (v_bus.lifecycle_status in ('draft', 'changes_requested') or v_bus.is_legacy) then
    raise exception 'Capacity is locked while the bus is %', v_bus.lifecycle_status;
  end if;
  select count(*) into v_n
  from public.seats s join public.bus_layouts bl on bl.id = s.bus_layout_id
  where bl.bus_id = p_bus_id and bl.is_active and s.kind = 'bookable';
  if v_n < 1 or v_n > 80 then
    raise exception 'The layout must have between 1 and 80 bookable seats';
  end if;
  update public.buses set total_seats = v_n where id = p_bus_id;
  return v_n;
end;
$$;

revoke execute on function public.sync_bus_capacity_from_layout(uuid) from public, anon;
grant execute on function public.sync_bus_capacity_from_layout(uuid) to authenticated;
