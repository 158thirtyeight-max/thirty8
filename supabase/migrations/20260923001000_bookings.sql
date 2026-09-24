-- =========================================================================
-- Bus bookings: passengers, bookings, booking_items, status history
-- =========================================================================

create type public.booking_status as enum (
  'draft', 'hold_created', 'payment_pending', 'confirmed',
  'cancelled', 'completed', 'expired', 'failed'
);
create type public.passenger_gender as enum ('male', 'female', 'other');

-- A customer's reusable passenger list ("saved passengers" quick-select).
create table public.saved_passengers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  full_name text not null,
  age smallint not null check (age > 0 and age < 130),
  gender public.passenger_gender not null,
  phone text,
  created_at timestamptz not null default now()
);

create index saved_passengers_profile_id_idx on public.saved_passengers (profile_id);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  booking_reference text not null unique,
  customer_id uuid not null references public.profiles (id),
  contact_email text,
  contact_phone text,
  status public.booking_status not null default 'draft',
  total_fare_cents integer not null default 0 check (total_fare_cents >= 0),
  currency_code text not null default 'INR',
  coupon_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.bookings
  for each row execute function private.set_updated_at();

create index bookings_customer_id_idx on public.bookings (customer_id);
create index bookings_status_idx on public.bookings (status);

-- One passenger per booked seat (booking_items.passenger_id -> here).
create table public.passengers (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  full_name text not null,
  age smallint not null check (age > 0 and age < 130),
  gender public.passenger_gender not null,
  phone text,
  created_at timestamptz not null default now()
);

create index passengers_booking_id_idx on public.passengers (booking_id);

create table public.booking_items (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  trip_id uuid not null references public.bus_trips (id),
  trip_seat_id uuid not null references public.trip_seats (id),
  passenger_id uuid references public.passengers (id),
  boarding_point_id uuid not null references public.boarding_points (id),
  dropping_point_id uuid not null references public.dropping_points (id),
  fare_cents integer not null check (fare_cents >= 0),
  status public.booking_status not null default 'draft',
  created_at timestamptz not null default now(),
  unique (booking_id, trip_seat_id)
);

create index booking_items_booking_id_idx on public.booking_items (booking_id);
create index booking_items_trip_id_idx on public.booking_items (trip_id);
create index booking_items_trip_seat_id_idx on public.booking_items (trip_seat_id);

create table public.booking_status_history (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  from_status public.booking_status,
  to_status public.booking_status not null,
  changed_by uuid references public.profiles (id),
  note text,
  created_at timestamptz not null default now()
);

create index booking_status_history_booking_id_idx on public.booking_status_history (booking_id);

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.saved_passengers enable row level security;
alter table public.bookings enable row level security;
alter table public.passengers enable row level security;
alter table public.booking_items enable row level security;
alter table public.booking_status_history enable row level security;

create policy saved_passengers_owner_all on public.saved_passengers
  for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

create policy bookings_select_own on public.bookings
  for select to authenticated
  using (
    customer_id = (select auth.uid())
    or exists (
      select 1 from public.booking_items bi
      join public.bus_trips t on t.id = bi.trip_id
      where bi.booking_id = bookings.id and private.is_operator_staff(t.operator_id)
    )
    or private.is_platform_admin()
  );

create policy bookings_admin_all on public.bookings
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
-- No direct insert/update for customers/operators: bookings are created and
-- transitioned exclusively through create_booking / cancel_booking /
-- confirm_booking_after_payment SECURITY DEFINER functions (next migration),
-- so fare totals and state transitions can never be forged by a client.

create policy passengers_select_via_booking on public.passengers
  for select to authenticated
  using (
    exists (
      select 1 from public.bookings b
      where b.id = passengers.booking_id and b.customer_id = (select auth.uid())
    )
    or exists (
      select 1 from public.booking_items bi
      join public.bus_trips t on t.id = bi.trip_id
      where bi.passenger_id = passengers.id and private.is_operator_staff(t.operator_id)
    )
    or private.is_platform_admin()
  );

create policy passengers_admin_all on public.passengers
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy booking_items_select on public.booking_items
  for select to authenticated
  using (
    exists (select 1 from public.bookings b where b.id = booking_items.booking_id and b.customer_id = (select auth.uid()))
    or exists (select 1 from public.bus_trips t where t.id = booking_items.trip_id and private.is_operator_staff(t.operator_id))
    or private.is_platform_admin()
  );

create policy booking_items_admin_all on public.booking_items
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy booking_status_history_select on public.booking_status_history
  for select to authenticated
  using (
    exists (select 1 from public.bookings b where b.id = booking_status_history.booking_id and b.customer_id = (select auth.uid()))
    or exists (
      select 1 from public.booking_items bi
      join public.bus_trips t on t.id = bi.trip_id
      where bi.booking_id = booking_status_history.booking_id and private.is_operator_staff(t.operator_id)
    )
    or private.is_platform_admin()
  );

create policy booking_status_history_admin_all on public.booking_status_history
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
