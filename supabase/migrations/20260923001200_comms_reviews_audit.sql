-- =========================================================================
-- Notifications, ratings/reviews, audit log
-- =========================================================================

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  title text not null,
  body text,
  data jsonb not null default '{}'::jsonb,
  type text,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index notifications_profile_id_idx on public.notifications (profile_id, created_at desc);
create index notifications_unread_idx on public.notifications (profile_id) where not is_read;

create table public.notification_preferences (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.profiles (id) on delete cascade,
  push_enabled boolean not null default true,
  sms_enabled boolean not null default true,
  email_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.notification_preferences
  for each row execute function private.set_updated_at();

create table public.ratings_reviews (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id),
  operator_id uuid references public.operators (id),
  trip_id uuid references public.bus_trips (id),
  shipment_id uuid references public.cargo_shipments (id),
  rating smallint not null check (rating between 1 and 5),
  review text,
  created_at timestamptz not null default now(),
  constraint ratings_reviews_target_chk check (trip_id is not null or shipment_id is not null)
);

create index ratings_reviews_operator_id_idx on public.ratings_reviews (operator_id) where operator_id is not null;
create index ratings_reviews_trip_id_idx on public.ratings_reviews (trip_id) where trip_id is not null;
create index ratings_reviews_shipment_id_idx on public.ratings_reviews (shipment_id) where shipment_id is not null;

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_profile_id uuid references public.profiles (id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before jsonb,
  after jsonb,
  request_id text,
  created_at timestamptz not null default now()
);

create index audit_logs_entity_idx on public.audit_logs (entity_type, entity_id);
create index audit_logs_created_at_idx on public.audit_logs (created_at desc);

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.ratings_reviews enable row level security;
alter table public.audit_logs enable row level security;

create policy notifications_owner_select on public.notifications
  for select to authenticated
  using (profile_id = (select auth.uid()) or private.is_platform_admin());

create policy notifications_owner_update on public.notifications
  for update to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

create policy notifications_admin_all on public.notifications
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
-- Insert is service-role only (Edge Functions dispatch notifications).

create policy notification_preferences_owner_all on public.notification_preferences
  for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

create policy ratings_reviews_select_public on public.ratings_reviews
  for select to anon, authenticated
  using (true);

create policy ratings_reviews_owner_write on public.ratings_reviews
  for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

create policy ratings_reviews_admin_all on public.ratings_reviews
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy audit_logs_admin_select on public.audit_logs
  for select to authenticated
  using (private.is_platform_admin());
-- Insert is service-role / SECURITY DEFINER function only, never direct client writes.
