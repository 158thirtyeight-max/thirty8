-- Rollback for 20261002000400_operator_write_lockdown.sql
-- Restores the legacy operator FOR ALL policies (captured from the live database before the
-- change), drops the ownership guards and public.set_trip_status. No data is changed.
-- WARNING: this re-opens the direct operator write paths the migration closed.

drop policy if exists bus_routes_operator_select on public.bus_routes;
drop policy if exists bus_services_operator_select on public.bus_services;
drop policy if exists bus_trips_operator_select on public.bus_trips;
drop policy if exists boarding_points_operator_select on public.boarding_points;
drop policy if exists dropping_points_operator_select on public.dropping_points;
drop policy if exists fare_rules_operator_select on public.fare_rules;
drop policy if exists fare_charges_operator_select on public.fare_charges;

create policy bus_routes_operator_manage on public.bus_routes
  for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy bus_services_operator_manage on public.bus_services
  for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy bus_trips_operator_manage on public.bus_trips
  for all to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));
create policy boarding_points_operator_manage on public.boarding_points
  for all to authenticated
  using (exists (select 1 from public.bus_routes r where r.id = boarding_points.route_id and private.is_operator_staff(r.operator_id)))
  with check (exists (select 1 from public.bus_routes r where r.id = boarding_points.route_id and private.is_operator_staff(r.operator_id)));
create policy dropping_points_operator_manage on public.dropping_points
  for all to authenticated
  using (exists (select 1 from public.bus_routes r where r.id = dropping_points.route_id and private.is_operator_staff(r.operator_id)))
  with check (exists (select 1 from public.bus_routes r where r.id = dropping_points.route_id and private.is_operator_staff(r.operator_id)));
create policy fare_rules_operator_manage on public.fare_rules
  for all to authenticated
  using (exists (select 1 from public.bus_services s where s.id = fare_rules.service_id and private.is_operator_staff(s.operator_id)))
  with check (exists (select 1 from public.bus_services s where s.id = fare_rules.service_id and private.is_operator_staff(s.operator_id)));
create policy fare_charges_operator_manage on public.fare_charges
  for all to authenticated
  using (exists (select 1 from public.bus_services s where s.id = fare_charges.service_id and private.is_operator_staff(s.operator_id)))
  with check (exists (select 1 from public.bus_services s where s.id = fare_charges.service_id and private.is_operator_staff(s.operator_id)));

drop trigger if exists guard_bus_trip_ownership on public.bus_trips;
drop trigger if exists guard_bus_service_ownership on public.bus_services;
drop trigger if exists guard_bus_route_ownership on public.bus_routes;
drop function if exists private.guard_bus_trip_ownership();
drop function if exists private.guard_bus_service_ownership();
drop function if exists private.guard_bus_route_ownership();
drop function if exists public.set_trip_status(uuid, text);
