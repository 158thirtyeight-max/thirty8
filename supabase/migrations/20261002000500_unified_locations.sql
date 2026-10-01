-- =========================================================================
-- Unified location master.
--
-- ONE canonical table, public.locations, replaces the two-level model
-- (cities as "main locations" + pickup_drop_points as child points):
--
--   * the physical table public.cities is renamed to public.locations, so every
--     foreign key (routes, services, route stops, cargo hubs / routes, route
--     templates) keeps pointing at the same rows and ids. The *_city_id column
--     names are kept; they now hold a locations.id.
--   * a location carries independent flags (main route / pickup / drop) and
--     independent display orders for each use.
--   * every location has a permanent business code  T8 + 3 letters + 3 digits.
--   * public.pickup_drop_points (empty) and the main_locations view are removed.
--   * route stops are locations: a stop is a boarding_points / dropping_points
--     row whose city_id is the location. route_stops / service_stops views
--     expose them by location.
--
-- Locations are never deleted (trigger) so codes are never reused.
-- Pre-migration data was exported to supabase/backups/.
-- =========================================================================

drop view if exists public.route_stops;
drop view if exists public.service_stops;
drop view if exists public.main_locations;

do $$
begin
  if exists (select 1 from public.pickup_drop_points) then
    raise exception 'pickup_drop_points still holds rows; migrate them before unifying';
  end if;
end $$;

alter table public.boarding_points drop column master_point_id;
alter table public.dropping_points drop column master_point_id;
drop table public.pickup_drop_points;

-- the old insert trigger / helper
drop trigger cities_before_insert on public.cities;
drop function private.cities_before_insert();

alter table public.cities rename to locations;
alter policy cities_select_public on public.locations rename to locations_select_public;
alter policy cities_admin_write on public.locations rename to locations_admin_write;

drop index if exists public.cities_slug_uniq;
drop index if exists public.cities_display_order_idx;

alter table public.locations
  add column location_code text,
  add column normalized_name text,
  add column is_main_route_enabled boolean not null default true,
  add column is_pickup_enabled boolean not null default true,
  add column is_drop_enabled boolean not null default true,
  add column main_route_order integer,
  add column pickup_order integer,
  add column drop_order integer,
  add column port_name text;

-- ---------------------------------------------------------------------
-- Name normalisation, codes, orders (all server-side)
-- ---------------------------------------------------------------------
create or replace function private.normalize_location_name(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(coalesce(p_name, ''), '[^a-zA-Z0-9]+', '', 'g'));
$$;

