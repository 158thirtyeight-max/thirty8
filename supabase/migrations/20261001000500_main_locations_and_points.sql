-- =========================================================================
-- Centralised location management.
--
--   main_locations      the approved major route locations. Physically this is
--                       public.cities (already referenced by routes, services,
--                       stops and search), extended with slug / display_order /
--                       updated_at and exposed through an updatable view so no
--                       existing reference changes.
--   pickup_drop_points  master list of detailed pickup / drop points, each
--                       belonging to one main location. (The existing
--                       boarding_points / dropping_points are per-route rows
--                       that bookings and fares reference, so they stay as the
--                       route instance of a point and link here through
--                       master_point_id.)
--   route_stops /       read-only views over the per-route stop rows:
--   service_stops       ordered main locations of a route, and the exact master
--                       points a service serves.
--
-- Everything is soft-deactivated, never deleted. Coordinates are nullable and
-- live only here; live GPS belongs in separate tracking tables.
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. Main locations (extend cities)
-- ---------------------------------------------------------------------
alter table public.cities
  add column slug text,
  add column display_order integer,
  add column updated_at timestamptz not null default now();

create unique index cities_slug_uniq on public.cities (slug) where slug is not null;
create index cities_display_order_idx on public.cities (display_order) where display_order is not null;

-- New locations get a slug, the next display order and the default country
-- unless the caller supplies them. Rows with a null display_order are legacy
-- (not part of the approved list) and are hidden from main_locations.
create or replace function private.cities_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.slug is null then
    new.slug := trim(both '-' from lower(regexp_replace(new.name, '[^a-zA-Z0-9]+', '-', 'g')));
  end if;
  if new.display_order is null then
    select coalesce(max(display_order), 0) + 1 into new.display_order from public.cities;
  end if;
  if new.country_id is null then
    select id into new.country_id from public.countries where code = 'IND';
  end if;
  return new;
end;
$$;

revoke execute on function private.cities_before_insert() from public, anon, authenticated;

create trigger cities_before_insert before insert on public.cities
  for each row execute function private.cities_before_insert();
create trigger set_updated_at before update on public.cities
  for each row execute function private.set_updated_at();

-- Idempotent seed of the ten approved locations, in display order. An existing
-- row is adopted (matched by slug, else by its legacy name) and never
-- overwritten once it has a slug, so re-running keeps admin edits.
do $$
declare
  r record;
  v_id uuid;
  v_country uuid := (select id from public.countries where code = 'IND');
begin
  for r in
    select * from (values
      (1,  'sri-vijaya-puram',   'SRI VIJAYA PURAM',     array['Sri Vijaya Puram (Port Blair)', 'Port Blair']),
      (2,  'bambooflat',         'BAMBOOFLAT',           array[]::text[]),
      (3,  'baratang',           'BARATANG',             array['Baratang']),
      (4,  'middle-strait',      'MIDDLE STRAIT',        array[]::text[]),
      (5,  'kadamtala',          'KADAMTALA',            array['Kadamtala']),
      (6,  'rangat',             'RANGAT',               array['Rangat']),
      (7,  'nimbudera',          'NIMBUDERA',            array[]::text[]),
      (8,  'mayabunder',         'MAYABUNDER',           array['Mayabunder']),
      (9,  'diglipur',           'DIGLIPUR',             array['Diglipur']),
      (10, 'aerial-bay-diglipur', 'AERIAL BAY- DIGLIPUR', array[]::text[])
    ) as v(ord, slug, name, legacy)
  loop
    select id into v_id from public.cities where slug = r.slug;
    if v_id is not null then
      continue;
    end if;
    select id into v_id from public.cities
    where slug is null and name = any (r.legacy)
    order by created_at limit 1;
    if v_id is null then
      insert into public.cities (country_id, name, state, slug, display_order, is_active)
      values (v_country, r.name, 'Andaman and Nicobar Islands', r.slug, r.ord, true);
    else
      update public.cities
      set name = r.name, slug = r.slug, display_order = r.ord, is_active = true
      where id = v_id;
    end if;
  end loop;
end $$;

-- Locations outside the approved list stay in the table (existing references
-- remain valid) but are inactive and not part of main_locations.
update public.cities set is_active = false where display_order is null and is_active;

