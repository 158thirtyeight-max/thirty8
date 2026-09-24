-- =========================================================================
-- Boarding events: the audit trail of QR scans at trip boarding, referenced
-- by verify_ticket_qr() (next migration).
-- =========================================================================

create table public.boarding_events (
  id uuid primary key default gen_random_uuid(),
  booking_item_id uuid not null references public.booking_items (id),
  trip_id uuid not null references public.bus_trips (id),
  scanned_by uuid references public.profiles (id),
  result text not null check (result in ('boarded', 'rejected_already_used', 'rejected_invalid', 'rejected_wrong_trip')),
  scanned_at timestamptz not null default now()
);

create index boarding_events_booking_item_id_idx on public.boarding_events (booking_item_id);
create index boarding_events_trip_id_idx on public.boarding_events (trip_id, scanned_at desc);

alter table public.boarding_events enable row level security;

create policy boarding_events_operator_select on public.boarding_events
  for select to authenticated
  using (
    exists (select 1 from public.bus_trips t where t.id = boarding_events.trip_id and private.is_operator_staff(t.operator_id))
    or private.is_platform_admin()
  );

create policy boarding_events_admin_all on public.boarding_events
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
-- No client insert policy: rows are written only by verify_ticket_qr() (SECURITY DEFINER, next migration).
