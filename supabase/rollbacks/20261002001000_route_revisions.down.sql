-- Rolls back 20261002001000_route_revisions.sql (development use).
-- Drops the revision layer and the return-journey columns. A bus that already has a RETURN
-- route must have it removed first (the one-route-per-bus index comes back).
do $$
begin
  if exists (select 1 from public.bus_routes where direction = 'return') then
    raise exception 'Remove return routes/services before rolling back (bus_routes.direction = return exists)';
  end if;
end $$;

drop function if exists public.start_route_revision(uuid, uuid);
drop function if exists public.save_route_revision(uuid, jsonb);
drop function if exists public.generate_reverse_route(uuid);
drop function if exists public.validate_route_revision(uuid);
drop function if exists public.submit_route_revision(uuid, text);
drop function if exists public.withdraw_route_revision(uuid);
drop function if exists public.admin_review_route_revision(uuid, text, text);
drop function if exists public.get_route_revision_diff(uuid);
drop function if exists private.materialize_revision(uuid);
drop function if exists private.load_revision_for_edit(uuid);
drop function if exists private.diff_journeys(jsonb, jsonb);
drop function if exists private.revision_journey_json(uuid, text);
drop function if exists private.live_journey_json(uuid, text);
drop function if exists private.validate_revision(uuid);
drop function if exists private.insert_journey_stops(uuid, jsonb);
drop function if exists private.live_route_stops(uuid);
drop function if exists private.journey_stops_json(uuid);

alter table public.bus_routes drop column if exists revision_journey_id;
alter table public.buses drop column if exists active_route_revision_id;
drop table if exists public.route_change_flags;
drop table if exists public.route_revision_events;
drop table if exists public.route_revision_stops;
drop table if exists public.route_revision_journeys;
drop table if exists public.route_revisions;

drop function if exists private.guard_revision_immutable();
drop function if exists private.guard_revision_children_immutable();
drop function if exists private.can_manage_routes(uuid);
drop function if exists private.revision_operator_id(uuid);
drop function if exists private.journey_operator_id(uuid);

drop index if exists public.bus_routes_one_per_bus_direction_uniq;
drop index if exists public.bus_routes_linked_route_idx;
drop index if exists public.bus_services_bus_direction_idx;
create unique index bus_routes_one_per_bus_uniq on public.bus_routes (bus_id) where bus_id is not null;
alter table public.bus_routes drop column if exists linked_route_id, drop column if exists direction;
alter table public.bus_services drop column if exists direction;

-- Restore the previous bus_primary_service, save_bus_route, generate_bus_trips and
-- private.apply_route_journey removal by re-applying 20260926000900 / 20261002000500 definitions:
drop function if exists private.apply_route_journey(uuid, text, uuid, uuid, numeric, time, integer, smallint[], jsonb, uuid, uuid);
drop function if exists private.validate_route_journey(uuid, uuid, uuid, time, integer, smallint[], jsonb, boolean);
create or replace function private.bus_primary_service(p_bus_id uuid)
returns uuid language sql stable security definer set search_path = ''
as $$ select id from public.bus_services where bus_id = p_bus_id order by created_at, id limit 1; $$;
-- NOTE: public.save_bus_route and public.generate_bus_trips keep their new bodies; re-run the
-- CREATE OR REPLACE blocks from 20261002000500_unified_locations.sql / 20260926000900_schedule.sql to restore the originals.
