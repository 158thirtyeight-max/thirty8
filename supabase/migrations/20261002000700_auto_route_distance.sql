-- Route distance is derived, not typed in. Estimated as the straight-line (haversine)
-- distance between origin and destination locations, scaled by a road factor.
-- Applies when the caller supplies no distance; falls back to null if either
-- location has no coordinates.

create or replace function private.estimate_route_distance_km(p_source uuid, p_dest uuid)
returns numeric
language sql
stable
set search_path = ''
as $$
  select nullif(round((2 * 6371 * asin(sqrt(
           power(sin(radians(d.latitude - s.latitude) / 2), 2)
           + cos(radians(s.latitude)) * cos(radians(d.latitude))
             * power(sin(radians(d.longitude - s.longitude) / 2), 2)
         )) * 1.25)::numeric, 1), 0)
  from public.locations s, public.locations d
  where s.id = p_source and d.id = p_dest
    and s.latitude is not null and d.latitude is not null;
$$;

create or replace function private.bus_routes_auto_distance()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.source_city_id is distinct from old.source_city_id
     or new.destination_city_id is distinct from old.destination_city_id
     or new.distance_km is null then
    new.distance_km := private.estimate_route_distance_km(new.source_city_id, new.destination_city_id);
  end if;
  return new;
end;
$$;

drop trigger if exists bus_routes_auto_distance on public.bus_routes;
create trigger bus_routes_auto_distance
  before insert or update on public.bus_routes
  for each row execute function private.bus_routes_auto_distance();

-- Admin catalog routes (route_templates) use the same rule.
drop trigger if exists route_templates_auto_distance on public.route_templates;
create trigger route_templates_auto_distance
  before insert or update on public.route_templates
  for each row execute function private.bus_routes_auto_distance();

-- Backfill existing routes with no distance.
update public.bus_routes
set distance_km = private.estimate_route_distance_km(source_city_id, destination_city_id)
where distance_km is null;

update public.route_templates
set distance_km = private.estimate_route_distance_km(source_city_id, destination_city_id)
where distance_km is null;
