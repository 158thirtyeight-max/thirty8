-- =========================================================================
-- Geography: countries, cities (search reference data — public read)
-- =========================================================================

create table public.countries (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table public.cities (
  id uuid primary key default gen_random_uuid(),
  country_id uuid not null references public.countries (id),
  name text not null,
  state text,
  latitude numeric(10, 7),
  longitude numeric(10, 7),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index cities_country_id_idx on public.cities (country_id);
create index cities_name_trgm_idx on public.cities using gin (name extensions.gin_trgm_ops);
create index cities_active_idx on public.cities (is_active) where is_active;

alter table public.countries enable row level security;
alter table public.cities enable row level security;

create policy countries_select_public on public.countries
  for select to anon, authenticated
  using (true);

create policy countries_admin_write on public.countries
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy cities_select_public on public.cities
  for select to anon, authenticated
  using (true);

create policy cities_admin_write on public.cities
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
