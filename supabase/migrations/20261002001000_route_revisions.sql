-- =========================================================================
-- Route revisions, linked round-trip journeys and admin approval.
--
-- The live route stays where it always was: bus_routes + boarding_points +
-- dropping_points + bus_services. The customer app reads only those. This
-- migration adds a revision layer on top: operators edit DRAFT revisions,
-- submit them, an admin approves, and only then is the revision
-- materialised into the live tables (private.materialize_revision).
--
-- A round trip is two live routes (direction 'outbound' / 'return'), each
-- with its own bus_services row, linked through bus_routes.linked_route_id.
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. Live-table changes
-- ---------------------------------------------------------------------
alter table public.bus_routes
  add column direction text not null default 'outbound' check (direction in ('outbound', 'return')),
  add column linked_route_id uuid references public.bus_routes (id) on delete set null;

alter table public.bus_services
  add column direction text not null default 'outbound' check (direction in ('outbound', 'return'));

drop index public.bus_routes_one_per_bus_uniq;
create unique index bus_routes_one_per_bus_direction_uniq
  on public.bus_routes (bus_id, direction) where bus_id is not null;
create index bus_routes_linked_route_idx on public.bus_routes (linked_route_id) where linked_route_id is not null;
create index bus_services_bus_direction_idx on public.bus_services (bus_id, direction);

-- The primary service is the OUTBOUND one (the return service is created later and
-- must never be picked by the fare / schedule / validation code that uses this).
create or replace function private.bus_primary_service(p_bus_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.bus_services
  where bus_id = p_bus_id and direction = 'outbound'
  order by created_at, id limit 1;
$$;

-- ---------------------------------------------------------------------
-- 2. Revision tables
-- ---------------------------------------------------------------------
create table public.route_revisions (
  id uuid primary key default gen_random_uuid(),
  bus_id uuid not null references public.buses (id) on delete cascade,
  operator_id uuid not null references public.operators (id),
  revision_no integer not null check (revision_no > 0),
  status text not null default 'draft'
    check (status in ('draft', 'pending_approval', 'approved', 'rejected', 'superseded', 'withdrawn')),
  trip_type text not null default 'one_way' check (trip_type in ('one_way', 'round_trip')),
  name text,
  change_reason text,
  base_revision_id uuid references public.route_revisions (id) on delete set null,
  created_by uuid references public.profiles (id),
  submitted_by uuid references public.profiles (id),
  submitted_at timestamptz,
  reviewed_by uuid references public.profiles (id),
  reviewed_at timestamptz,
  rejection_reason text,
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (bus_id, revision_no),
  check (status <> 'rejected' or nullif(btrim(rejection_reason), '') is not null)
);
-- At most one open (draft or pending) revision per bus.
create unique index route_revisions_one_open_per_bus
  on public.route_revisions (bus_id) where status in ('draft', 'pending_approval');
create index route_revisions_operator_idx on public.route_revisions (operator_id, status);
create index route_revisions_pending_idx on public.route_revisions (submitted_at) where status = 'pending_approval';
create index route_revisions_base_idx on public.route_revisions (base_revision_id) where base_revision_id is not null;

alter table public.buses
  add column active_route_revision_id uuid references public.route_revisions (id) on delete set null;

create table public.route_revision_journeys (
  id uuid primary key default gen_random_uuid(),
  revision_id uuid not null references public.route_revisions (id) on delete cascade,
  direction text not null check (direction in ('outbound', 'return')),
  source_city_id uuid references public.locations (id),
  destination_city_id uuid references public.locations (id),
  departure_time time,
  est_duration_min integer check (est_duration_min is null or est_duration_min > 0),
  operating_days smallint[] not null default '{}',
  -- 0 = the return runs the same day, 1 = the next day, ... (used when generating a reverse route)
  departure_day_offset smallint not null default 0 check (departure_day_offset between 0 and 7),
  reverse_generated boolean not null default false,
  unique (revision_id, direction),
  check (operating_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[])
);

create table public.route_revision_stops (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.route_revision_journeys (id) on delete cascade,
  sequence_no integer not null check (sequence_no > 0),
  city_id uuid not null references public.locations (id),
  arrival_offset_min integer check (arrival_offset_min is null or arrival_offset_min >= 0),
  departure_offset_min integer check (departure_offset_min is null or departure_offset_min >= 0),
  is_boarding boolean not null default false,
  is_dropping boolean not null default false,
  address text,
  latitude numeric,
  longitude numeric,
  unique (journey_id, sequence_no),
  unique (journey_id, city_id)
);
create index route_revision_stops_city_idx on public.route_revision_stops (city_id);

alter table public.bus_routes
  add column revision_journey_id uuid references public.route_revision_journeys (id) on delete set null;

-- Approval history.
create table public.route_revision_events (
  id uuid primary key default gen_random_uuid(),
  revision_id uuid not null references public.route_revisions (id) on delete cascade,
  event text not null check (event in ('created', 'submitted', 'applied_setup', 'approved', 'rejected', 'withdrawn', 'superseded')),
  actor_id uuid references public.profiles (id),
  reason text,
  created_at timestamptz not null default now()
);
create index route_revision_events_revision_idx on public.route_revision_events (revision_id, created_at);

-- Bookings affected by an activated revision. Bookings themselves are never changed.
create table public.route_change_flags (
  id uuid primary key default gen_random_uuid(),
  revision_id uuid not null references public.route_revisions (id) on delete cascade,
  booking_item_id uuid not null references public.booking_items (id) on delete cascade,
  reason text not null check (reason in ('point_removed', 'order_changed', 'route_removed')),
  status text not null default 'open' check (status in ('open', 'notified', 'resolved')),
  created_at timestamptz not null default now(),
  unique (revision_id, booking_item_id)
);
create index route_change_flags_item_idx on public.route_change_flags (booking_item_id);
create index route_change_flags_open_idx on public.route_change_flags (status) where status = 'open';

-- ---------------------------------------------------------------------
-- 3. Authorization helpers
-- ---------------------------------------------------------------------
create or replace function private.can_manage_routes(p_operator_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid())
      and ur.operator_id = p_operator_id
      and ur.role in ('operator_admin', 'operator_staff')
  );
$$;

