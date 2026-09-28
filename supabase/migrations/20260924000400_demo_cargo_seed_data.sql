-- =========================================================================
-- DEMO cargo seed data: the same demo operator also handles cargo (a real
-- vehicle, the Port Blair <-> Diglipur cargo route, a destination hub with
-- coordinates so geofence milestone detection is testable, and pricing for
-- a couple of common cargo types).
-- =========================================================================

do $$
declare
  v_operator_id uuid;
  v_vehicle_type_id uuid;
  v_vehicle_id uuid;
  v_route_id uuid;
  v_hub_id uuid;
  v_pb uuid := (select id from public.cities where name ilike '%Sri Vijaya Puram%');
  v_dg uuid := (select id from public.cities where name ilike '%Diglipur%');
begin
  select id into v_operator_id from public.operators where name = 'Andaman Express (Demo)';
  if v_operator_id is null then
    return;
  end if;
  if exists (select 1 from public.cargo_routes where operator_id = v_operator_id) then
    return;
  end if;

  update public.operators set business_type = 'both' where id = v_operator_id;

  select id into v_vehicle_type_id from public.cargo_vehicle_types where name = 'Mini Van';

  insert into public.cargo_vehicles (operator_id, vehicle_type_id, registration_number)
  values (v_operator_id, v_vehicle_type_id, 'AN01-CARGO-DEMO-1')
  returning id into v_vehicle_id;

  insert into public.cargo_routes (operator_id, source_city_id, destination_city_id, distance_km)
  values (v_operator_id, v_pb, v_dg, 320)
  returning id into v_route_id;

  insert into public.cargo_hub (operator_id, city_id, name, address, latitude, longitude, operating_hours)
  values (v_operator_id, v_dg, 'Diglipur Cargo Hub', 'Main Road, Diglipur', 13.2600, 93.0000, '8am - 8pm')
  returning id into v_hub_id;

  insert into public.cargo_hub (operator_id, city_id, name, address, latitude, longitude, operating_hours)
  values (v_operator_id, v_pb, 'Port Blair Cargo Hub', 'Junglighat, Port Blair', 11.6234, 92.7265, '8am - 8pm');

  insert into public.cargo_pricing_rules (route_id, vehicle_type_id, cargo_type_id, base_fare_cents, per_km_cents, per_kg_cents, surcharge_cents)
  select v_route_id, v_vehicle_type_id, ct.id, 5000, 10, 50,
    case when ct.requires_special_handling then 2000 else 0 end
  from public.cargo_types ct;
end $$;
