-- =========================================================================
-- Phase 5 repair: stop exposing booking inventory and operator data to everyone
--   Before: bus_routes, bus_services, bus_trips (incl. live location), boarding /
--   dropping points, fare_rules, fare_charges, seats and trip_seats were readable by
--   anonymous users with `using (true)`; buses (chassis / engine numbers) and
--   operators (legal name, contact details) were readable for every active bus /
--   approved operator; and the policies on operators, bus_layouts and
--   cargo_vehicles called private helper functions that anon cannot execute, so an
--   anonymous SELECT failed with "permission denied for function is_operator_staff".
--
--   The customer-facing data already flows through SECURITY DEFINER RPCs
--   (search_trips, get_trip_seat_map, create_seat_hold, create_booking, ...), so no
--   client needs those public reads. The one direct read left in the customer app
--   (boarding / dropping points of a searched trip) moves to a new RPC,
--   public.get_trip_points. A customer keeps read access to the trips and stops of
--   their OWN bookings (needed by "My trips").
--
--   Operators keep reading their own data (operator SELECT policies); platform admin
--   keeps `*_admin_all`. Nothing here changes any write path.
--
--   Rollback: supabase/rollbacks/20261002000600_public_read_lockdown.down.sql
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. Helpers for "my own bookings" reads. SECURITY DEFINER so the policy does not
--    recurse into booking_items / bookings RLS (booking_items_select already looks
--    at bus_trips).
-- ---------------------------------------------------------------------
create or replace function private.customer_has_booking_on_trip(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.booking_items bi
    join public.bookings b on b.id = bi.booking_id
    where bi.trip_id = p_trip_id
      and b.customer_id = (select auth.uid())
  );
$function$;

create or replace function private.customer_booked_point(p_point_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.booking_items bi
    join public.bookings b on b.id = bi.booking_id
    where b.customer_id = (select auth.uid())
      and p_point_id in (bi.boarding_point_id, bi.dropping_point_id)
  );
$function$;

revoke execute on function private.customer_has_booking_on_trip(uuid) from public, anon;
revoke execute on function private.customer_booked_point(uuid) from public, anon;
grant execute on function private.customer_has_booking_on_trip(uuid) to authenticated;
grant execute on function private.customer_booked_point(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Points of a searched trip, for the booking screen (replaces direct table reads)
-- ---------------------------------------------------------------------
create or replace function public.get_trip_points(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_route uuid;
begin
  select t.route_id into v_route
  from public.bus_trips t
  where t.id = p_trip_id
    and private.is_bus_bookable(t.bus_id)
    and private.trip_is_open_for_booking(t.id);
  if v_route is null then
    return null;
  end if;

  return jsonb_build_object(
    'route_id', v_route,
    'boarding', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.sequence_no)
      from public.boarding_points b where b.route_id = v_route and b.is_active), '[]'::jsonb),
    'dropping', coalesce((
      select jsonb_agg(to_jsonb(d) order by d.sequence_no)
      from public.dropping_points d where d.route_id = v_route and d.is_active), '[]'::jsonb)
  );
end;
$function$;

revoke execute on function public.get_trip_points(uuid) from public;
grant execute on function public.get_trip_points(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Drop the open reads
-- ---------------------------------------------------------------------
drop policy bus_routes_select_public on public.bus_routes;
drop policy bus_services_select_public on public.bus_services;
drop policy bus_trips_select_public on public.bus_trips;
drop policy boarding_points_select_public on public.boarding_points;
drop policy dropping_points_select_public on public.dropping_points;
drop policy fare_rules_select_public on public.fare_rules;
drop policy fare_charges_select_public on public.fare_charges;
drop policy trip_seats_select_public on public.trip_seats;
drop policy seats_select_public on public.seats;
drop policy bus_layouts_select_public on public.bus_layouts;
drop policy buses_select_public on public.buses;
drop policy operators_select_public on public.operators;
drop policy cargo_vehicles_select_public on public.cargo_vehicles;

-- ---------------------------------------------------------------------
-- 4. What is still readable, and by whom
-- ---------------------------------------------------------------------
-- customers: the trips and stops of their own bookings
create policy bus_trips_select_own_booking on public.bus_trips
  for select to authenticated using (private.customer_has_booking_on_trip(id));
create policy boarding_points_select_own_booking on public.boarding_points
  for select to authenticated using (private.customer_booked_point(id));
create policy dropping_points_select_own_booking on public.dropping_points
  for select to authenticated using (private.customer_booked_point(id));

-- operator staff: their own operator row, seat definitions and trip seat inventory
-- (routes, services, trips, points, fares, layouts and buses already have operator SELECT policies)
create policy operators_select_staff on public.operators
  for select to authenticated using (private.is_operator_staff(id));
create policy seats_operator_select on public.seats
  for select to authenticated using (exists (
    select 1 from public.bus_layouts l
    where l.id = seats.bus_layout_id and private.is_operator_staff(private.bus_operator_id(l.bus_id))));
create policy trip_seats_operator_select on public.trip_seats
  for select to authenticated using (exists (
    select 1 from public.bus_trips t
    where t.id = trip_seats.trip_id and private.is_operator_staff(t.operator_id)));

-- cargo vehicles: signed-in users only (the previous policy also let anon in, and failed for them)
create policy cargo_vehicles_select_active on public.cargo_vehicles
  for select to authenticated using (status = 'active'::public.bus_status);
