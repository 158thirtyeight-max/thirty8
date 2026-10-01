-- Restrict the customer-facing city list to the Sri Vijaya Puram <-> Diglipur
-- bus corridor. Island destinations (Havelock, Neil, Long Island, Little
-- Andaman, Car Nicobar, Kamorta, Nancowry) aren't reachable by this bus route.
-- Rows are deactivated, not deleted, so existing references stay valid.

update public.cities
set is_active = false
where name in (
  'Havelock Island (Swaraj Dweep)',
  'Neil Island (Shaheed Dweep)',
  'Long Island',
  'Little Andaman',
  'Car Nicobar',
  'Kamorta',
  'Nancowry',
  'Ferrargunj'
);

-- Stops along the Andaman Trunk Road between the two ends.
insert into public.cities (country_id, name, state, latitude, longitude)
select (select id from public.countries where code = 'IND'), v.name, v.state, v.latitude, v.longitude
from (values
  ('Jirkatang', 'Andaman and Nicobar Islands', 11.8333::numeric, 92.7167::numeric),
  ('Baratang', 'Andaman and Nicobar Islands', 12.1667, 92.7667),
  ('Kadamtala', 'Andaman and Nicobar Islands', 12.3500, 92.7833),
  ('Billiground', 'Andaman and Nicobar Islands', 13.0000, 92.9000)
) as v(name, state, latitude, longitude)
where not exists (select 1 from public.cities c where c.name = v.name);
