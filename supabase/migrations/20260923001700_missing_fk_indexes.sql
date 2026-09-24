-- =========================================================================
-- Covering indexes for foreign keys flagged by the Supabase performance
-- advisor (unindexed_foreign_keys) — avoids sequential scans on joins and
-- on FK-referenced-row deletes/updates.
-- =========================================================================

create index audit_logs_actor_profile_id_idx on public.audit_logs (actor_profile_id);
create index booking_items_boarding_point_id_idx on public.booking_items (boarding_point_id);
create index booking_items_dropping_point_id_idx on public.booking_items (dropping_point_id);
create index booking_items_passenger_id_idx on public.booking_items (passenger_id);
create index booking_status_history_changed_by_idx on public.booking_status_history (changed_by);
create index bus_routes_destination_city_id_idx on public.bus_routes (destination_city_id);
create index bus_services_bus_id_idx on public.bus_services (bus_id);
create index bus_services_service_dest_city_id_idx on public.bus_services (service_dest_city_id);
create index bus_trips_bus_id_idx on public.bus_trips (bus_id);
create index cargo_pricing_rules_cargo_type_id_idx on public.cargo_pricing_rules (cargo_type_id);
create index cargo_pricing_rules_vehicle_type_id_idx on public.cargo_pricing_rules (vehicle_type_id);
create index cargo_routes_destination_city_id_idx on public.cargo_routes (destination_city_id);
create index cargo_shipments_cargo_type_id_idx on public.cargo_shipments (cargo_type_id);
create index cargo_shipments_delivery_hub_id_idx on public.cargo_shipments (delivery_hub_id) where delivery_hub_id is not null;
create index cargo_shipments_pickup_hub_id_idx on public.cargo_shipments (pickup_hub_id) where pickup_hub_id is not null;
create index cargo_shipments_route_id_idx on public.cargo_shipments (route_id) where route_id is not null;
create index cargo_shipments_vehicle_id_idx on public.cargo_shipments (vehicle_id) where vehicle_id is not null;
create index cargo_status_history_changed_by_idx on public.cargo_status_history (changed_by);
create index cargo_tracking_events_milestone_hub_id_idx on public.cargo_tracking_events (milestone_hub_id) where milestone_hub_id is not null;
create index cargo_vehicles_vehicle_type_id_idx on public.cargo_vehicles (vehicle_type_id);
create index operator_insurance_verified_by_idx on public.operator_insurance (verified_by) where verified_by is not null;
create index operators_approved_by_idx on public.operators (approved_by) where approved_by is not null;
create index ratings_reviews_profile_id_idx on public.ratings_reviews (profile_id);
create index trip_seats_seat_id_idx on public.trip_seats (seat_id);
