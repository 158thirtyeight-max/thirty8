-- =========================================================================
-- Cargo shipments: the top-level cargo entity (parallel to bookings for bus)
-- =========================================================================

create type public.cargo_point_type as enum ('address', 'hub');
create type public.cargo_speed as enum ('standard', 'express', 'same_day');
create type public.cargo_shipment_status as enum (
  'draft', 'confirmed', 'picked_up', 'in_transit', 'arrived_at_hub',
  'out_for_delivery', 'delivered', 'cancelled', 'failed'
);

create table public.cargo_shipments (
  id uuid primary key default gen_random_uuid(),
  shipment_reference text not null unique,
  sender_user_id uuid not null references public.profiles (id),
  operator_id uuid references public.operators (id),
  route_id uuid references public.cargo_routes (id),
  vehicle_id uuid references public.cargo_vehicles (id),
  cargo_type_id uuid not null references public.cargo_types (id),

  -- Package
  description text,
  weight_kg numeric(10, 2) not null check (weight_kg > 0),
  length_cm numeric(8, 2),
  width_cm numeric(8, 2),
  height_cm numeric(8, 2),
  volume_cbm numeric(10, 3),
  declared_value_cents integer,
  special_instructions text,

  -- Pickup
  pickup_type public.cargo_point_type not null,
  pickup_address text,
  pickup_latitude numeric(10, 7),
  pickup_longitude numeric(10, 7),
  pickup_hub_id uuid references public.cargo_hub (id),
  pickup_contact_name text,
  pickup_contact_phone text,
  pickup_scheduled_at timestamptz,

  -- Delivery
  delivery_type public.cargo_point_type not null,
  delivery_address text,
  delivery_latitude numeric(10, 7),
  delivery_longitude numeric(10, 7),
  delivery_hub_id uuid references public.cargo_hub (id),
  delivery_contact_name text,
  delivery_contact_phone text,
  delivery_scheduled_at timestamptz,

  -- Pricing
  shipping_speed public.cargo_speed not null default 'standard',
  currency_code text not null default 'INR',
  base_fare_cents integer not null default 0,
  distance_fare_cents integer not null default 0,
  weight_fare_cents integer not null default 0,
  surcharge_cents integer not null default 0,
  discount_cents integer not null default 0,
  total_fare_cents integer not null default 0,

  -- Status
  status public.cargo_shipment_status not null default 'draft',

  -- Tracking
  current_latitude numeric(10, 7),
  current_longitude numeric(10, 7),
  last_location_update timestamptz,
  estimated_delivery_at timestamptz,
  actual_delivered_at timestamptz,

  -- Proof
  pickup_proof_url text,
  delivery_proof_url text,
  recipient_name text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint cargo_shipments_pickup_chk check (
    (pickup_type = 'address' and pickup_address is not null)
    or (pickup_type = 'hub' and pickup_hub_id is not null)
  ),
  constraint cargo_shipments_delivery_chk check (
    (delivery_type = 'address' and delivery_address is not null)
    or (delivery_type = 'hub' and delivery_hub_id is not null)
  )
);

create trigger set_updated_at
  before update on public.cargo_shipments
  for each row execute function private.set_updated_at();

create index cargo_shipments_sender_idx on public.cargo_shipments (sender_user_id);
create index cargo_shipments_operator_idx on public.cargo_shipments (operator_id) where operator_id is not null;
create index cargo_shipments_status_idx on public.cargo_shipments (status);

create table public.cargo_status_history (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.cargo_shipments (id) on delete cascade,
  from_status public.cargo_shipment_status,
  to_status public.cargo_shipment_status not null,
  changed_by uuid references public.profiles (id),
  note text,
  created_at timestamptz not null default now()
);

create index cargo_status_history_shipment_id_idx on public.cargo_status_history (shipment_id);

create table public.cargo_tracking_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.cargo_shipments (id) on delete cascade,
  latitude numeric(10, 7) not null,
  longitude numeric(10, 7) not null,
  event_type text not null check (event_type in ('location_update', 'milestone_arrived', 'milestone_departed')),
  milestone_hub_id uuid references public.cargo_hub (id),
  recorded_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index cargo_tracking_events_shipment_id_idx on public.cargo_tracking_events (shipment_id, recorded_at desc);

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.cargo_shipments enable row level security;
alter table public.cargo_status_history enable row level security;
alter table public.cargo_tracking_events enable row level security;

create policy cargo_shipments_select_own on public.cargo_shipments
  for select to authenticated
  using (
    sender_user_id = (select auth.uid())
    or (operator_id is not null and private.is_operator_staff(operator_id))
    or private.is_platform_admin()
  );

create policy cargo_shipments_insert_own on public.cargo_shipments
  for insert to authenticated
  with check (sender_user_id = (select auth.uid()));

create policy cargo_shipments_update_own_draft on public.cargo_shipments
  for update to authenticated
  using (sender_user_id = (select auth.uid()) and status in ('draft', 'confirmed'))
  with check (sender_user_id = (select auth.uid()));

create policy cargo_shipments_operator_manage on public.cargo_shipments
  for update to authenticated
  using (operator_id is not null and private.is_operator_staff(operator_id))
  with check (operator_id is not null and private.is_operator_staff(operator_id));

create policy cargo_shipments_admin_all on public.cargo_shipments
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy cargo_status_history_select on public.cargo_status_history
  for select to authenticated
  using (
    exists (
      select 1 from public.cargo_shipments s
      where s.id = cargo_status_history.shipment_id
        and (s.sender_user_id = (select auth.uid()) or (s.operator_id is not null and private.is_operator_staff(s.operator_id)))
    )
    or private.is_platform_admin()
  );

create policy cargo_status_history_admin_all on public.cargo_status_history
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy cargo_tracking_events_select on public.cargo_tracking_events
  for select to authenticated
  using (
    exists (
      select 1 from public.cargo_shipments s
      where s.id = cargo_tracking_events.shipment_id
        and (s.sender_user_id = (select auth.uid()) or (s.operator_id is not null and private.is_operator_staff(s.operator_id)))
    )
    or private.is_platform_admin()
  );

create policy cargo_tracking_events_operator_insert on public.cargo_tracking_events
  for insert to authenticated
  with check (
    exists (
      select 1 from public.cargo_shipments s
      where s.id = cargo_tracking_events.shipment_id
        and s.operator_id is not null
        and private.is_operator_staff(s.operator_id)
    )
  );

create policy cargo_tracking_events_admin_all on public.cargo_tracking_events
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
