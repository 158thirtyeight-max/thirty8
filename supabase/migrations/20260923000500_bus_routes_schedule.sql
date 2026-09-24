-- =========================================================================
-- Bus routes & schedule: routes, boarding/dropping points, services, trips
-- =========================================================================

create type public.bus_service_status as enum ('active', 'paused', 'retired');
create type public.bus_trip_status as enum ('scheduled', 'boarding', 'departed', 'arrived', 'cancelled');

-- A route is the full corridor an operator runs (e.g. Port Blair -> Diglipur).
create table public.bus_routes (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id) on delete cascade,
  source_city_id uuid not null references public.cities (id),
  destination_city_id uuid not null references public.cities (id),
  distance_km numeric(8, 2),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (operator_id, source_city_id, destination_city_id)
);

create index bus_routes_operator_id_idx on public.bus_routes (operator_id);
create index bus_routes_source_dest_idx on public.bus_routes (source_city_id, destination_city_id);

-- Boarding/dropping points along a route corridor, in travel sequence.
create table public.boarding_points (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.bus_routes (id) on delete cascade,
  name text not null,
  address text,
  latitude numeric(10, 7),
  longitude numeric(10, 7),
  sequence_no integer not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (route_id, sequence_no)
);

create index boarding_points_route_id_idx on public.boarding_points (route_id);

create table public.dropping_points (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.bus_routes (id) on delete cascade,
  name text not null,
  address text,
  latitude numeric(10, 7),
  longitude numeric(10, 7),
  sequence_no integer not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (route_id, sequence_no)
);

create index dropping_points_route_id_idx on public.dropping_points (route_id);

-- A service is an operator's specific offering on a route, covering one segment
-- (service_source_city_id -> service_dest_city_id) which may be the full route
-- or a sub-segment of it (e.g. "Port Blair to Rangat Express").
create table public.bus_services (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id) on delete cascade,
  route_id uuid not null references public.bus_routes (id) on delete cascade,
  bus_id uuid not null references public.buses (id),
  service_code text,
  service_name text not null,
  service_source_city_id uuid not null references public.cities (id),
  service_dest_city_id uuid not null references public.cities (id),
  default_departure_time time not null,
  default_arrival_offset_minutes integer not null check (default_arrival_offset_minutes > 0),
  status public.bus_service_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.bus_services
  for each row execute function private.set_updated_at();

create index bus_services_operator_id_idx on public.bus_services (operator_id);
create index bus_services_route_id_idx on public.bus_services (route_id);
create index bus_services_segment_idx on public.bus_services (service_source_city_id, service_dest_city_id);

-- A trip is a concrete, dated instance of a service.
create table public.bus_trips (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.bus_services (id) on delete cascade,
  operator_id uuid not null references public.operators (id) on delete cascade,
  route_id uuid not null references public.bus_routes (id),
  bus_id uuid not null references public.buses (id),
  travel_date date not null,
  departure_at timestamptz not null,
  arrival_at timestamptz,
  currency_code text not null default 'INR',
  min_fare_cents integer,
  max_fare_cents integer,
  available_seats integer not null default 0,
  live_tracking_enabled boolean not null default false,
  status public.bus_trip_status not null default 'scheduled',
  booking_open_at timestamptz not null default now(),
  booking_close_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (service_id, travel_date)
);

create trigger set_updated_at
  before update on public.bus_trips
  for each row execute function private.set_updated_at();

create index bus_trips_operator_id_idx on public.bus_trips (operator_id);
create index bus_trips_search_idx on public.bus_trips (route_id, travel_date, status);
create index bus_trips_service_id_idx on public.bus_trips (service_id);

-- =========================================================================
-- RLS — all route/schedule reference data is publicly readable (needed for
-- unauthenticated search); mutation is restricted to the owning operator.
-- =========================================================================

alter table public.bus_routes enable row level security;
alter table public.boarding_points enable row level security;
alter table public.dropping_points enable row level security;
alter table public.bus_services enable row level security;
alter table public.bus_trips enable row level security;

create policy bus_routes_select_public on public.bus_routes for select to anon, authenticated using (true);
create policy bus_routes_operator_manage on public.bus_routes for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy bus_routes_admin_all on public.bus_routes for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy boarding_points_select_public on public.boarding_points for select to anon, authenticated using (true);
create policy boarding_points_operator_manage on public.boarding_points for all to authenticated
  using (exists (select 1 from public.bus_routes r where r.id = boarding_points.route_id and private.is_operator_staff(r.operator_id)))
  with check (exists (select 1 from public.bus_routes r where r.id = boarding_points.route_id and private.is_operator_staff(r.operator_id)));
create policy boarding_points_admin_all on public.boarding_points for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy dropping_points_select_public on public.dropping_points for select to anon, authenticated using (true);
create policy dropping_points_operator_manage on public.dropping_points for all to authenticated
  using (exists (select 1 from public.bus_routes r where r.id = dropping_points.route_id and private.is_operator_staff(r.operator_id)))
  with check (exists (select 1 from public.bus_routes r where r.id = dropping_points.route_id and private.is_operator_staff(r.operator_id)));
create policy dropping_points_admin_all on public.dropping_points for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy bus_services_select_public on public.bus_services for select to anon, authenticated using (true);
create policy bus_services_operator_manage on public.bus_services for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy bus_services_admin_all on public.bus_services for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy bus_trips_select_public on public.bus_trips for select to anon, authenticated using (true);
create policy bus_trips_operator_manage on public.bus_trips for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy bus_trips_admin_all on public.bus_trips for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());