-- T8 + first three letters of the name + next free three-digit sequence for that prefix.
create or replace function private.next_location_code(p_name text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_abbr text := upper(left(regexp_replace(coalesce(p_name, ''), '[^A-Za-z]', '', 'g'), 3));
  v_seq integer;
begin
  v_abbr := rpad(v_abbr, 3, 'X');
  select coalesce(max(substr(location_code, 6)::integer), 0) + 1 into v_seq
  from public.locations
  where location_code ~ ('^T8' || v_abbr || '[0-9]{3}$');
  if v_seq > 999 then raise exception 'Location code sequence exhausted for %', v_abbr; end if;
  return 'T8' || v_abbr || lpad(v_seq::text, 3, '0');
end;
$$;

create or replace function private.locations_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.name := btrim(regexp_replace(new.name, '\s+', ' ', 'g'));
  if new.name = '' then raise exception 'A location name is required'; end if;
  new.normalized_name := private.normalize_location_name(new.name);

  if tg_op = 'INSERT' then
    if new.country_id is null then
      select id into new.country_id from public.countries where code = 'IND';
    end if;
    if new.location_code is null then
      perform pg_advisory_xact_lock(hashtext('thirty8_location_code'));
      new.location_code := private.next_location_code(new.name);
    end if;
    if new.main_route_order is null then select coalesce(max(main_route_order), 0) + 1 into new.main_route_order from public.locations; end if;
    if new.pickup_order is null then select coalesce(max(pickup_order), 0) + 1 into new.pickup_order from public.locations; end if;
    if new.drop_order is null then select coalesce(max(drop_order), 0) + 1 into new.drop_order from public.locations; end if;
  else
    if new.location_code is distinct from old.location_code then
      raise exception 'A location code is permanent and cannot be changed';
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.locations_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Locations cannot be deleted (their codes are permanent). Disable the location instead.';
end;
$$;

-- A renamed location shows its new canonical name on every route stop and catalog stop.
create or replace function private.locations_after_rename()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.name is distinct from old.name then
    update public.boarding_points set name = new.name where city_id = new.id and name is distinct from new.name;
    update public.dropping_points set name = new.name where city_id = new.id and name is distinct from new.name;
    update public.route_template_stops set name = new.name where city_id = new.id and name is distinct from new.name;
  end if;
  return null;
end;
$$;

revoke execute on function private.next_location_code(text) from public, anon, authenticated;
revoke execute on function private.locations_before_write() from public, anon, authenticated;
revoke execute on function private.locations_no_delete() from public, anon, authenticated;
revoke execute on function private.locations_after_rename() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Move the existing rows onto their permanent codes (matched by their old slug),
-- remove the one row that is not in the approved list, then drop old columns.
-- ---------------------------------------------------------------------
update public.locations l
set location_code = m.code
from (values
  ('sri-vijaya-puram', 'T8SVP001'), ('baratang', 'T8BAR001'), ('kadamtala', 'T8KAD001'), ('middle-strait', 'T8MID001'),
  ('rangat', 'T8RAN001'), ('nimbudera', 'T8NIM001'), ('mayabunder', 'T8MAY001'), ('diglipur', 'T8DIG001'),
  ('aerial-bay-diglipur', 'T8AER001')
) as m(slug, code)
where l.slug = m.slug;

-- BAMBOOFLAT is not in the approved list and nothing references it.
delete from public.locations l
where l.slug = 'bambooflat'
  and not exists (select 1 from public.cargo_hub h where h.city_id = l.id)
  and not exists (select 1 from public.cargo_routes r where l.id in (r.source_city_id, r.destination_city_id))
  and not exists (select 1 from public.bus_routes r where l.id in (r.source_city_id, r.destination_city_id))
  and not exists (select 1 from public.boarding_points p where p.city_id = l.id)
  and not exists (select 1 from public.dropping_points p where p.city_id = l.id)
  and not exists (select 1 from public.route_templates t where l.id in (t.source_city_id, t.destination_city_id))
  and not exists (select 1 from public.route_template_stops s where s.city_id = l.id);

alter table public.locations drop column slug, drop column display_order;

-- normalised names for existing rows before the unique index
update public.locations set normalized_name = private.normalize_location_name(name);

-- Seed: the 33 initial locations, in the supplied order. Rows that already exist
-- (matched by code) are only given the canonical name; admin edits to flags, orders,
-- port and coordinates are never overwritten, so re-running is safe.
-- main route = the previously approved route locations that are still in the list.
do $$
declare
  r record;
  v_main integer := 0;
begin
  for r in
    select * from (values
      (1,  'T8SVP001', 'SRI VIJAYA PURAM', true),
      (2,  'T8ADA001', 'ADAZIG', false),
      (3,  'T8AMK001', 'AMKUNJ', false),
      (4,  'T8BAD001', 'BADAM NALLAH', false),
      (5,  'T8BAK001', 'BAKULTALA', false),
      (6,  'T8BAS001', 'BASANTIPUR', false),
      (7,  'T8BET001', 'BETAPUR', false),
      (8,  'T8BIL001', 'BILLIGROUND', false),
      (9,  'T8CEO001', 'CEO NALLAH', false),
      (10, 'T8KAU001', 'KAUSHALYA NAGAR', false),
      (11, 'T8KER001', 'KERLAPURAM', false),
      (12, 'T8KOR001', 'KORANG NALLAH', false),
      (13, 'T8BAR001', 'BARATANG', true),
      (14, 'T8JIR001', 'JIRKATANG / SOUTH CREEK', false),
      (15, 'T8UTT001', 'UTTARA', false),
      (16, 'T8VSP001', 'V S PALLY', false),
      (17, 'T8RRO001', 'R R O', false),
      (18, 'T8KAD001', 'KADAMTALA', true),
      (19, 'T8MID001', 'MIDDLE STRAIT', true),
      (20, 'T8MOH001', 'MOHANPUR', false),
      (21, 'T8RAN001', 'RANGAT', true),
      (22, 'T8NIM001', 'NIMBUDERA', true),
      (23, 'T8NBT001', 'NIMBUTALA', false),
      (24, 'T8PAN001', 'PANCHAWATI', false),
      (25, 'T8PAR001', 'PARANGARHA', false),
      (26, 'T8PYL001', 'PYLON', false),
      (27, 'T8SAB001', 'SABARI', false),
      (28, 'T8SIT001', 'SITA NAGAR', false),
      (29, 'T8KAL001', 'KALARA JUNCTION', false),
      (30, 'T8KPH001', 'KALAPAHAD', false),
      (31, 'T8MAY001', 'MAYABUNDER', true),
      (32, 'T8DIG001', 'DIGLIPUR', true),
      (33, 'T8AER001', 'AERIAL BAY', true)
    ) as v(ord, code, name, is_main)
    order by ord
  loop
    if r.is_main then v_main := v_main + 1; end if;
    if exists (select 1 from public.locations where location_code = r.code) then
      update public.locations
      set name = r.name, normalized_name = private.normalize_location_name(r.name), main_route_order = coalesce(main_route_order, case when r.is_main then v_main else 100 + r.ord end),
          pickup_order = coalesce(pickup_order, r.ord), drop_order = coalesce(drop_order, r.ord)
      where location_code = r.code;
    else
      insert into public.locations (country_id, name, normalized_name, state, location_code, is_active, is_main_route_enabled,
                                    is_pickup_enabled, is_drop_enabled, main_route_order, pickup_order, drop_order)
      values ((select id from public.countries where code = 'IND'), r.name, private.normalize_location_name(r.name),
              'Andaman and Nicobar Islands', r.code, true, r.is_main, true, true,
              case when r.is_main then v_main else 100 + r.ord end, r.ord, r.ord);
    end if;
  end loop;
end $$;

-- Existing rows seeded above only got their orders on first creation; align the nine
-- pre-existing main rows to the new list order and flags (one-time, this migration).
update public.locations set is_main_route_enabled = (location_code in
  ('T8SVP001', 'T8BAR001', 'T8KAD001', 'T8MID001', 'T8RAN001', 'T8NIM001', 'T8MAY001', 'T8DIG001', 'T8AER001'));
update public.locations l
set main_route_order = o.ord
from (values ('T8SVP001', 1), ('T8BAR001', 2), ('T8KAD001', 3), ('T8MID001', 4), ('T8RAN001', 5),
             ('T8NIM001', 6), ('T8MAY001', 7), ('T8DIG001', 8), ('T8AER001', 9)) as o(code, ord)
where l.location_code = o.code;

alter table public.locations
  alter column location_code set not null,
  alter column normalized_name set not null,
  alter column main_route_order set not null,
  alter column pickup_order set not null,
  alter column drop_order set not null,
  add constraint locations_code_format check (location_code ~ '^T8[A-Z]{3}[0-9]{3}$'),
  add constraint locations_coords_pair check ((latitude is null) = (longitude is null));

create unique index locations_code_uniq on public.locations (location_code);
create unique index locations_normalized_name_uniq on public.locations (normalized_name);
create index locations_main_route_idx on public.locations (main_route_order) where is_main_route_enabled and is_active;
create index locations_pickup_idx on public.locations (pickup_order) where is_pickup_enabled and is_active;
create index locations_drop_idx on public.locations (drop_order) where is_drop_enabled and is_active;

create trigger locations_before_write before insert or update on public.locations
  for each row execute function private.locations_before_write();
create trigger locations_no_delete before delete on public.locations
  for each row execute function private.locations_no_delete();
create trigger locations_after_rename after update of name on public.locations
  for each row execute function private.locations_after_rename();

-- ---------------------------------------------------------------------
-- Route stops by location (views over the route's boarding / dropping rows)
-- ---------------------------------------------------------------------
create view public.route_stops with (security_invoker = true) as
  with s as (
    select route_id, city_id, sequence_no, true as pickup, false as drop_ from public.boarding_points
      where is_active and city_id is not null
    union all
    select route_id, city_id, sequence_no, false, true from public.dropping_points
      where is_active and city_id is not null
  )
  select route_id,
         city_id as location_id,
         (row_number() over (partition by route_id order by min(sequence_no)))::integer as stop_order,
         bool_or(pickup) as is_pickup_allowed,
         bool_or(drop_) as is_drop_allowed
  from s
  group by route_id, city_id;

-- What each service serves: its locations, pickup / drop enabled, and clock times.
create view public.service_stops with (security_invoker = true) as
  with s as (
    select route_id, city_id, sequence_no, true as pickup, false as drop_,
           departure_offset_min as pickup_off, null::integer as drop_off
      from public.boarding_points where is_active and city_id is not null
    union all
    select route_id, city_id, sequence_no, false, true, null, arrival_offset_min
      from public.dropping_points where is_active and city_id is not null
  )
  select sv.id as service_id,
         s.city_id as location_id,
         min(s.sequence_no) as stop_order,
         bool_or(s.pickup) as pickup_enabled,
         bool_or(s.drop_) as drop_enabled,
         (sv.default_departure_time + make_interval(mins => min(s.pickup_off)))::time as pickup_time,
         (sv.default_departure_time + make_interval(mins => min(s.drop_off)))::time as drop_time
  from s
  join public.bus_services sv on sv.route_id = s.route_id
  group by sv.id, sv.default_departure_time, s.city_id;

grant select on public.route_stops, public.service_stops to anon, authenticated;

-- =========================================================================
-- Functions on the unified table
-- =========================================================================

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
  v_svc public.bus_services;
  v_route_id uuid;
  v_n integer;
  v_i integer := 0;
  v_stop jsonb;
  v_min_b integer;
  v_min_d integer;
  v_id uuid;
  v_src_name text;
  v_dst_name text;
  v_city uuid;
  v_prev_city uuid;
  v_seen uuid[] := '{}';
  v_loc public.locations;
  v_locname text;
  v_used boolean;
  v_idx integer := 0;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
  if not (v_bus.lifecycle_status in ('draft', 'changes_requested') or v_bus.is_legacy) then
    raise exception 'The route is locked while the bus is %', v_bus.lifecycle_status;
  end if;

  if p_source_city_id is null or p_destination_city_id is null or p_source_city_id = p_destination_city_id then
    raise exception 'Origin and destination must be two different cities';
  end if;
  if p_departure_time is null then raise exception 'Departure time is required'; end if;
  if p_duration_min is null or p_duration_min < 1 then raise exception 'Estimated journey duration is required'; end if;
  if p_operating_days is null or coalesce(array_length(p_operating_days, 1), 0) = 0 then
    raise exception 'Select at least one operating day';
  end if;
  if jsonb_typeof(p_stops) <> 'array' then raise exception 'Stops must be an array'; end if;
  v_n := jsonb_array_length(p_stops);
  if v_n < 2 or v_n > 30 then raise exception 'A route needs between 2 and 30 stops'; end if;
  if not coalesce((p_stops -> 0 ->> 'is_boarding')::boolean, false) then
    raise exception 'The origin must be a boarding point';
  end if;
  if not coalesce((p_stops -> (v_n - 1) ->> 'is_dropping')::boolean, false) then
    raise exception 'The destination must be a dropping point';
  end if;

  select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);

  if v_svc.id is not null then
    v_route_id := v_svc.route_id;
    update public.bus_routes
    set source_city_id = p_source_city_id, destination_city_id = p_destination_city_id, distance_km = p_distance_km
    where id = v_route_id;
  else
    select id into v_route_id from public.bus_routes where bus_id = p_bus_id;
    if v_route_id is null then
      insert into public.bus_routes (operator_id, bus_id, source_city_id, destination_city_id, distance_km)
      values (v_bus.operator_id, p_bus_id, p_source_city_id, p_destination_city_id, p_distance_km)
      returning id into v_route_id;
    else
      update public.bus_routes
      set source_city_id = p_source_city_id, destination_city_id = p_destination_city_id, distance_km = p_distance_km
      where id = v_route_id;
    end if;
  end if;


  -- Every stop is a central location, referenced by id. Origin / destination must be
  -- main-route locations; a stop is boarding only where pickup is enabled and dropping
  -- only where drop is enabled. A location already on this route stays valid even if
  -- it has been disabled since, so existing routes can still be re-saved.
  for v_stop in select * from jsonb_array_elements(p_stops) loop
    v_idx := v_idx + 1;
    v_city := nullif(v_stop ->> 'city_id', '')::uuid;
    if v_city is null then
      raise exception 'Stop % needs a location', v_idx;
    end if;
    select * into v_loc from public.locations where id = v_city;
    if v_loc.id is null then
      raise exception 'Stop %: location not found', v_idx;
    end if;
    v_used := exists (select 1 from public.boarding_points bp where bp.route_id = v_route_id and bp.city_id = v_city)
           or exists (select 1 from public.dropping_points dp where dp.route_id = v_route_id and dp.city_id = v_city);
    if not v_loc.is_active and not v_used then
      raise exception 'Stop %: % is disabled', v_idx, v_loc.name;
    end if;
    if (v_idx = 1 or v_idx = v_n) and not v_loc.is_main_route_enabled and not v_used then
      raise exception 'Stop %: % is not a main route location', v_idx, v_loc.name;
    end if;
    if v_idx = 1 and v_city <> p_source_city_id then
      raise exception 'The first stop must be the origin location';
    end if;
    if v_idx = v_n and v_city <> p_destination_city_id then
      raise exception 'The last stop must be the destination location';
    end if;
    if v_city = any (v_seen) then
      raise exception 'A location can appear only once on a route (stop %)', v_idx;
    end if;
    v_seen := v_seen || v_city;

    if not coalesce((v_stop ->> 'is_boarding')::boolean, false) and not coalesce((v_stop ->> 'is_dropping')::boolean, false) then
      raise exception 'Stop %: choose pickup, drop or both', v_idx;
    end if;
    if coalesce((v_stop ->> 'is_boarding')::boolean, false) and not v_loc.is_pickup_enabled and not v_used then
      raise exception 'Stop %: pickup is not enabled at %', v_idx, v_loc.name;
    end if;
    if coalesce((v_stop ->> 'is_dropping')::boolean, false) and not v_loc.is_drop_enabled and not v_used then
      raise exception 'Stop %: drop is not enabled at %', v_idx, v_loc.name;
    end if;
  end loop;

  -- Park existing active rows out of the way of the unique (route, sequence) key.
  select least(coalesce(min(sequence_no), 0), 0) into v_min_b from public.boarding_points where route_id = v_route_id;
  select least(coalesce(min(sequence_no), 0), 0) into v_min_d from public.dropping_points where route_id = v_route_id;
  update public.boarding_points set sequence_no = sequence_no + 1000000 where route_id = v_route_id and sequence_no > 0;
  update public.dropping_points set sequence_no = sequence_no + 1000000 where route_id = v_route_id and sequence_no > 0;

  for v_stop in select * from jsonb_array_elements(p_stops) loop
    v_i := v_i + 1;
    -- the stop's name is always the location's canonical name
    select name into v_locname from public.locations where id = (v_stop ->> 'city_id')::uuid;

    if coalesce((v_stop ->> 'is_boarding')::boolean, false) then
      v_id := nullif(v_stop ->> 'boarding_point_id', '')::uuid;
      if v_id is not null and exists (select 1 from public.boarding_points where id = v_id and route_id = v_route_id) then
        update public.boarding_points set
          name = v_locname, address = nullif(v_stop ->> 'address', ''),
          latitude = nullif(v_stop ->> 'latitude', '')::numeric, longitude = nullif(v_stop ->> 'longitude', '')::numeric,
          city_id = nullif(v_stop ->> 'city_id', '')::uuid,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.boarding_points (route_id, name, address, latitude, longitude, city_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, v_locname, nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric,
                nullif(v_stop ->> 'city_id', '')::uuid,
                nullif(v_stop ->> 'arrival_offset_min', '')::integer,
                nullif(v_stop ->> 'departure_offset_min', '')::integer, v_i);
      end if;
    end if;

    if coalesce((v_stop ->> 'is_dropping')::boolean, false) then
      v_id := nullif(v_stop ->> 'dropping_point_id', '')::uuid;
      if v_id is not null and exists (select 1 from public.dropping_points where id = v_id and route_id = v_route_id) then
        update public.dropping_points set
          name = v_locname, address = nullif(v_stop ->> 'address', ''),
          latitude = nullif(v_stop ->> 'latitude', '')::numeric, longitude = nullif(v_stop ->> 'longitude', '')::numeric,
          city_id = nullif(v_stop ->> 'city_id', '')::uuid,
          arrival_offset_min = nullif(v_stop ->> 'arrival_offset_min', '')::integer,
          departure_offset_min = nullif(v_stop ->> 'departure_offset_min', '')::integer,
          sequence_no = v_i, is_active = true
        where id = v_id;
      else
        insert into public.dropping_points (route_id, name, address, latitude, longitude, city_id,
                                            arrival_offset_min, departure_offset_min, sequence_no)
        values (v_route_id, v_locname, nullif(v_stop ->> 'address', ''),
                nullif(v_stop ->> 'latitude', '')::numeric, nullif(v_stop ->> 'longitude', '')::numeric,
                nullif(v_stop ->> 'city_id', '')::uuid,
                nullif(v_stop ->> 'arrival_offset_min', '')::integer,
                nullif(v_stop ->> 'departure_offset_min', '')::integer, v_i);
      end if;
    end if;
  end loop;

  -- Anything still parked was removed by the operator: deactivate with unique negative sequence numbers.
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

  select name into v_src_name from public.locations where id = p_source_city_id;
  select name into v_dst_name from public.locations where id = p_destination_city_id;

  if v_svc.id is not null then
    update public.bus_services
    set service_source_city_id = p_source_city_id, service_dest_city_id = p_destination_city_id,
        default_departure_time = p_departure_time, default_arrival_offset_minutes = p_duration_min,
        est_duration_min = p_duration_min, operating_days = p_operating_days
    where id = v_svc.id;
  else
    insert into public.bus_services (
      operator_id, route_id, bus_id, service_name, service_source_city_id, service_dest_city_id,
      default_departure_time, default_arrival_offset_minutes, est_duration_min, operating_days, status
    ) values (
      v_bus.operator_id, v_route_id, p_bus_id,
      coalesce(v_bus.name, v_bus.registration_number) || ' ' || coalesce(v_src_name, '') || ' to ' || coalesce(v_dst_name, ''),
      p_source_city_id, p_destination_city_id, p_departure_time, p_duration_min, p_duration_min, p_operating_days,
      'paused'
    );
  end if;

  perform private.write_audit(
    'bus.route_saved', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'route_id', v_route_id, 'stops', v_n)
  );
  return public.validate_bus_route(p_bus_id);
