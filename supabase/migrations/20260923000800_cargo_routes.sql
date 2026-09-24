-- =========================================================================
-- Cargo routes, hubs, pricing rules, cargo type reference data
-- =========================================================================

create table public.cargo_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  max_weight_kg numeric(10, 2) not null,
  requires_special_handling boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.cargo_routes (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id) on delete cascade,
  source_city_id uuid not null references public.cities (id),
  destination_city_id uuid not null references public.cities (id),
  distance_km numeric(8, 2),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (operator_id, source_city_id, destination_city_id)
);

create index cargo_routes_operator_id_idx on public.cargo_routes (operator_id);
create index cargo_routes_source_dest_idx on public.cargo_routes (source_city_id, destination_city_id);

create table public.cargo_hub (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid references public.operators (id) on delete cascade,
  city_id uuid not null references public.cities (id),
  name text not null,
  address text,
  latitude numeric(10, 7),
  longitude numeric(10, 7),
  operating_hours text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index cargo_hub_city_id_idx on public.cargo_hub (city_id);
create index cargo_hub_operator_id_idx on public.cargo_hub (operator_id) where operator_id is not null;

create table public.cargo_pricing_rules (
  id uuid primary key default gen_random_uuid(),
  route_id uuid not null references public.cargo_routes (id) on delete cascade,
  vehicle_type_id uuid not null references public.cargo_vehicle_types (id),
  cargo_type_id uuid not null references public.cargo_types (id),
  base_fare_cents integer not null check (base_fare_cents >= 0),
  per_km_cents integer not null default 0 check (per_km_cents >= 0),
  per_kg_cents integer not null default 0 check (per_kg_cents >= 0),
  surcharge_cents integer not null default 0 check (surcharge_cents >= 0),
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default now(),
  unique (route_id, vehicle_type_id, cargo_type_id, effective_from)
);

create index cargo_pricing_rules_route_id_idx on public.cargo_pricing_rules (route_id);

-- =========================================================================
-- RLS — routes/hubs/pricing are public-readable (needed for the shipment
-- quote flow before login); mutation is restricted to the owning operator.
-- A hub with operator_id null is a shared/platform hub, admin-managed only.
-- =========================================================================

alter table public.cargo_types enable row level security;
alter table public.cargo_routes enable row level security;
alter table public.cargo_hub enable row level security;
alter table public.cargo_pricing_rules enable row level security;

create policy cargo_types_select_public on public.cargo_types for select to anon, authenticated using (true);
create policy cargo_types_admin_write on public.cargo_types for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy cargo_routes_select_public on public.cargo_routes for select to anon, authenticated using (true);
create policy cargo_routes_operator_manage on public.cargo_routes for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy cargo_routes_admin_all on public.cargo_routes for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy cargo_hub_select_public on public.cargo_hub for select to anon, authenticated using (true);
create policy cargo_hub_operator_manage on public.cargo_hub for all to authenticated
  using (operator_id is not null and private.is_operator_staff(operator_id))
  with check (operator_id is not null and private.is_operator_staff(operator_id));
create policy cargo_hub_admin_all on public.cargo_hub for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy cargo_pricing_rules_select_public on public.cargo_pricing_rules for select to anon, authenticated using (true);
create policy cargo_pricing_rules_operator_manage on public.cargo_pricing_rules for all to authenticated
  using (exists (select 1 from public.cargo_routes r where r.id = cargo_pricing_rules.route_id and private.is_operator_staff(r.operator_id)))
  with check (exists (select 1 from public.cargo_routes r where r.id = cargo_pricing_rules.route_id and private.is_operator_staff(r.operator_id)));
create policy cargo_pricing_rules_admin_all on public.cargo_pricing_rules for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());
