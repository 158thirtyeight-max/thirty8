-- Rollback for 20261002000600_public_read_lockdown.sql
-- Restores the previous open read policies (predicates captured from the live database before
-- the change) and drops the new policies and functions. No data is changed.
-- WARNING: this re-opens anonymous reads of trips (incl. live location), fares, stops, buses and
-- operators, and brings back the anon "permission denied for function is_operator_staff" errors
-- on operators, bus_layouts and cargo_vehicles.

drop policy if exists bus_trips_select_own_booking on public.bus_trips;
drop policy if exists boarding_points_select_own_booking on public.boarding_points;
drop policy if exists dropping_points_select_own_booking on public.dropping_points;
drop policy if exists operators_select_staff on public.operators;
drop policy if exists seats_operator_select on public.seats;
drop policy if exists trip_seats_operator_select on public.trip_seats;
drop policy if exists cargo_vehicles_select_active on public.cargo_vehicles;

create policy bus_routes_select_public on public.bus_routes for select to anon, authenticated using (true);
create policy bus_services_select_public on public.bus_services for select to anon, authenticated using (true);
create policy bus_trips_select_public on public.bus_trips for select to anon, authenticated using (true);
create policy boarding_points_select_public on public.boarding_points for select to anon, authenticated using (true);
create policy dropping_points_select_public on public.dropping_points for select to anon, authenticated using (true);
create policy fare_rules_select_public on public.fare_rules for select to anon, authenticated using (true);
create policy fare_charges_select_public on public.fare_charges for select to anon, authenticated using (true);
create policy trip_seats_select_public on public.trip_seats for select to anon, authenticated using (true);
create policy seats_select_public on public.seats for select to anon, authenticated using (true);
create policy bus_layouts_select_public on public.bus_layouts for select to anon, authenticated using (
  exists (select 1 from public.buses b where b.id = bus_layouts.bus_id
          and (b.status = 'active'::public.bus_status or private.is_operator_staff(b.operator_id) or private.is_platform_admin())));
create policy buses_select_public on public.buses for select to anon, authenticated using (
  status = 'active'::public.bus_status
  and lifecycle_status = any (array['approved'::public.bus_lifecycle, 'active'::public.bus_lifecycle, 'suspended'::public.bus_lifecycle, 'inactive'::public.bus_lifecycle]));
create policy operators_select_public on public.operators for select to anon, authenticated using (
  status = 'approved'::public.operator_status or private.is_operator_staff(id) or private.is_platform_admin());
create policy cargo_vehicles_select_public on public.cargo_vehicles for select to anon, authenticated using (
  status = 'active'::public.bus_status or private.is_operator_staff(operator_id) or private.is_platform_admin());

drop function if exists public.get_trip_points(uuid);
drop function if exists private.customer_booked_point(uuid);
drop function if exists private.customer_has_booking_on_trip(uuid);