end;
$$;

revoke execute on function public.save_bus_route(uuid, uuid, uuid, numeric, time, integer, smallint[], jsonb) from public, anon;
grant execute on function public.save_bus_route(uuid, uuid, uuid, numeric, time, integer, smallint[], jsonb) to authenticated;

drop function private.trip_fare_range(uuid, uuid, uuid, uuid, uuid);
create or replace function private.trip_fare_range(
  p_trip_id uuid, p_src_city_id uuid, p_dst_city_id uuid,
  p_pickup_location_id uuid default null, p_drop_location_id uuid default null
)
returns table (min_cents integer, max_cents integer)
language sql
stable
security definer
set search_path = ''
as $$
  with trip as (
    select t.id, t.service_id, t.route_id, t.travel_date, sv.service_source_city_id as src, sv.service_dest_city_id as dst,
           (r.bus_id is not null) as wizard
    from public.bus_trips t
    join public.bus_services sv on sv.id = t.service_id
    join public.bus_routes r on r.id = t.route_id
    where t.id = p_trip_id
  ),
  pairs as (
    select b.id as b_id, d.id as d_id
    from trip tr
    join public.boarding_points b on b.route_id = tr.route_id and b.is_active
    join public.dropping_points d on d.route_id = tr.route_id and d.is_active
    where coalesce(b.city_id, tr.src) = coalesce(p_pickup_location_id, p_src_city_id)
      and coalesce(d.city_id, tr.dst) = coalesce(p_drop_location_id, p_dst_city_id)
      and (not tr.wizard or d.sequence_no > b.sequence_no)
  ),
  chosen as (
    select b_id, d_id from pairs
    union all
    select null::uuid, null::uuid where not exists (select 1 from pairs)
  ),
  seats as (
    select ts.seat_id, ts.fare_cents
    from public.trip_seats ts
    where ts.trip_id = p_trip_id
      and (ts.status = 'available'
           or not exists (select 1 from public.trip_seats x where x.trip_id = p_trip_id and x.status = 'available'))
  ),
  fares as (
    select private.resolve_seat_fare(tr.service_id, tr.travel_date, s.seat_id, c.b_id, c.d_id, s.fare_cents) as f
    from trip tr cross join chosen c cross join seats s
  )
  select min(f)::integer, max(f)::integer from fares;