create or replace function private.revision_operator_id(p_revision_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select operator_id from public.route_revisions where id = p_revision_id;
$$;

create or replace function private.journey_operator_id(p_journey_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select r.operator_id from public.route_revision_journeys j
  join public.route_revisions r on r.id = j.revision_id where j.id = p_journey_id;
$$;

revoke execute on function private.can_manage_routes(uuid), private.revision_operator_id(uuid),
  private.journey_operator_id(uuid), private.bus_primary_service(uuid) from public, anon;
grant execute on function private.can_manage_routes(uuid), private.revision_operator_id(uuid),
  private.journey_operator_id(uuid), private.bus_primary_service(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. RLS: read-only for operators of the bus and admins; writes only via RPCs.
--    Customers (and anon) have no access to any revision table.
-- ---------------------------------------------------------------------
alter table public.route_revisions enable row level security;
alter table public.route_revision_journeys enable row level security;
alter table public.route_revision_stops enable row level security;
alter table public.route_revision_events enable row level security;
alter table public.route_change_flags enable row level security;

revoke all on public.route_revisions, public.route_revision_journeys, public.route_revision_stops,
  public.route_revision_events, public.route_change_flags from anon, authenticated;
grant select on public.route_revisions, public.route_revision_journeys, public.route_revision_stops,
  public.route_revision_events, public.route_change_flags to authenticated;

create policy route_revisions_select on public.route_revisions for select to authenticated
  using (private.is_platform_admin() or private.is_operator_staff(operator_id));
create policy route_revision_journeys_select on public.route_revision_journeys for select to authenticated
  using (private.is_platform_admin() or private.is_operator_staff(private.revision_operator_id(revision_id)));
create policy route_revision_stops_select on public.route_revision_stops for select to authenticated
  using (private.is_platform_admin() or private.is_operator_staff(private.journey_operator_id(journey_id)));
create policy route_revision_events_select on public.route_revision_events for select to authenticated
  using (private.is_platform_admin() or private.is_operator_staff(private.revision_operator_id(revision_id)));
create policy route_change_flags_select on public.route_change_flags for select to authenticated
  using (private.is_platform_admin() or private.is_operator_staff(private.revision_operator_id(revision_id)));

-- ---------------------------------------------------------------------
-- 5. Immutability: a revision's content cannot change once it has left 'draft'.
--    Status / review columns may still move through the workflow RPCs.
-- ---------------------------------------------------------------------
create or replace function private.guard_revision_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'draft' and (
       new.bus_id is distinct from old.bus_id or new.operator_id is distinct from old.operator_id
       or new.revision_no is distinct from old.revision_no or new.trip_type is distinct from old.trip_type
       or new.name is distinct from old.name or new.change_reason is distinct from old.change_reason
       or new.base_revision_id is distinct from old.base_revision_id or new.created_by is distinct from old.created_by
       or new.submitted_by is distinct from old.submitted_by or new.submitted_at is distinct from old.submitted_at)
  then
    raise exception 'A submitted route revision cannot be edited; create a new revision instead';
  end if;
  if old.status <> 'draft' and old.status <> 'pending_approval' and new.status is distinct from old.status
     and not (old.status = 'approved' and new.status = 'superseded') then
    raise exception 'Route revision is already %', old.status;
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger route_revisions_immutable before update on public.route_revisions
  for each row execute function private.guard_revision_immutable();

create or replace function private.guard_revision_children_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_rev uuid;
  v_status text;
begin
  -- cascade deletes (a bus or revision being removed) are not edits
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if;
  if tg_table_name = 'route_revision_stops' then
    select j.revision_id into v_rev from public.route_revision_journeys j
    where j.id = case when tg_op = 'DELETE' then old.journey_id else new.journey_id end;
  else
    v_rev := case when tg_op = 'DELETE' then old.revision_id else new.revision_id end;
  end if;
  select status into v_status from public.route_revisions where id = v_rev;
  if v_status is not null and v_status <> 'draft' then
    raise exception 'A submitted route revision cannot be edited; create a new revision instead';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
create trigger route_revision_journeys_immutable before insert or update or delete on public.route_revision_journeys
  for each row execute function private.guard_revision_children_immutable();
create trigger route_revision_stops_immutable before insert or update or delete on public.route_revision_stops
  for each row execute function private.guard_revision_children_immutable();

-- ---------------------------------------------------------------------
-- 6. Shared validation. Returns the list of problems (empty = valid).
--    p_route_id is the live route of the same direction (or null); a location
--    already used on it stays valid even if it was disabled since.
-- ---------------------------------------------------------------------
create or replace function private.validate_route_journey(
  p_route_id uuid, p_source uuid, p_dest uuid, p_departure time, p_duration integer,
  p_days smallint[], p_stops jsonb, p_strict boolean default true
)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  e text[] := '{}';
  n integer;
  idx integer := 0;
  stop jsonb;
  city uuid;
  loc public.locations;
  used boolean;
  seen uuid[] := '{}';
  is_b boolean;
  is_d boolean;
  arr integer;
  dep integer;
  last_end integer := null;
  missing integer := 0;
begin
  if p_source is null or p_dest is null or p_source = p_dest then
    e := e || 'Origin and destination must be two different cities';
  end if;
  if p_departure is null then e := e || 'Departure time is required'; end if;
  if p_duration is null or p_duration < 1 then e := e || 'Estimated journey duration is required'; end if;
  if p_days is null or coalesce(array_length(p_days, 1), 0) = 0 then e := e || 'Select at least one operating day'; end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then return e || 'Stops must be an array'; end if;
  n := jsonb_array_length(p_stops);
  if n < 2 or n > 30 then return e || 'A route needs between 2 and 30 stops'; end if;
  if not coalesce((p_stops -> 0 ->> 'is_boarding')::boolean, false) then e := e || 'The origin must be a boarding point'; end if;
  if not coalesce((p_stops -> (n - 1) ->> 'is_dropping')::boolean, false) then e := e || 'The destination must be a dropping point'; end if;

  for stop in select * from jsonb_array_elements(p_stops) loop
    idx := idx + 1;
    city := nullif(stop ->> 'city_id', '')::uuid;
    if city is null then e := e || format('Stop %s needs a location', idx); continue; end if;
    select * into loc from public.locations where id = city;
    if loc.id is null then e := e || format('Stop %s: location not found', idx); continue; end if;
    used := p_route_id is not null and (
      exists (select 1 from public.boarding_points bp where bp.route_id = p_route_id and bp.city_id = city)
      or exists (select 1 from public.dropping_points dp where dp.route_id = p_route_id and dp.city_id = city));
    is_b := coalesce((stop ->> 'is_boarding')::boolean, false);
    is_d := coalesce((stop ->> 'is_dropping')::boolean, false);
    if not loc.is_active and not used then e := e || format('Stop %s: %s is disabled', idx, loc.name); end if;
    if (idx = 1 or idx = n) and not loc.is_main_route_enabled and not used then
      e := e || format('Stop %s: %s is not a main route location', idx, loc.name);
    end if;
    if idx = 1 and city is distinct from p_source then e := e || 'The first stop must be the origin location'; end if;
    if idx = n and city is distinct from p_dest then e := e || 'The last stop must be the destination location'; end if;
    if city = any (seen) then e := e || format('A location can appear only once on a route (stop %s)', idx); end if;
    seen := seen || city;
    if not is_b and not is_d then e := e || format('Stop %s: choose pickup, drop or both', idx); end if;
    if is_b and not loc.is_pickup_enabled and not used then e := e || format('Stop %s: pickup is not enabled at %s', idx, loc.name); end if;
    if is_d and not loc.is_drop_enabled and not used then e := e || format('Stop %s: drop is not enabled at %s', idx, loc.name); end if;

    if p_strict then
      arr := nullif(stop ->> 'arrival_offset_min', '')::integer;
      dep := nullif(stop ->> 'departure_offset_min', '')::integer;
      if (is_b and dep is null) or (is_d and arr is null) then missing := missing + 1; end if;
      if arr is not null and last_end is not null and arr < last_end then
        e := e || format('Stop %s is reached before the previous stop is left', idx);
      end if;
      if arr is not null and dep is not null and dep < arr then
        e := e || format('Stop %s departs before it arrives', idx);
      end if;
      last_end := coalesce(dep, arr, last_end);
    end if;
  end loop;

  if p_strict then
    if missing > 0 then e := e || 'Arrival / departure times are missing for some stops'; end if;
    if p_duration is not null and last_end is not null and last_end > p_duration then
      e := e || 'Stop times run past the estimated journey duration';
    end if;
  end if;
  return e;
end;
$$;

-- Stops of a revision journey as the jsonb shape the validator / materialiser use.
create or replace function private.journey_stops_json(p_journey_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'sequence_no', s.sequence_no, 'city_id', s.city_id, 'name', l.name,
    'is_boarding', s.is_boarding, 'is_dropping', s.is_dropping,
    'arrival_offset_min', s.arrival_offset_min, 'departure_offset_min', s.departure_offset_min,
    'address', s.address, 'latitude', s.latitude, 'longitude', s.longitude
  ) order by s.sequence_no), '[]'::jsonb)
  from public.route_revision_stops s join public.locations l on l.id = s.city_id
  where s.journey_id = p_journey_id;
$$;

-- Stops of a LIVE route (boarding + dropping rows merged per sequence number).
create or replace function private.live_route_stops(p_route_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'sequence_no', u.seq, 'city_id', u.city, 'name', u.nm, 'is_boarding', u.b, 'is_dropping', u.d,
    'arrival_offset_min', u.arr, 'departure_offset_min', u.dep, 'address', u.addr,
    'latitude', u.lat, 'longitude', u.lng
  ) order by u.seq), '[]'::jsonb)
  from (
    select seq, (array_agg(city_id))[1] as city, max(name) as nm,
           bool_or(b) as b, bool_or(d) as d, min(arr) as arr, max(dep) as dep,
           max(address) as addr, max(latitude) as lat, max(longitude) as lng
    from (
      select sequence_no as seq, city_id, name, true as b, false as d, arrival_offset_min as arr,
             departure_offset_min as dep, address, latitude, longitude
      from public.boarding_points where route_id = p_route_id and is_active
      union all
      select sequence_no, city_id, name, false, true, arrival_offset_min, departure_offset_min,
             address, latitude, longitude
      from public.dropping_points where route_id = p_route_id and is_active
    ) x group by seq
  ) u;
