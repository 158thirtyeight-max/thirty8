-- =========================================================================
-- Clean slate for the location / route subsystem (development data only).
--
-- Removes the demo / test route data so routes can be built fresh on the
-- approved main locations: bus routes, services, trips and their seats,
-- fares, route stops, route templates and master points, plus legacy
-- (non-approved) location rows that nothing references.
--
-- Deliberately NOT touched: users, auth, admin and operator accounts, buses
-- (bus registration, documents, layouts), payments, subscriptions, cargo,
-- bookings. Explicit deletes in dependency order, no cascade tricks: if any
-- booking, seat hold, boarding event or review depends on these trips, the
-- migration stops instead of deleting it.
-- =========================================================================

do $$
declare
  n bigint;
begin
  select count(*) into n from public.booking_items;
  if n > 0 then raise exception 'Clean slate aborted: % booking item(s) reference trips/points. Clear test bookings first.', n; end if;
  select count(*) into n from public.seat_holds;
  if n > 0 then raise exception 'Clean slate aborted: % seat hold(s) exist.', n; end if;
  select count(*) into n from public.boarding_events;
  if n > 0 then raise exception 'Clean slate aborted: % boarding event(s) exist.', n; end if;
  select count(*) into n from public.ratings_reviews where trip_id is not null;
  if n > 0 then raise exception 'Clean slate aborted: % trip review(s) exist.', n; end if;

  -- trips and everything hanging off them
  delete from public.bus_trip_events;
  delete from public.trip_seats;
  delete from public.bus_trips;

  -- fares, services, stops, routes
  delete from public.fare_rules;
  delete from public.fare_charges;
  delete from public.bus_services;
  delete from public.boarding_points;
  delete from public.dropping_points;
  delete from public.bus_routes;

  -- route catalog and master points (re-created through the admin panel)
  delete from public.route_template_stops;
  delete from public.route_templates;
  delete from public.pickup_drop_points;

  -- legacy locations that are not part of the approved list and are unused anywhere
  delete from public.cities c
  where c.display_order is null
    and not exists (select 1 from public.cargo_hub h where h.city_id = c.id)
    and not exists (select 1 from public.cargo_routes r where r.source_city_id = c.id or r.destination_city_id = c.id);
end $$;
