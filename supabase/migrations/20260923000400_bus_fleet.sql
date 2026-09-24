-- =========================================================================
-- Bus fleet: buses, seat layouts, seats
-- =========================================================================

create type public.bus_status as enum ('active', 'maintenance', 'inactive');
create type public.seat_type as enum ('seater', 'sleeper');
create type public.gender_restriction as enum ('none', 'female');

create table public.buses (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id) on delete cascade,
  registration_number text not null,
  bus_type text not null check (bus_type in ('ac_seater', 'ac_sleeper', 'non_ac_seater', 'non_ac_sleeper', 'ac_semi_sleeper', 'non_ac_semi_sleeper')),
  total_seats integer not null check (total_seats > 0),
  amenities text[] not null default '{}',
  photo_urls text[] not null default '{}',
  status public.bus_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operator_id, registration_number)
);

create trigger set_updated_at
  before update on public.buses
  for each row execute function private.set_updated_at();

create index buses_operator_id_idx on public.buses (operator_id);

create table public.bus_layouts (
  id uuid primary key default gen_random_uuid(),
  bus_id uuid not null references public.buses (id) on delete cascade,
  name text not null default 'Default layout',
  deck_count smallint not null default 1 check (deck_count in (1, 2)),
  layout_json jsonb not null default '{}'::jsonb,
  version integer not null default 1,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create index bus_layouts_bus_id_idx on public.bus_layouts (bus_id);
create unique index bus_layouts_one_active_per_bus_idx on public.bus_layouts (bus_id) where is_active;

create table public.seats (
  id uuid primary key default gen_random_uuid(),
  bus_layout_id uuid not null references public.bus_layouts (id) on delete cascade,
  seat_code text not null,
  deck smallint not null default 1 check (deck in (1, 2)),
  row_no smallint,
  col_no smallint,
  seat_type public.seat_type not null default 'seater',
  gender_restriction public.gender_restriction not null default 'none',
  created_at timestamptz not null default now(),
  unique (bus_layout_id, seat_code)
);

create index seats_bus_layout_id_idx on public.seats (bus_layout_id);

alter table public.buses enable row level security;
alter table public.bus_layouts enable row level security;
alter table public.seats enable row level security;

create policy buses_select_public on public.buses
  for select to anon, authenticated
  using (status = 'active' or private.is_operator_staff(operator_id) or private.is_platform_admin());

create policy buses_operator_manage on public.buses
  for all to authenticated
  using (private.is_operator_staff(operator_id))
  with check (private.is_operator_staff(operator_id));

create policy buses_admin_all on public.buses
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy bus_layouts_select_public on public.bus_layouts
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.buses b
      where b.id = bus_layouts.bus_id
        and (b.status = 'active' or private.is_operator_staff(b.operator_id) or private.is_platform_admin())
    )
  );

create policy bus_layouts_operator_manage on public.bus_layouts
  for all to authenticated
  using (exists (select 1 from public.buses b where b.id = bus_layouts.bus_id and private.is_operator_staff(b.operator_id)))
  with check (exists (select 1 from public.buses b where b.id = bus_layouts.bus_id and private.is_operator_staff(b.operator_id)));

create policy bus_layouts_admin_all on public.bus_layouts
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy seats_select_public on public.seats
  for select to anon, authenticated
  using (true);

create policy seats_operator_manage on public.seats
  for all to authenticated
  using (
    exists (
      select 1 from public.bus_layouts bl
      join public.buses b on b.id = bl.bus_id
      where bl.id = seats.bus_layout_id and private.is_operator_staff(b.operator_id)
    )
  )
  with check (
    exists (
      select 1 from public.bus_layouts bl
      join public.buses b on b.id = bl.bus_id
      where bl.id = seats.bus_layout_id and private.is_operator_staff(b.operator_id)
    )
  );

create policy seats_admin_all on public.seats
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
