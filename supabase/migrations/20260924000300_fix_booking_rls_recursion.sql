-- =========================================================================
-- Fix: infinite recursion in RLS between bookings and booking_items.
--
-- bookings_select_own queried booking_items to check operator visibility;
-- booking_items_select queried bookings to check customer ownership. Each
-- subquery re-triggers the OTHER table's RLS policy (RLS applies per-table
-- regardless of where the reference comes from), so Postgres recurses
-- forever: 42P17 "infinite recursion detected in policy for relation
-- bookings". This broke every read of bookings/booking_items/passengers/
-- booking_status_history for real users (found via a live UI test, not
-- caught by RPC-based fixture testing since those never went through a
-- plain SELECT on these tables with RLS active for a real session).
--
-- Fix: move the cross-table checks into SECURITY DEFINER helper functions.
-- Queries inside a SECURITY DEFINER function run as the function's owner
-- (here, the migration-applying role, which owns these tables and — since
-- FORCE ROW LEVEL SECURITY was never set — bypasses their RLS), so the
-- helper's internal query never re-triggers the other table's policy.
-- =========================================================================

create or replace function private.is_operator_staff_for_booking(p_booking_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.booking_items bi
    join public.bus_trips t on t.id = bi.trip_id
    where bi.booking_id = p_booking_id and private.is_operator_staff(t.operator_id)
  );
$$;

create or replace function private.booking_customer_id(p_booking_id uuid)
returns uuid
language sql
security definer
stable
set search_path = ''
as $$
  select customer_id from public.bookings where id = p_booking_id;
$$;

drop policy if exists bookings_select_own on public.bookings;
create policy bookings_select_own on public.bookings
  for select to authenticated
  using (
    customer_id = (select auth.uid())
    or private.is_operator_staff_for_booking(id)
    or private.is_platform_admin()
  );

drop policy if exists booking_items_select on public.booking_items;
create policy booking_items_select on public.booking_items
  for select to authenticated
  using (
    private.booking_customer_id(booking_id) = (select auth.uid())
    or exists (select 1 from public.bus_trips t where t.id = booking_items.trip_id and private.is_operator_staff(t.operator_id))
    or private.is_platform_admin()
  );