$$;

revoke execute on function private.trip_fare_range(uuid, uuid, uuid, uuid, uuid) from public;
grant execute on function private.trip_fare_range(uuid, uuid, uuid, uuid, uuid) to anon, authenticated;

drop function public.search_trips(uuid, uuid, date, uuid, uuid);
create or replace function public.search_trips(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date,
  p_pickup_location_id uuid default null,
  p_drop_location_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_direct jsonb;
  v_connected jsonb;
begin
  -- Only active main locations are searchable.
  if not exists (select 1 from public.locations where id = p_source_city_id and is_active and is_main_route_enabled)
     or not exists (select 1 from public.locations where id = p_destination_city_id and is_active and is_main_route_enabled) then
    return jsonb_build_object('direct', '[]'::jsonb, 'connected', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'trip_id', t.id,
    'service_id', sv.id,
    'operator_id', o.id,
    'operator_name', o.name,
    'operator_rating', o.rating,
    'bus_id', bs.id,
    'bus_type', bs.bus_type,
    'amenities', bs.amenities,
    'departure_at', t.departure_at,
    'arrival_at', t.arrival_at,
    'available_seats', t.available_seats,
    'min_fare_cents', fr.min_cents,
    'max_fare_cents', fr.max_cents,
    'currency_code', t.currency_code
  ) order by t.departure_at), '[]'::jsonb)
  into v_direct
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  join public.operators o on o.id = t.operator_id
  join public.buses bs on bs.id = t.bus_id
  join public.bus_routes r on r.id = t.route_id
  cross join lateral private.trip_fare_range(t.id, p_source_city_id, p_destination_city_id, p_pickup_location_id, p_drop_location_id) fr
  where t.travel_date = p_travel_date
    and t.status = 'scheduled'
    and private.trip_is_open_for_booking(t.id)
    and private.is_bus_bookable(t.bus_id)
    and (
      (p_pickup_location_id is null and p_drop_location_id is null
       and sv.service_source_city_id = p_source_city_id and sv.service_dest_city_id = p_destination_city_id)
      or exists (
        select 1
        from public.boarding_points bs
        join public.dropping_points dd on dd.route_id = bs.route_id and dd.sequence_no > bs.sequence_no
        where bs.route_id = t.route_id and bs.is_active and dd.is_active
          and bs.city_id = p_source_city_id and dd.city_id = p_destination_city_id
          -- an exact pickup / drop location must be a stop the bus serves between the searched ends
          and (p_pickup_location_id is null or exists (
                select 1 from public.boarding_points bp
                where bp.route_id = t.route_id and bp.is_active and bp.city_id = p_pickup_location_id
                  and bp.sequence_no >= bs.sequence_no and bp.sequence_no < dd.sequence_no))
          and (p_drop_location_id is null or exists (
                select 1 from public.dropping_points dp
                where dp.route_id = t.route_id and dp.is_active and dp.city_id = p_drop_location_id
                  and dp.sequence_no > bs.sequence_no and dp.sequence_no <= dd.sequence_no))
      )
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'transfer_city_id', s1.service_dest_city_id,
    'leg1', jsonb_build_object(
      'trip_id', t1.id, 'service_id', s1.id, 'operator_id', o1.id, 'operator_name', o1.name,
      'departure_at', t1.departure_at, 'arrival_at', t1.arrival_at,
      'min_fare_cents', f1.min_cents, 'available_seats', t1.available_seats
    ),
    'leg2', jsonb_build_object(
      'trip_id', t2.id, 'service_id', s2.id, 'operator_id', o2.id, 'operator_name', o2.name,
      'departure_at', t2.departure_at, 'arrival_at', t2.arrival_at,
      'min_fare_cents', f2.min_cents, 'available_seats', t2.available_seats
    ),
    'total_min_fare_cents', coalesce(f1.min_cents, 0) + coalesce(f2.min_cents, 0)
  ) order by t1.departure_at), '[]'::jsonb)
  into v_connected
  from public.bus_services s1
  join public.bus_trips t1 on t1.service_id = s1.id
    and t1.travel_date = p_travel_date
    and t1.status = 'scheduled'
  join public.operators o1 on o1.id = t1.operator_id
  join public.bus_services s2 on s2.service_source_city_id = s1.service_dest_city_id
    and s2.service_dest_city_id = p_destination_city_id
  join public.bus_trips t2 on t2.service_id = s2.id
    and t2.status = 'scheduled'
    and t2.travel_date between p_travel_date and p_travel_date + 1
  join public.operators o2 on o2.id = t2.operator_id
  cross join lateral private.trip_fare_range(t1.id, s1.service_source_city_id, s1.service_dest_city_id) f1
  cross join lateral private.trip_fare_range(t2.id, s2.service_source_city_id, s2.service_dest_city_id) f2
  where s1.service_source_city_id = p_source_city_id
    and private.is_bus_bookable(t1.bus_id)
    and private.is_bus_bookable(t2.bus_id)
    and private.trip_is_open_for_booking(t1.id)
    and private.trip_is_open_for_booking(t2.id)
    and p_pickup_location_id is null and p_drop_location_id is null
    and t2.departure_at >= t1.arrival_at + interval '15 minutes'
    and t2.departure_at <= t1.arrival_at + interval '6 hours';

  return jsonb_build_object('direct', v_direct, 'connected', v_connected);
