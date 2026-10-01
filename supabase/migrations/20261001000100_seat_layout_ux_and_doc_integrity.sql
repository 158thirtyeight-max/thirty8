-- =========================================================================
-- Seat layout UX + vehicle document integrity
--
-- 1. seats.role: operator-facing position type that refines `kind`
--      reserved -> ladies | accessible      crew -> driver | conductor
--    `kind` stays the single source of truth for "can a customer book it":
--    only kind = 'bookable' seats ever become trip_seats (generate_trip_seats()).
-- 2. save_bus_layout(): stores role; seats without a number yet (manual
--    numbering in progress) get a TMP- placeholder so a draft can be saved.
-- 3. validate_bus_layout(): capacity is the declared total of physical
--    positions (bookable + reserved + crew + other). A mismatch is a warning;
--    more bookable seats than the declared capacity is an error. Seats still
--    holding a TMP- placeholder block submission.
-- 4. bus_documents: file path / document type are checked against the bus so
--    a record can never point at another operator's or bus's file.
-- =========================================================================

alter table public.seats
  add column role text check (role in ('ladies', 'accessible', 'driver', 'conductor'));

alter table public.seats
  add constraint seats_role_matches_kind check (
    role is null
    or (role in ('ladies', 'accessible') and kind = 'reserved')
    or (role in ('driver', 'conductor') and kind = 'crew')
  );

-- Existing driver positions were written by the editor as crew seats coded DRV*.
update public.seats set role = 'driver' where kind = 'crew' and role is null and seat_code like 'DRV%';

-- ---------------------------------------------------------------------
-- save_bus_layout: same behaviour as before, plus role and TMP- numbers.
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

  insert into public.seats (bus_layout_id, seat_code, deck, row_no, col_no, seat_type, berth, kind, category, role)
  select
    v_layout_id,
    coalesce(
      nullif(btrim(e ->> 'seat_code'), ''),
      'TMP-' || (e ->> 'deck') || '-' || (e ->> 'row_no') || '-' || (e ->> 'col_no')
    ),
    (e ->> 'deck')::smallint,
    (e ->> 'row_no')::smallint,
    (e ->> 'col_no')::smallint,
    (e ->> 'seat_type')::public.seat_type,
    nullif(e ->> 'berth', ''),
    coalesce(nullif(e ->> 'kind', ''), 'bookable'),
    nullif(e ->> 'category', ''),
    nullif(e ->> 'role', '')
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