create view public.main_locations with (security_invoker = true) as
  select id, name, slug, display_order, is_active, state, latitude, longitude, country_id, created_at, updated_at
  from public.cities
  where display_order is not null;

grant select on public.main_locations to anon, authenticated;
grant insert, update on public.main_locations to authenticated;

-- ---------------------------------------------------------------------
-- 2. Master pickup / drop points
-- ---------------------------------------------------------------------
create table public.pickup_drop_points (
  id uuid primary key default gen_random_uuid(),
  main_location_id uuid not null references public.cities (id),
  name text not null check (btrim(name) <> ''),
  landmark text,
  address text,
  latitude numeric(10, 7) check (latitude is null or latitude between -90 and 90),
  longitude numeric(10, 7) check (longitude is null or longitude between -180 and 180),
  is_pickup_allowed boolean not null default true,
  is_drop_allowed boolean not null default true,
  is_active boolean not null default true,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint pickup_drop_points_coords_pair check ((latitude is null) = (longitude is null))
);

create unique index pickup_drop_points_name_uniq on public.pickup_drop_points (main_location_id, lower(btrim(name)));
create index pickup_drop_points_location_idx on public.pickup_drop_points (main_location_id, display_order);

create trigger set_updated_at before update on public.pickup_drop_points
  for each row execute function private.set_updated_at();

alter table public.pickup_drop_points enable row level security;

-- Logged-out and customer reads see active points; admins see everything and
-- are the only writers. Operators cannot modify master data.
create policy pickup_drop_points_select_anon on public.pickup_drop_points
  for select to anon using (is_active);
create policy pickup_drop_points_select_auth on public.pickup_drop_points
  for select to authenticated using (is_active or private.is_platform_admin());
create policy pickup_drop_points_admin_write on public.pickup_drop_points
  for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

grant select on public.pickup_drop_points to anon, authenticated;
grant insert, update, delete on public.pickup_drop_points to authenticated;

-- Route-level points remember which master point they are an instance of.
alter table public.boarding_points add column master_point_id uuid references public.pickup_drop_points (id);
alter table public.dropping_points add column master_point_id uuid references public.pickup_drop_points (id);
create index boarding_points_master_idx on public.boarding_points (master_point_id) where master_point_id is not null;
create index dropping_points_master_idx on public.dropping_points (master_point_id) where master_point_id is not null;

-- ---------------------------------------------------------------------
-- 3. route_stops / service_stops (views over the per-route stop rows)
-- ---------------------------------------------------------------------
-- Ordered main locations of a route.
create view public.route_stops with (security_invoker = true) as
  with s as (
    select route_id, city_id, sequence_no, true as pickup, false as drop_ from public.boarding_points
      where is_active and city_id is not null
    union all
    select route_id, city_id, sequence_no, false, true from public.dropping_points
      where is_active and city_id is not null
  )
  select route_id,
         city_id as main_location_id,
         (row_number() over (partition by route_id order by min(sequence_no)))::integer as stop_order,
         bool_or(pickup) as is_pickup_allowed,
         bool_or(drop_) as is_drop_allowed
  from s
  group by route_id, city_id;

-- The exact master points a service serves, with enabled flags and clock times.
create view public.service_stops with (security_invoker = true) as
  with s as (
    select route_id, master_point_id, sequence_no, true as pickup, false as drop_,
           departure_offset_min as pickup_off, null::integer as drop_off
      from public.boarding_points where is_active and master_point_id is not null
    union all
    select route_id, master_point_id, sequence_no, false, true, null, arrival_offset_min
      from public.dropping_points where is_active and master_point_id is not null
  )
  select sv.id as service_id,
         s.master_point_id as point_id,
         min(s.sequence_no) as stop_order,
         bool_or(s.pickup) as pickup_enabled,
         bool_or(s.drop_) as drop_enabled,
         (sv.default_departure_time + make_interval(mins => min(s.pickup_off)))::time as pickup_time,
         (sv.default_departure_time + make_interval(mins => min(s.drop_off)))::time as drop_time
  from s
  join public.bus_services sv on sv.route_id = s.route_id
  group by sv.id, sv.default_departure_time, s.master_point_id;

grant select on public.route_stops, public.service_stops to anon, authenticated;
