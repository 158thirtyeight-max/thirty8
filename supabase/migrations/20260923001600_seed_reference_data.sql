-- =========================================================================
-- Seed: global reference data (countries, Andaman & Nicobar cities, cargo
-- vehicle/cargo type catalogs). Route/boarding-point/service/trip seed data
-- is NOT included here — it depends on a real operator + bus existing,
-- which is created through the app (operator onboarding, Phase 2+), not a
-- platform-level migration.
-- =========================================================================

insert into public.countries (code, name)
values ('IND', 'India')
on conflict (code) do nothing;

insert into public.cities (country_id, name, state, latitude, longitude)
select (select id from public.countries where code = 'IND'), v.name, v.state, v.latitude, v.longitude
from (values
  ('Sri Vijaya Puram (Port Blair)', 'Andaman and Nicobar Islands', 11.6234::numeric, 92.7265::numeric),
  ('Diglipur', 'Andaman and Nicobar Islands', 13.2600, 93.0000),
  ('Rangat', 'Andaman and Nicobar Islands', 12.5333, 92.8833),
  ('Havelock Island (Swaraj Dweep)', 'Andaman and Nicobar Islands', 11.9833, 93.0000),
  ('Neil Island (Shaheed Dweep)', 'Andaman and Nicobar Islands', 11.8167, 93.0333),
  ('Long Island', 'Andaman and Nicobar Islands', 12.2833, 93.0667),
  ('Mayabunder', 'Andaman and Nicobar Islands', 12.8833, 92.8167),
  ('Ferrargunj', 'Andaman and Nicobar Islands', 11.5833, 92.7167),
  ('Little Andaman', 'Andaman and Nicobar Islands', 10.8000, 92.7333),
  ('Car Nicobar', 'Andaman and Nicobar Islands', 9.1667, 92.7500),
  ('Kamorta', 'Andaman and Nicobar Islands', 8.9500, 93.5333),
  ('Nancowry', 'Andaman and Nicobar Islands', 8.9000, 93.5500)
) as v(name, state, latitude, longitude)
where not exists (select 1 from public.cities c where c.name = v.name);

insert into public.cargo_vehicle_types (name, max_weight_kg, max_volume_cbm)
values
  ('Bike', 10, 0.02),
  ('Auto', 50, 0.3),
  ('Mini Van', 200, 2),
  ('Truck (7T)', 7000, 20),
  ('Truck (16T)', 16000, 40)
on conflict (name) do nothing;

insert into public.cargo_types (name, max_weight_kg, requires_special_handling)
values
  ('Document', 5, false),
  ('Parcel', 50, false),
  ('Fragile', 30, true),
  ('Heavy Goods', 500, true),
  ('Perishable', 20, true),
  ('Electronics', 25, true)
on conflict (name) do nothing;
