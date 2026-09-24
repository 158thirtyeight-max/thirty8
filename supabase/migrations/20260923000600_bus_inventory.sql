-- =========================================================================
-- Bus inventory: trip_seats (the seat truth table), seat_holds, fare_rules
-- =========================================================================

create type public.trip_seat_status as enum ('available', 'held', 'booked', 'blocked', 'cancelled', 'boarded');
create type public.seat_hold_status as enum ('active', 'confirmed', 'released', 'expired');

create table public.fare_rules (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.bus_services (id) on delete cascade,
  seat_type public.seat_type not null,
  base_fare_cents integer not null check (base_fare_cents >= 0),
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default now()
);

create index fare_rules_service_id_idx on public.fare_rules (service_id);

create table public.seat_holds (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.bus_trips (id) on delete cascade,
  user_id uuid not null references public.profiles (id),
  hold_token uuid not null default gen_random_uuid() unique,
  status public.seat_hold_status not null default 'active',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index seat_holds_trip_id_idx on public.seat_holds (trip_id);
create index seat_holds_user_id_idx on public.seat_holds (user_id);
create index seat_holds_active_expiry_idx on public.seat_holds (expires_at) where status = 'active';

-- The seat truth table for a trip. One row per (trip, seat). This is what
-- prevents double-booking: the UNIQUE constraint plus SELECT ... FOR UPDATE
-- in create_seat_hold() (next migration) is the entire concurrency guarantee.
create table public.trip_seats (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.bus_trips (id) on delete cascade,
  seat_id uuid not null references public.seats (id),
  status public.trip_seat_status not null default 'available',
  fare_cents integer not null default 0 check (fare_cents >= 0),
  hold_id uuid references public.seat_holds (id) on delete set null,
  updated_at timestamptz not null default now(),
  unique (trip_id, seat_id)
);

create trigger set_updated_at
  before update on public.trip_seats
  for each row execute function private.set_updated_at();

create index trip_seats_trip_id_idx on public.trip_seats (trip_id);
create index trip_seats_hold_id_idx on public.trip_seats (hold_id) where hold_id is not null;
create index trip_seats_status_idx on public.trip_seats (trip_id, status);

-- Auto-populate trip_seats from the bus's active layout whenever a trip is
-- created, pricing each seat from the most specific matching fare_rule
-- (falling back to the trip's min_fare_cents, then 0).
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
    and bl.is_active;

  update public.bus_trips
  set available_seats = (select count(*) from public.trip_seats where trip_id = new.id)
  where id = new.id;

  return new;
end;
$$;

create trigger generate_trip_seats
  after insert on public.bus_trips
  for each row execute function private.generate_trip_seats();

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.fare_rules enable row level security;
alter table public.seat_holds enable row level security;
alter table public.trip_seats enable row level security;

create policy fare_rules_select_public on public.fare_rules for select to anon, authenticated using (true);
create policy fare_rules_operator_manage on public.fare_rules for all to authenticated
  using (exists (select 1 from public.bus_services s where s.id = fare_rules.service_id and private.is_operator_staff(s.operator_id)))
  with check (exists (select 1 from public.bus_services s where s.id = fare_rules.service_id and private.is_operator_staff(s.operator_id)));
create policy fare_rules_admin_all on public.fare_rules for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- Seat map is public (needed to render availability before login); trip_seats
-- has NO insert/update/delete policy for authenticated/anon at all — every
-- mutation goes through SECURITY DEFINER functions (create_seat_hold,
-- confirm_booking_after_payment, etc., next migration) or the operator block
-- function, so the concurrency guarantees can never be bypassed by a client.
create policy trip_seats_select_public on public.trip_seats for select to anon, authenticated using (true);
create policy trip_seats_admin_all on public.trip_seats for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy seat_holds_select_own on public.seat_holds
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or exists (select 1 from public.bus_trips t where t.id = seat_holds.trip_id and private.is_operator_staff(t.operator_id))
    or private.is_platform_admin()
  );

create policy seat_holds_admin_all on public.seat_holds
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
-- No direct insert/update/delete for regular users — only via create_seat_hold /
-- release_seat_hold SECURITY DEFINER functions in the next migration.