-- ---------------------------------------------------------------------
-- validate_bus_layout: capacity semantics + unnumbered seats + role counts.
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
  v_reserved integer;
  v_crew integer;
  v_unavailable integer;
  v_configured integer;
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

  select count(*),
         count(*) filter (where kind = 'bookable'),
         count(*) filter (where kind = 'reserved'),
         count(*) filter (where kind = 'crew'),
         count(*) filter (where kind = 'unavailable')
    into v_total, v_bookable, v_reserved, v_crew, v_unavailable
  from public.seats where bus_layout_id = v_layout.id;
  -- Physical positions that count towards the declared capacity.
  v_configured := v_total - v_unavailable;

  if v_total = 0 then
    v_errors := array_append(v_errors, 'The layout has no seats');
  end if;
  if v_bookable = 0 then
    v_errors := array_append(v_errors, 'At least one seat must be available for booking');
  end if;

  select count(*) into v_n from (
    select upper(btrim(seat_code)) from public.seats where bus_layout_id = v_layout.id
    group by 1 having count(*) > 1
  ) d;
  if v_n > 0 then v_errors := v_errors || format('%s duplicate seat number(s)', v_n); end if;

  -- passenger-facing seats still waiting for a number (manual numbering)
  select count(*) into v_n from public.seats
  where bus_layout_id = v_layout.id and kind in ('bookable', 'reserved') and seat_code like 'TMP-%';
  if v_n > 0 then v_errors := v_errors || format('%s seat(s) have not been numbered yet', v_n); end if;

  select count(*) into v_n from (
    select 1 from public.seats where bus_layout_id = v_layout.id
    group by deck, row_no, col_no having count(*) > 1
  ) d;
  if v_n > 0 then v_errors := v_errors || format('%s cell(s) contain more than one seat', v_n); end if;

  select count(*) into v_n from public.seats
  where bus_layout_id = v_layout.id and (btrim(seat_code) = '' or row_no is null or col_no is null);
  if v_n > 0 then v_errors := v_errors || format('%s seat(s) have no number or position', v_n); end if;

  if v_rows is not null and v_cols is not null then
    select count(*) into v_n from public.seats
    where bus_layout_id = v_layout.id and (row_no < 1 or row_no > v_rows or col_no < 1 or col_no > v_cols);
    if v_n > 0 then v_errors := v_errors || format('%s seat(s) are outside the layout grid', v_n); end if;
  end if;
  select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and col_no = any (v_aisles);
  if v_n > 0 then v_errors := v_errors || format('%s seat(s) are placed on the aisle', v_n); end if;
  select count(*) into v_n from public.seats where bus_layout_id = v_layout.id and deck > v_layout.deck_count;
  if v_n > 0 then v_errors := v_errors || format('%s seat(s) are on a deck that does not exist', v_n); end if;

  -- capacity: never sell more seats than declared; a different physical total is a warning
  if v_bookable > v_bus.total_seats then
    v_errors := v_errors || format('Bookable seats (%s) exceed the bus capacity (%s)', v_bookable, v_bus.total_seats);
  elsif v_configured <> v_bus.total_seats then
    v_warnings := v_warnings || format('The layout has %s positions but the declared bus capacity is %s', v_configured, v_bus.total_seats);
  end if;

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

  if not exists (select 1 from public.seats where bus_layout_id = v_layout.id and kind = 'crew' and (role is null or role = 'driver')) then
    v_warnings := array_append(v_warnings, 'No driver position is marked');
  end if;

  return jsonb_build_object(
    'valid', coalesce(array_length(v_errors, 1), 0) = 0,
    'errors', to_jsonb(v_errors),
    'warnings', to_jsonb(v_warnings),
    'stats', jsonb_build_object(
      'total', v_total, 'bookable', v_bookable, 'reserved', v_reserved, 'crew', v_crew,
      'unavailable', v_unavailable, 'configured', v_configured, 'capacity', v_bus.total_seats,
      'layout_id', v_layout.id, 'version', v_layout.version
    )
  );
end;
$$;

revoke execute on function public.validate_bus_layout(uuid) from public, anon;
grant execute on function public.validate_bus_layout(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Defence in depth: whatever the layout says, only kind = 'bookable' seats
-- may ever be inventory. This blocks a trip_seat from being created for a
-- reserved / crew / unavailable position by any code path.
-- ---------------------------------------------------------------------
create or replace function private.trip_seat_must_be_bookable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.seats s where s.id = new.seat_id and s.kind = 'bookable') then
    raise exception 'Only passenger seats can be offered for booking';
  end if;
  return new;
end;
$$;

create trigger trip_seat_must_be_bookable
  before insert on public.trip_seats
  for each row execute function private.trip_seat_must_be_bookable();

-- ---------------------------------------------------------------------
-- bus_documents integrity: the stored file must live under
--   <operator_id>/<bus_id>/<doc_type>_<epoch>.<ext>
-- for the bus the row belongs to, and doc_type must be a configured bus
-- document type. Older insurance rows migrated from operator_insurance use
-- their own bucket/path and are exempt.
-- ---------------------------------------------------------------------
create or replace function private.validate_bus_document_file()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_operator uuid;
begin
  if not exists (
    select 1 from public.document_requirements dr where dr.scope = 'bus' and dr.doc_type = new.doc_type
  ) then
    raise exception 'Unknown vehicle document type %', new.doc_type;
  end if;

  if new.bucket = 'bus-documents'
     and (tg_op = 'INSERT' or new.file_path is distinct from old.file_path) then
    select operator_id into v_operator from public.buses where id = new.bus_id;
    if split_part(new.file_path, '/', 1) is distinct from v_operator::text
       or split_part(new.file_path, '/', 2) is distinct from new.bus_id::text
       or split_part(new.file_path, '/', 3) not like new.doc_type || '\_%' then
      raise exception 'The document file does not belong to this bus';
    end if;
  end if;
  return new;
end;
$$;

create trigger validate_bus_document_file
  before insert or update on public.bus_documents
  for each row execute function private.validate_bus_document_file();