$$;

create or replace function private.insert_journey_stops(p_journey_id uuid, p_stops jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then return; end if;
  if jsonb_array_length(p_stops) > 30 then raise exception 'A route needs between 2 and 30 stops'; end if;
  insert into public.route_revision_stops (
    journey_id, sequence_no, city_id, arrival_offset_min, departure_offset_min,
    is_boarding, is_dropping, address, latitude, longitude)
  select p_journey_id, e.ord::integer, (e.v ->> 'city_id')::uuid,
         nullif(e.v ->> 'arrival_offset_min', '')::integer, nullif(e.v ->> 'departure_offset_min', '')::integer,
         coalesce((e.v ->> 'is_boarding')::boolean, false), coalesce((e.v ->> 'is_dropping')::boolean, false),
         nullif(e.v ->> 'address', ''), nullif(e.v ->> 'latitude', '')::numeric, nullif(e.v ->> 'longitude', '')::numeric
  from jsonb_array_elements(p_stops) with ordinality as e(v, ord);
end;
$$;

-- Validation of a whole revision. {valid, errors:[{direction, message}]}
create or replace function private.validate_revision(p_revision_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_out public.route_revision_journeys;
  v_ret public.route_revision_journeys;
  j public.route_revision_journeys;
  errs jsonb := '[]'::jsonb;
  m text;
  v_route uuid;
begin
  select * into v_rev from public.route_revisions where id = p_revision_id;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  select * into v_out from public.route_revision_journeys where revision_id = p_revision_id and direction = 'outbound';
  select * into v_ret from public.route_revision_journeys where revision_id = p_revision_id and direction = 'return';

  if v_out.id is null then
    errs := errs || jsonb_build_object('direction', 'outbound', 'message', 'The outbound journey is not configured');
  end if;
  if v_rev.trip_type = 'one_way' and v_ret.id is not null then
    errs := errs || jsonb_build_object('direction', 'return', 'message', 'A one-way route cannot have a return journey');
  end if;
  if v_rev.trip_type = 'round_trip' and v_ret.id is null then
    errs := errs || jsonb_build_object('direction', 'return', 'message', 'A round trip needs a return journey');
  end if;

  for j in select * from public.route_revision_journeys where revision_id = p_revision_id order by direction desc loop
    select id into v_route from public.bus_routes where bus_id = v_rev.bus_id and direction = j.direction;
    foreach m in array private.validate_route_journey(
      v_route, j.source_city_id, j.destination_city_id, j.departure_time, j.est_duration_min,
      j.operating_days, private.journey_stops_json(j.id), true)
    loop
      errs := errs || jsonb_build_object('direction', j.direction, 'message', m);
    end loop;
  end loop;

  if v_out.id is not null and v_ret.id is not null
     and (v_ret.source_city_id is distinct from v_out.destination_city_id
          or v_ret.destination_city_id is distinct from v_out.source_city_id) then
    errs := errs || jsonb_build_object('direction', 'return',
      'message', 'The return journey must start where the outbound ends and end where it starts');
  end if;

  return jsonb_build_object('valid', jsonb_array_length(errs) = 0, 'errors', errs);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Writing one journey into the live tables. Shared by save_bus_route
--    (draft buses, outbound only) and materialize_revision.
--    Points are reused by location (so booking references survive), parked and
--    deactivated when removed, never deleted. Returns the live route id.
-- ---------------------------------------------------------------------
create or replace function private.apply_route_journey(
  p_bus_id uuid, p_direction text, p_source uuid, p_dest uuid, p_distance numeric,
  p_departure time, p_duration integer, p_days smallint[], p_stops jsonb,
  p_linked_route uuid, p_journey_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc public.bus_services;
  v_primary public.bus_services;
  v_route_id uuid;
  v_errs text[];
  v_stop jsonb;
  v_i integer := 0;
  v_id uuid;
  v_city uuid;
  v_locname text;
  v_min_b integer;
  v_min_d integer;
  v_src_name text;
  v_dst_name text;
  v_new_svc uuid;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;

  if p_direction = 'outbound' then
    select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);
  else
    select * into v_svc from public.bus_services where bus_id = p_bus_id and direction = 'return'
      order by created_at, id limit 1;
  end if;
  select * into v_primary from public.bus_services where id = private.bus_primary_service(p_bus_id);

  if v_svc.id is not null then
    v_route_id := v_svc.route_id;
  else
    select id into v_route_id from public.bus_routes where bus_id = p_bus_id and direction = p_direction;
  end if;

  v_errs := private.validate_route_journey(v_route_id, p_source, p_dest, p_departure, p_duration, p_days, p_stops, false);
  if coalesce(array_length(v_errs, 1), 0) > 0 then raise exception '%', v_errs[1]; end if;

  if v_route_id is null then
    insert into public.bus_routes (operator_id, bus_id, source_city_id, destination_city_id, distance_km,
                                   direction, linked_route_id, revision_journey_id)
    values (v_bus.operator_id, p_bus_id, p_source, p_dest, p_distance, p_direction, p_linked_route, p_journey_id)
    returning id into v_route_id;
  else
    update public.bus_routes
    set source_city_id = p_source, destination_city_id = p_dest, distance_km = p_distance,
        active = true, linked_route_id = coalesce(p_linked_route, linked_route_id),
        revision_journey_id = coalesce(p_journey_id, revision_journey_id)
    where id = v_route_id;
  end if;

  -- Park existing active rows out of the way of the unique (route, sequence) key.
  select least(coalesce(min(sequence_no), 0), 0) into v_min_b from public.boarding_points where route_id = v_route_id;
  select least(coalesce(min(sequence_no), 0), 0) into v_min_d from public.dropping_points where route_id = v_route_id;
  update public.boarding_points set sequence_no = sequence_no + 1000000 where route_id = v_route_id and sequence_no > 0;
  update public.dropping_points set sequence_no = sequence_no + 1000000 where route_id = v_route_id and sequence_no > 0;

  for v_stop in select * from jsonb_array_elements(p_stops) loop
    v_i := v_i + 1;
    v_city := (v_stop ->> 'city_id')::uuid;
    select name into v_locname from public.locations where id = v_city;

    if coalesce((v_stop ->> 'is_boarding')::boolean, false) then
      v_id := nullif(v_stop ->> 'boarding_point_id', '')::uuid;
      if v_id is null or not exists (select 1 from public.boarding_points where id = v_id and route_id = v_route_id) then
        select id into v_id from public.boarding_points
        where route_id = v_route_id and city_id = v_city order by is_active desc, sequence_no limit 1;
      end if;
      if v_id is not null then
        update public.boarding_points set
          name = v_locname, address = nullif(v_stop ->> 'address', ''),
          latitude = nullif(v_stop ->> 'latitude', '')::numeric, longitude = nullif(v_stop ->> 'longitude', '')::numeric,
          city_id = v_city,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.boarding_points (route_id, name, address, latitude, longitude, city_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, v_locname, nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric, v_city,
                nullif(v_stop ->> 'arrival_offset_min', '')::integer,
                nullif(v_stop ->> 'departure_offset_min', '')::integer, v_i);
      end if;
    end if;

    if coalesce((v_stop ->> 'is_dropping')::boolean, false) then
      v_id := nullif(v_stop ->> 'dropping_point_id', '')::uuid;
      if v_id is null or not exists (select 1 from public.dropping_points where id = v_id and route_id = v_route_id) then
        select id into v_id from public.dropping_points
        where route_id = v_route_id and city_id = v_city order by is_active desc, sequence_no limit 1;
      end if;
      if v_id is not null then
        update public.dropping_points set
          name = v_locname, address = nullif(v_stop ->> 'address', ''),
          latitude = nullif(v_stop ->> 'latitude', '')::numeric, longitude = nullif(v_stop ->> 'longitude', '')::numeric,
          city_id = v_city,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.dropping_points (route_id, name, address, latitude, longitude, city_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, v_locname, nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric, v_city,
                nullif(v_stop ->> 'arrival_offset_min', '')::integer,
                nullif(v_stop ->> 'departure_offset_min', '')::integer, v_i);
      end if;
    end if;
  end loop;

  -- Anything still parked was removed: deactivate with unique negative sequence numbers.
  update public.boarding_points bp
  set is_active = false, sequence_no = v_min_b - x.rn
  from (select id, row_number() over (order by id) as rn from public.boarding_points
        where route_id = v_route_id and sequence_no >= 1000000) x
  where bp.id = x.id;
  update public.dropping_points dp
  set is_active = false, sequence_no = v_min_d - x.rn
  from (select id, row_number() over (order by id) as rn from public.dropping_points
        where route_id = v_route_id and sequence_no >= 1000000) x
  where dp.id = x.id;

  select name into v_src_name from public.locations where id = p_source;
  select name into v_dst_name from public.locations where id = p_dest;

  if v_svc.id is not null then
    update public.bus_services
    set service_source_city_id = p_source, service_dest_city_id = p_dest,
        default_departure_time = p_departure, default_arrival_offset_minutes = p_duration,
        est_duration_min = p_duration, operating_days = p_days,
        status = case when status = 'retired' then coalesce(v_primary.status, 'paused') else status end
    where id = v_svc.id;
  elsif p_direction = 'outbound' then
    insert into public.bus_services (
      operator_id, route_id, bus_id, service_name, service_source_city_id, service_dest_city_id,
      default_departure_time, default_arrival_offset_minutes, est_duration_min, operating_days, status, direction
    ) values (
      v_bus.operator_id, v_route_id, p_bus_id,
      coalesce(v_bus.name, v_bus.registration_number) || ' ' || coalesce(v_src_name, '') || ' to ' || coalesce(v_dst_name, ''),
      p_source, p_dest, p_departure, p_duration, p_duration, p_days, 'paused', 'outbound'
    );
  else
    -- A new return service starts from the outbound service's booking rules, confirmed schedule
    -- and base fares; it follows the bus's activation state through activate/deactivate_bus.
    insert into public.bus_services (
      operator_id, route_id, bus_id, service_name, service_source_city_id, service_dest_city_id,
      default_departure_time, default_arrival_offset_minutes, est_duration_min, operating_days, status, direction,
      booking_open_days_before, booking_cutoff_min, boarding_cutoff_min, schedule_configured
    ) values (
      v_bus.operator_id, v_route_id, p_bus_id,
      coalesce(v_bus.name, v_bus.registration_number) || ' ' || coalesce(v_src_name, '') || ' to ' || coalesce(v_dst_name, ''),
      p_source, p_dest, p_departure, p_duration, p_duration, p_days, coalesce(v_primary.status, 'paused'), 'return',
      coalesce(v_primary.booking_open_days_before, 30), coalesce(v_primary.booking_cutoff_min, 30),
      coalesce(v_primary.boarding_cutoff_min, 15), true
    ) returning id into v_new_svc;
    if v_primary.id is not null then
      insert into public.fare_rules (service_id, seat_type, berth, seat_category, base_fare_cents, effective_from, effective_to)
      select v_new_svc, seat_type, berth, seat_category, base_fare_cents, effective_from, effective_to
      from public.fare_rules
      where service_id = v_primary.id and from_boarding_point_id is null and to_dropping_point_id is null;
      insert into public.fare_charges (service_id, name, kind, flat_cents, percent)
      select v_new_svc, name, kind, flat_cents, percent from public.fare_charges where service_id = v_primary.id;
    end if;
  end if;

  return v_route_id;
end;
$$;

-- save_bus_route now only serves buses still being set up (draft / changes requested).
-- Once a bus is approved, route changes go through route revisions.
create or replace function public.save_bus_route(
  p_bus_id uuid,
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_distance_km numeric,
  p_departure_time time,
  p_duration_min integer,
  p_operating_days smallint[],
  p_stops jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_route_id uuid;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
  if v_bus.lifecycle_status not in ('draft', 'changes_requested') then
    raise exception 'The route is locked while the bus is %; submit a route change request instead', v_bus.lifecycle_status;
  end if;

  v_route_id := private.apply_route_journey(
    p_bus_id, 'outbound', p_source_city_id, p_destination_city_id, p_distance_km,
    p_departure_time, p_duration_min, p_operating_days, p_stops, null, null);

  perform private.write_audit(
    'bus.route_saved', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'route_id', v_route_id, 'stops', jsonb_array_length(p_stops))
  );
  return public.validate_bus_route(p_bus_id);
end;
$$;

revoke execute on function public.save_bus_route(uuid, uuid, uuid, numeric, time, integer, smallint[], jsonb) from public, anon;
grant execute on function public.save_bus_route(uuid, uuid, uuid, numeric, time, integer, smallint[], jsonb) to authenticated;

-- Trip generation covers every active, configured service of the bus (outbound and return).
create or replace function public.generate_bus_trips(p_bus_id uuid, p_from date, p_to date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_primary public.bus_services;
  v_svc public.bus_services;
  v_day date;
  v_dep timestamptz;
  v_count integer := 0;
  v_rows integer;
  i integer;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_staff(v_bus.operator_id) then raise exception 'Not authorized'; end if;
  if not private.is_bus_bookable(p_bus_id) then
    raise exception 'Trips can only be generated for an active bus of an approved operator';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 90 then
    raise exception 'Choose a date range of at most 90 days';
  end if;

  select * into v_primary from public.bus_services where id = private.bus_primary_service(p_bus_id);
  if v_primary.id is null or not v_primary.schedule_configured then
    raise exception 'Confirm the schedule before generating trips';
  end if;
  if v_primary.status <> 'active' then
    raise exception 'The bus service is not active';
  end if;

  for v_svc in
    select * from public.bus_services
    where bus_id = p_bus_id and status = 'active' and schedule_configured
    order by direction desc, created_at
  loop
    for i in 0 .. (p_to - p_from) loop
      v_day := p_from + i;
      if extract(isodow from v_day)::smallint = any (v_svc.operating_days) then
        v_dep := (v_day + v_svc.default_departure_time) at time zone 'Asia/Kolkata';
        insert into public.bus_trips (
          service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at,
          booking_open_at, booking_close_at
        ) values (
          v_svc.id, v_svc.operator_id, v_svc.route_id, v_svc.bus_id, v_day, v_dep,
          v_dep + make_interval(mins => v_svc.default_arrival_offset_minutes),
          greatest(v_dep - make_interval(days => v_svc.booking_open_days_before), now()),
          v_dep - make_interval(mins => v_svc.booking_cutoff_min)
        )
        on conflict (service_id, travel_date) do nothing;
        get diagnostics v_rows = row_count;
        v_count := v_count + v_rows;
      end if;
    end loop;
  end loop;

  perform private.write_audit(
    'bus.trips_generated', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'from', p_from, 'to', p_to, 'created', v_count)
  );
  return v_count;
end;
$$;

revoke execute on function public.generate_bus_trips(uuid, date, date) from public, anon;
grant execute on function public.generate_bus_trips(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 8. Materialising a revision into the live tables (approval / setup apply).
--    The only code path that writes live routes from a revision.
-- ---------------------------------------------------------------------
create or replace function private.materialize_revision(p_revision_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_bus public.buses;
  v_out public.route_revision_journeys;
  v_ret public.route_revision_journeys;
  v_out_route uuid;
  v_ret_route uuid;
  v_check jsonb;
  v_old_ret_route uuid;
  v_old_ret_svc uuid;
begin
  select * into v_rev from public.route_revisions where id = p_revision_id;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  select * into v_bus from public.buses where id = v_rev.bus_id for update;

  v_check := private.validate_revision(p_revision_id);
  if not (v_check ->> 'valid')::boolean then
    raise exception 'The route revision is not valid: %', v_check -> 'errors' -> 0 ->> 'message';
  end if;

  select * into v_out from public.route_revision_journeys where revision_id = p_revision_id and direction = 'outbound';
  select * into v_ret from public.route_revision_journeys where revision_id = p_revision_id and direction = 'return';

  v_out_route := private.apply_route_journey(
    v_rev.bus_id, 'outbound', v_out.source_city_id, v_out.destination_city_id, null,
    v_out.departure_time, v_out.est_duration_min, v_out.operating_days,
    private.journey_stops_json(v_out.id), null, v_out.id);

  if v_rev.trip_type = 'round_trip' then
    v_ret_route := private.apply_route_journey(
      v_rev.bus_id, 'return', v_ret.source_city_id, v_ret.destination_city_id, null,
      v_ret.departure_time, v_ret.est_duration_min, v_ret.operating_days,
      private.journey_stops_json(v_ret.id), v_out_route, v_ret.id);
    update public.bus_routes set linked_route_id = v_ret_route where id = v_out_route;
  else
    -- one way: retire any return journey left from an earlier revision (points deactivated, not deleted)
    select id into v_old_ret_route from public.bus_routes where bus_id = v_rev.bus_id and direction = 'return';
    if v_old_ret_route is not null then
      update public.bus_routes set active = false, linked_route_id = null where id = v_old_ret_route;
      update public.bus_routes set linked_route_id = null where id = v_out_route;
      update public.bus_services set status = 'retired' where route_id = v_old_ret_route;
      update public.boarding_points set is_active = false where route_id = v_old_ret_route;
      update public.dropping_points set is_active = false where route_id = v_old_ret_route;
      insert into public.route_change_flags (revision_id, booking_item_id, reason)
      select p_revision_id, bi.id, 'route_removed'
      from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
      where t.route_id = v_old_ret_route and t.departure_at > now()
        and bi.status in ('confirmed', 'payment_pending', 'hold_created')
      on conflict do nothing;
    end if;
  end if;

  -- Existing future bookings are never changed, only flagged for review.
  insert into public.route_change_flags (revision_id, booking_item_id, reason)
  select p_revision_id, bi.id,
         case when not bp.is_active or not dp.is_active then 'point_removed' else 'order_changed' end
  from public.booking_items bi
  join public.bus_trips t on t.id = bi.trip_id
  join public.boarding_points bp on bp.id = bi.boarding_point_id
  join public.dropping_points dp on dp.id = bi.dropping_point_id
  where t.bus_id = v_rev.bus_id and t.departure_at > now()
    and bi.status in ('confirmed', 'payment_pending', 'hold_created')
    and (not bp.is_active or not dp.is_active or bp.sequence_no >= dp.sequence_no)
  on conflict do nothing;

  if v_bus.active_route_revision_id is not null and v_bus.active_route_revision_id <> p_revision_id then
    update public.route_revisions set status = 'superseded'
    where id = v_bus.active_route_revision_id and status = 'approved';
    insert into public.route_revision_events (revision_id, event, actor_id)
    values (v_bus.active_route_revision_id, 'superseded', (select auth.uid()));
  end if;
  update public.buses set active_route_revision_id = p_revision_id where id = v_rev.bus_id;
  update public.route_revisions set activated_at = now() where id = p_revision_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Operator RPCs
-- ---------------------------------------------------------------------
create or replace function private.load_revision_for_edit(p_revision_id uuid)
returns public.route_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare v_rev public.route_revisions;
begin
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if not private.can_manage_routes(v_rev.operator_id) then raise exception 'Not authorized'; end if;
  if v_rev.status <> 'draft' then
    raise exception 'This revision is % and can no longer be edited; start a new revision', v_rev.status;
  end if;
  return v_rev;
end;
$$;

create or replace function public.start_route_revision(p_bus_id uuid, p_base_revision_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_open public.route_revisions;
  v_base public.route_revisions;
  v_no integer;
  v_rev uuid;
  v_svc public.bus_services;
  v_route public.bus_routes;
  v_jid uuid;
  j public.route_revision_journeys;
  v_src text;
  v_dst text;
  d text;
  v_has_return boolean := false;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.can_manage_routes(v_bus.operator_id) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
  if v_bus.lifecycle_status not in ('draft', 'changes_requested', 'approved', 'active') then
    raise exception 'Route changes are locked while the bus is %', v_bus.lifecycle_status;
  end if;

  select * into v_open from public.route_revisions where bus_id = p_bus_id and status in ('draft', 'pending_approval');
  if v_open.id is not null then
    if v_open.status = 'pending_approval' then raise exception 'A route change is already awaiting approval'; end if;
    if p_base_revision_id is null then return v_open.id; end if;
    raise exception 'Finish or withdraw the open draft revision first';
  end if;

  if p_base_revision_id is not null then
    select * into v_base from public.route_revisions where id = p_base_revision_id and bus_id = p_bus_id;
    if v_base.id is null then raise exception 'Base revision not found'; end if;
  end if;

  select coalesce(max(revision_no), 0) + 1 into v_no from public.route_revisions where bus_id = p_bus_id;
  insert into public.route_revisions (bus_id, operator_id, revision_no, status, trip_type, base_revision_id, created_by)
  values (p_bus_id, v_bus.operator_id, v_no, 'draft', coalesce(v_base.trip_type, 'one_way'),
          coalesce(p_base_revision_id, v_bus.active_route_revision_id), (select auth.uid()))
  returning id into v_rev;

  if v_base.id is not null then
    for j in select * from public.route_revision_journeys where revision_id = v_base.id loop
      insert into public.route_revision_journeys (revision_id, direction, source_city_id, destination_city_id,
        departure_time, est_duration_min, operating_days, departure_day_offset, reverse_generated)
      values (v_rev, j.direction, j.source_city_id, j.destination_city_id, j.departure_time, j.est_duration_min,
              j.operating_days, j.departure_day_offset, j.reverse_generated)
      returning id into v_jid;
      perform private.insert_journey_stops(v_jid, private.journey_stops_json(j.id));
    end loop;
  else
    -- clone the live route(s)
    foreach d in array array['outbound', 'return'] loop
      if d = 'outbound' then
        select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);
      else
        select * into v_svc from public.bus_services
        where bus_id = p_bus_id and direction = 'return' and status <> 'retired' order by created_at limit 1;
      end if;
      if v_svc.id is null then continue; end if;
      select * into v_route from public.bus_routes where id = v_svc.route_id;
      if not v_route.active then continue; end if;
      insert into public.route_revision_journeys (revision_id, direction, source_city_id, destination_city_id,
        departure_time, est_duration_min, operating_days)
      values (v_rev, d, v_route.source_city_id, v_route.destination_city_id, v_svc.default_departure_time,
              v_svc.est_duration_min, v_svc.operating_days)
      returning id into v_jid;
      perform private.insert_journey_stops(v_jid, private.live_route_stops(v_route.id));
      if d = 'return' then v_has_return := true; end if;
    end loop;
    if v_has_return then update public.route_revisions set trip_type = 'round_trip' where id = v_rev; end if;
  end if;

  select l.name into v_src from public.route_revision_journeys j2 join public.locations l on l.id = j2.source_city_id
    where j2.revision_id = v_rev and j2.direction = 'outbound';
  select l.name into v_dst from public.route_revision_journeys j2 join public.locations l on l.id = j2.destination_city_id
    where j2.revision_id = v_rev and j2.direction = 'outbound';
  if v_src is not null then
    update public.route_revisions set name = v_src || ' to ' || v_dst where id = v_rev;
  end if;

  insert into public.route_revision_events (revision_id, event, actor_id) values (v_rev, 'created', (select auth.uid()));
  return v_rev;
end;
$$;

-- p_payload: {trip_type, name, outbound:{source_city_id, destination_city_id, departure_time,
--   duration_min, operating_days[], stops[]}, return:{... , departure_day_offset, reverse_generated}}
-- Saves a draft (incomplete drafts are fine) and returns the validation result.
create or replace function public.save_route_revision(p_revision_id uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_trip text;
  d text;
  v_j jsonb;
  v_jid uuid;
begin
  v_rev := private.load_revision_for_edit(p_revision_id);
  v_trip := coalesce(p_payload ->> 'trip_type', v_rev.trip_type);
  if v_trip not in ('one_way', 'round_trip') then raise exception 'Trip type must be one way or round trip'; end if;

  delete from public.route_revision_journeys where revision_id = p_revision_id;
  foreach d in array array['outbound', 'return'] loop
    v_j := p_payload -> d;
    if v_j is null or jsonb_typeof(v_j) <> 'object' then continue; end if;
    if d = 'return' and v_trip = 'one_way' then continue; end if;
    insert into public.route_revision_journeys (revision_id, direction, source_city_id, destination_city_id,
      departure_time, est_duration_min, operating_days, departure_day_offset, reverse_generated)
    values (p_revision_id, d, nullif(v_j ->> 'source_city_id', '')::uuid, nullif(v_j ->> 'destination_city_id', '')::uuid,
            nullif(v_j ->> 'departure_time', '')::time, nullif(v_j ->> 'duration_min', '')::integer,
            coalesce(array(select jsonb_array_elements_text(coalesce(v_j -> 'operating_days', '[]'::jsonb))::smallint), '{}'),
            coalesce(nullif(v_j ->> 'departure_day_offset', '')::smallint, 0),
            coalesce((v_j ->> 'reverse_generated')::boolean, false))
    returning id into v_jid;
    perform private.insert_journey_stops(v_jid, v_j -> 'stops');
  end loop;

  update public.route_revisions
  set trip_type = v_trip, name = coalesce(nullif(btrim(p_payload ->> 'name'), ''), name)
  where id = p_revision_id;
  return private.validate_revision(p_revision_id);
end;
$$;

-- Builds the return journey as the reverse of the outbound one. The result is an ordinary
-- editable return journey (flagged reverse_generated); times are mirrored from the outbound.
create or replace function public.generate_reverse_route(p_revision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_out public.route_revision_journeys;
  v_old public.route_revision_journeys;
  v_dur integer;
  v_dep time;
  v_off smallint;
  v_days smallint[];
  v_jid uuid;
begin
  v_rev := private.load_revision_for_edit(p_revision_id);
  select * into v_out from public.route_revision_journeys where revision_id = p_revision_id and direction = 'outbound';
  if v_out.id is null then raise exception 'Configure the outbound journey first'; end if;
  v_dur := v_out.est_duration_min;
  if v_dur is null then raise exception 'Set the outbound journey duration first'; end if;
  select * into v_old from public.route_revision_journeys where revision_id = p_revision_id and direction = 'return';

  v_off := coalesce(v_old.departure_day_offset,
    case when v_out.departure_time is not null
          and extract(epoch from v_out.departure_time) / 60 + v_dur >= 1440 then 1 else 0 end);
  v_dep := coalesce(v_old.departure_time,
    case when v_out.departure_time is not null then v_out.departure_time + make_interval(mins => v_dur) end);
  v_days := case when coalesce(array_length(v_old.operating_days, 1), 0) > 0 then v_old.operating_days
    else coalesce((select array_agg((((x - 1 + v_off) % 7) + 1)::smallint order by x)
                   from unnest(v_out.operating_days) x), '{}') end;

  delete from public.route_revision_journeys where revision_id = p_revision_id and direction = 'return';
  insert into public.route_revision_journeys (revision_id, direction, source_city_id, destination_city_id,
    departure_time, est_duration_min, operating_days, departure_day_offset, reverse_generated)
  values (p_revision_id, 'return', v_out.destination_city_id, v_out.source_city_id, v_dep, v_dur, v_days, v_off, true)
  returning id into v_jid;

  insert into public.route_revision_stops (journey_id, sequence_no, city_id, arrival_offset_min, departure_offset_min,
                                           is_boarding, is_dropping, address, latitude, longitude)
  select v_jid, (row_number() over (order by s.sequence_no desc))::integer, s.city_id,
         v_dur - coalesce(s.departure_offset_min, s.arrival_offset_min, 0),
         v_dur - coalesce(s.arrival_offset_min, s.departure_offset_min, 0),
         s.is_dropping, s.is_boarding, s.address, s.latitude, s.longitude
  from public.route_revision_stops s where s.journey_id = v_out.id;

  update public.route_revisions set trip_type = 'round_trip' where id = p_revision_id;
  return private.validate_revision(p_revision_id);
end;
$$;

create or replace function public.validate_route_revision(p_revision_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (private.is_platform_admin() or private.is_operator_staff(private.revision_operator_id(p_revision_id))) then
    raise exception 'Not authorized';
  end if;
  return private.validate_revision(p_revision_id);
end;
$$;

create or replace function public.submit_route_revision(p_revision_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_bus public.buses;
  v_check jsonb;
  v_reason text := nullif(btrim(p_reason), '');
begin
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if not private.is_operator_admin(v_rev.operator_id) then
    raise exception 'Only an operator administrator can submit a route change';
  end if;
  if v_rev.status <> 'draft' then raise exception 'This revision is already %', v_rev.status; end if;
  select * into v_bus from public.buses where id = v_rev.bus_id for update;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;

  v_check := private.validate_revision(p_revision_id);
  if not (v_check ->> 'valid')::boolean then
    return jsonb_build_object('ok', false, 'errors', v_check -> 'errors');
  end if;

  if v_bus.lifecycle_status in ('draft', 'changes_requested') then
    -- Setup stage: the bus itself still goes through admin approval, so the route is applied directly.
    perform private.materialize_revision(p_revision_id);
    update public.route_revisions
    set status = 'approved', submitted_by = (select auth.uid()), submitted_at = now(),
        change_reason = coalesce(v_reason, 'Initial route setup')
    where id = p_revision_id;
    insert into public.route_revision_events (revision_id, event, actor_id, reason)
    values (p_revision_id, 'applied_setup', (select auth.uid()), v_reason);
    perform private.write_audit('route.applied_setup', 'route_revision', p_revision_id, null,
      jsonb_build_object('bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id));
    return jsonb_build_object('ok', true, 'status', 'approved', 'applied', true);
  end if;

  if v_reason is null then raise exception 'A reason for the change is required'; end if;
  update public.route_revisions
  set status = 'pending_approval', submitted_by = (select auth.uid()), submitted_at = now(), change_reason = v_reason
  where id = p_revision_id;
  insert into public.route_revision_events (revision_id, event, actor_id, reason)
  values (p_revision_id, 'submitted', (select auth.uid()), v_reason);

  insert into public.notifications (profile_id, title, body, data, type)
  select distinct ur.user_id, 'Route change awaiting approval',
         coalesce(v_rev.name, 'A route') || ' on bus ' || v_bus.registration_number || ' needs review.',
         jsonb_build_object('revision_id', p_revision_id, 'bus_id', v_rev.bus_id), 'route_revision_submitted'
  from public.user_roles ur where ur.role in ('platform_admin', 'platform_support');

  perform private.write_audit('route.submitted', 'route_revision', p_revision_id, null,
    jsonb_build_object('bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'status', 'pending_approval', 'applied', false);
end;
$$;

create or replace function public.withdraw_route_revision(p_revision_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_rev public.route_revisions;
begin
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if not private.can_manage_routes(v_rev.operator_id) then raise exception 'Not authorized'; end if;
  if v_rev.status not in ('draft', 'pending_approval') then raise exception 'This revision is already %', v_rev.status; end if;
  update public.route_revisions set status = 'withdrawn' where id = p_revision_id;
  insert into public.route_revision_events (revision_id, event, actor_id) values (p_revision_id, 'withdrawn', (select auth.uid()));
  perform private.write_audit('route.withdrawn', 'route_revision', p_revision_id, null,
    jsonb_build_object('bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id));
end;
$$;

-- ---------------------------------------------------------------------
-- 10. Admin review. One transaction: validate, materialise, mark approved,
--     supersede the previous revision, set the bus's active reference, notify.
-- ---------------------------------------------------------------------
create or replace function public.admin_review_route_revision(p_revision_id uuid, p_action text, p_reason text default null)
returns public.route_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_bus public.buses;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if not private.is_platform_admin() then raise exception 'Not authorized'; end if;
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if v_rev.status <> 'pending_approval' then raise exception 'This revision is %, not awaiting approval', v_rev.status; end if;
  if v_rev.submitted_by is not distinct from (select auth.uid()) then
    raise exception 'You cannot review a route change you submitted yourself';
  end if;
  select * into v_bus from public.buses where id = v_rev.bus_id for update;

  if p_action = 'approve' then
    perform private.materialize_revision(p_revision_id);
    update public.route_revisions
    set status = 'approved', reviewed_by = (select auth.uid()), reviewed_at = now()
    where id = p_revision_id returning * into v_rev;
    insert into public.route_revision_events (revision_id, event, actor_id, reason)
    values (p_revision_id, 'approved', (select auth.uid()), v_reason);
    insert into public.notifications (profile_id, title, body, data, type)
    values (v_rev.submitted_by, 'Route change approved',
            coalesce(v_rev.name, 'Your route') || ' on bus ' || v_bus.registration_number || ' is now live.',
            jsonb_build_object('revision_id', p_revision_id, 'bus_id', v_rev.bus_id), 'route_revision_approved');
  elsif p_action = 'reject' then
    if v_reason is null then raise exception 'A reason is required to reject a route change'; end if;
    update public.route_revisions
    set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now(), rejection_reason = v_reason
    where id = p_revision_id returning * into v_rev;
    insert into public.route_revision_events (revision_id, event, actor_id, reason)
    values (p_revision_id, 'rejected', (select auth.uid()), v_reason);
    insert into public.notifications (profile_id, title, body, data, type)
    values (v_rev.submitted_by, 'Route change rejected',
            coalesce(v_rev.name, 'Your route') || ' on bus ' || v_bus.registration_number || ' was rejected: ' || v_reason,
            jsonb_build_object('revision_id', p_revision_id, 'bus_id', v_rev.bus_id, 'reason', v_reason),
            'route_revision_rejected');
  else
    raise exception 'Unknown action %', p_action;
  end if;

  perform private.write_audit('route.' || p_action, 'route_revision', p_revision_id, null,
    jsonb_build_object('bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id, 'reason', v_reason));
  return v_rev;
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Comparison: proposed vs current live route (or vs the base revision for
--     revisions that are already decided).
-- ---------------------------------------------------------------------
create or replace function private.diff_journeys(c jsonb, p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_added jsonb; v_removed jsonb; v_reseq jsonb; v_perm jsonb; v_times jsonb; v_fields text[] := '{}';
begin
  if c is null and p is null then return jsonb_build_object('added_journey', false, 'removed_journey', false); end if;
  if c is null then return jsonb_build_object('added_journey', true, 'removed_journey', false); end if;
  if p is null then return jsonb_build_object('added_journey', false, 'removed_journey', true); end if;

  with cs as (select * from jsonb_to_recordset(c -> 'stops') as x(city_id uuid, name text, sequence_no int,
                is_boarding boolean, is_dropping boolean, arrival_offset_min int, departure_offset_min int)),
       ps as (select * from jsonb_to_recordset(p -> 'stops') as x(city_id uuid, name text, sequence_no int,
                is_boarding boolean, is_dropping boolean, arrival_offset_min int, departure_offset_min int)),
       cc as (select *, row_number() over (order by sequence_no) as pos from cs where city_id in (select city_id from ps)),
       pc as (select *, row_number() over (order by sequence_no) as pos from ps where city_id in (select city_id from cs))
  select
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', ps.city_id, 'name', ps.name, 'position', ps.sequence_no) order by ps.sequence_no), '[]')
       from ps where ps.city_id not in (select city_id from cs)),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', cs.city_id, 'name', cs.name, 'position', cs.sequence_no) order by cs.sequence_no), '[]')
       from cs where cs.city_id not in (select city_id from ps)),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', pc.city_id, 'name', pc.name, 'from', cc.sequence_no, 'to', pc.sequence_no) order by pc.sequence_no), '[]')
       from cc join pc using (city_id) where cc.pos <> pc.pos),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', pc.city_id, 'name', pc.name,
              'boarding', jsonb_build_object('from', cc.is_boarding, 'to', pc.is_boarding),
              'dropping', jsonb_build_object('from', cc.is_dropping, 'to', pc.is_dropping)) order by pc.sequence_no), '[]')
       from cc join pc using (city_id)
       where cc.is_boarding is distinct from pc.is_boarding or cc.is_dropping is distinct from pc.is_dropping),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', pc.city_id, 'name', pc.name,
              'arrival', jsonb_build_object('from', cc.arrival_offset_min, 'to', pc.arrival_offset_min),
              'departure', jsonb_build_object('from', cc.departure_offset_min, 'to', pc.departure_offset_min)) order by pc.sequence_no), '[]')
       from cc join pc using (city_id)
       where cc.arrival_offset_min is distinct from pc.arrival_offset_min
          or cc.departure_offset_min is distinct from pc.departure_offset_min)
  into v_added, v_removed, v_reseq, v_perm, v_times;
  -- (added/removed are listed first in the select; the order matches the INTO list)

  if (c ->> 'departure_time') is distinct from (p ->> 'departure_time') then v_fields := v_fields || 'departure_time'; end if;
  if (c ->> 'duration_min') is distinct from (p ->> 'duration_min') then v_fields := v_fields || 'duration'; end if;
  if (c -> 'operating_days') is distinct from (p -> 'operating_days') then v_fields := v_fields || 'operating_days'; end if;
  if (c ->> 'departure_day_offset') is distinct from (p ->> 'departure_day_offset') then v_fields := v_fields || 'departure_day_offset'; end if;

  return jsonb_build_object(
    'added_journey', false, 'removed_journey', false,
    'direction_changed', (c ->> 'source_city_id') is distinct from (p ->> 'source_city_id')
                         or (c ->> 'destination_city_id') is distinct from (p ->> 'destination_city_id'),
    'added_stops', v_added, 'removed_stops', v_removed, 'resequenced', v_reseq,
    'permission_changes', v_perm, 'time_changes', v_times, 'schedule_changes', to_jsonb(v_fields));
end;
$$;

create or replace function private.revision_journey_json(p_revision_id uuid, p_direction text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'source_city_id', j.source_city_id, 'source_name', ls.name,
    'destination_city_id', j.destination_city_id, 'destination_name', ld.name,
    'departure_time', j.departure_time, 'duration_min', j.est_duration_min,
    'operating_days', to_jsonb(j.operating_days), 'departure_day_offset', j.departure_day_offset,
    'reverse_generated', j.reverse_generated,
    'stops', private.journey_stops_json(j.id))
  from public.route_revision_journeys j
  left join public.locations ls on ls.id = j.source_city_id
  left join public.locations ld on ld.id = j.destination_city_id
  where j.revision_id = p_revision_id and j.direction = p_direction;
$$;

create or replace function private.live_journey_json(p_bus_id uuid, p_direction text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'source_city_id', r.source_city_id, 'source_name', ls.name,
    'destination_city_id', r.destination_city_id, 'destination_name', ld.name,
    'departure_time', s.default_departure_time, 'duration_min', s.est_duration_min,
    'operating_days', to_jsonb(s.operating_days), 'departure_day_offset', 0,
    'stops', private.live_route_stops(r.id))
  from public.bus_routes r
  join public.bus_services s on s.route_id = r.id and s.status <> 'retired'
  left join public.locations ls on ls.id = r.source_city_id
  left join public.locations ld on ld.id = r.destination_city_id
  where r.bus_id = p_bus_id and r.direction = p_direction and r.active
  order by s.created_at limit 1;
$$;

create or replace function public.get_route_revision_diff(p_revision_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_base_status boolean;
  d text;
  cur jsonb;
  prop jsonb;
  res jsonb := '{}'::jsonb;
  v_cur_type text;
begin
  select * into v_rev from public.route_revisions where id = p_revision_id;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if not (private.is_platform_admin() or private.is_operator_staff(v_rev.operator_id)) then raise exception 'Not authorized'; end if;

  -- open / unsuccessful revisions are compared with what is live; decided ones with their base revision
  v_base_status := v_rev.status in ('draft', 'pending_approval', 'rejected', 'withdrawn');
  foreach d in array array['outbound', 'return'] loop
    if v_base_status then
      cur := private.live_journey_json(v_rev.bus_id, d);
    elsif v_rev.base_revision_id is not null then
      cur := private.revision_journey_json(v_rev.base_revision_id, d);
    else
      cur := null;
    end if;
    prop := private.revision_journey_json(p_revision_id, d);
    res := res || jsonb_build_object(d, jsonb_build_object(
      'current', cur, 'proposed', prop, 'changes', private.diff_journeys(cur, prop)));
  end loop;

  v_cur_type := case when jsonb_typeof(res -> 'return' -> 'current') = 'object' then 'round_trip' else 'one_way' end;
  return res || jsonb_build_object(
    'trip_type', jsonb_build_object('current', v_cur_type, 'proposed', v_rev.trip_type),
    'revision', jsonb_build_object('id', v_rev.id, 'revision_no', v_rev.revision_no, 'status', v_rev.status,
                                   'name', v_rev.name, 'change_reason', v_rev.change_reason));
end;
$$;

-- ---------------------------------------------------------------------
-- 12. Grants
-- ---------------------------------------------------------------------
revoke execute on function
  public.start_route_revision(uuid, uuid), public.save_route_revision(uuid, jsonb),
  public.generate_reverse_route(uuid), public.validate_route_revision(uuid),
  public.submit_route_revision(uuid, text), public.withdraw_route_revision(uuid),
  public.admin_review_route_revision(uuid, text, text), public.get_route_revision_diff(uuid)
  from public, anon;
grant execute on function
  public.start_route_revision(uuid, uuid), public.save_route_revision(uuid, jsonb),
  public.generate_reverse_route(uuid), public.validate_route_revision(uuid),
  public.submit_route_revision(uuid, text), public.withdraw_route_revision(uuid),
  public.admin_review_route_revision(uuid, text, text), public.get_route_revision_diff(uuid)
  to authenticated;

revoke execute on function
  private.validate_route_journey(uuid, uuid, uuid, time, integer, smallint[], jsonb, boolean),
  private.journey_stops_json(uuid), private.live_route_stops(uuid), private.insert_journey_stops(uuid, jsonb),
  private.validate_revision(uuid),
  private.apply_route_journey(uuid, text, uuid, uuid, numeric, time, integer, smallint[], jsonb, uuid, uuid),
  private.materialize_revision(uuid), private.load_revision_for_edit(uuid), private.diff_journeys(jsonb, jsonb),
  private.revision_journey_json(uuid, text), private.live_journey_json(uuid, text)
  from public, anon, authenticated;