end;
$$;

revoke execute on function public.search_trips(uuid, uuid, date, uuid, uuid) from public;
grant execute on function public.search_trips(uuid, uuid, date, uuid, uuid) to anon, authenticated;

-- Pickup / drop locations the running buses on a journey actually serve: stops of
-- matching services between the searched origin and destination, filtered live by
-- the location's pickup / drop flag and active status. Disabled locations vanish here.
create or replace function public.get_journey_points(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with trips as (
    select distinct t.route_id
    from public.bus_trips t
    where t.status = 'scheduled'
      and (p_travel_date is null or t.travel_date = p_travel_date)
      and private.is_bus_bookable(t.bus_id)
  ),
  spans as (
    select tr.route_id, bs.sequence_no as s_seq, dd.sequence_no as d_seq
    from trips tr
    join public.boarding_points bs on bs.route_id = tr.route_id and bs.is_active and bs.city_id = p_source_city_id
    join public.dropping_points dd on dd.route_id = tr.route_id and dd.is_active and dd.city_id = p_destination_city_id
                                   and dd.sequence_no > bs.sequence_no
  ),
  pick as (
    select distinct b.city_id as location_id
    from spans sp
    join public.boarding_points b on b.route_id = sp.route_id and b.is_active and b.sequence_no >= sp.s_seq and b.sequence_no < sp.d_seq
  ),
  drp as (
    select distinct d.city_id as location_id
    from spans sp
    join public.dropping_points d on d.route_id = sp.route_id and d.is_active and d.sequence_no > sp.s_seq and d.sequence_no <= sp.d_seq
  )
  select jsonb_build_object(
    'pickup', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'location_code', l.location_code, 'name', l.name, 'port_name', l.port_name)
                       order by l.pickup_order, l.name)
      from public.locations l
      where l.is_active and l.is_pickup_enabled and l.id in (select location_id from pick)), '[]'::jsonb),
    'drop', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.id, 'location_code', l.location_code, 'name', l.name, 'port_name', l.port_name)
                       order by l.drop_order, l.name)
      from public.locations l
      where l.is_active and l.is_drop_enabled and l.id in (select location_id from drp)), '[]'::jsonb)
  );
$$;

revoke execute on function public.get_journey_points(uuid, uuid, date) from public;
grant execute on function public.get_journey_points(uuid, uuid, date) to anon, authenticated;

drop function public.search_cities(text, integer);
create or replace function public.search_cities(p_query text default '', p_limit integer default 10)
returns setof public.locations
language sql
stable
security definer
set search_path = ''
as $$
  select l.*
  from public.locations l
  where l.is_active and l.is_main_route_enabled
    and (coalesce(p_query, '') = '' or l.normalized_name like '%' || private.normalize_location_name(p_query) || '%' or upper(l.location_code) = upper(p_query))
  order by l.main_route_order, l.name
  limit greatest(p_limit, 1);
$$;

grant execute on function public.search_cities(text, integer) to anon, authenticated;
