-- =========================================================================
-- Cargo fleet: vehicle types (reference data), operator vehicles
-- =========================================================================

create table public.cargo_vehicle_types (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  max_weight_kg numeric(10, 2) not null,
  max_volume_cbm numeric(10, 3) not null,
  created_at timestamptz not null default now()
);

create table public.cargo_vehicles (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id) on delete cascade,
  vehicle_type_id uuid not null references public.cargo_vehicle_types (id),
  registration_number text not null,
  status public.bus_status not null default 'active',
  photo_urls text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operator_id, registration_number)
);

create trigger set_updated_at
  before update on public.cargo_vehicles
  for each row execute function private.set_updated_at();

create index cargo_vehicles_operator_id_idx on public.cargo_vehicles (operator_id);

alter table public.cargo_vehicle_types enable row level security;
alter table public.cargo_vehicles enable row level security;

create policy cargo_vehicle_types_select_public on public.cargo_vehicle_types for select to anon, authenticated using (true);
create policy cargo_vehicle_types_admin_write on public.cargo_vehicle_types for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy cargo_vehicles_select_public on public.cargo_vehicles for select to anon, authenticated
  using (status = 'active' or private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy cargo_vehicles_operator_manage on public.cargo_vehicles for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy cargo_vehicles_admin_all on public.cargo_vehicles for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());
