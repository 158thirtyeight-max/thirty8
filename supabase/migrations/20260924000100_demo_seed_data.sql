-- =========================================================================
-- DEMO seed data: one approved operator with a bus, route, and a week of
-- scheduled trips on the Port Blair <-> Diglipur corridor, so the customer
-- app has something real to search/browse/book during development. This is
-- clearly demo inventory, not production — remove before a real launch
-- (the "Define bus operators to onboard" item is still genuinely pending
-- per the plan's own pre-build checklist).
-- =========================================================================

do $$
declare
  v_op_admin_user uuid := gen_random_uuid();
  v_operator_id uuid;
  v_bus_id uuid;
  v_layout_id uuid;
  v_route_id uuid;
  v_service_id uuid;
  v_pb uuid := (select id from public.cities where name ilike '%Sri Vijaya Puram%');
  v_dg uuid := (select id from public.cities where name ilike '%Diglipur%');
  v_bp_id uuid;
  v_dp_id uuid;
  v_trip_id uuid;
  v_row int;
  v_col int;
  v_letters text[] := array['A', 'B', 'C', 'D'];
  v_day int;
begin
  if exists (select 1 from public.operators where name = 'Andaman Express (Demo)') then
    return;
  end if;

  insert into auth.users (id, email) values (v_op_admin_user, 'demo-operator@thirty8.app');

  insert into public.operators (name, legal_name, business_type, contact_email, contact_phone, status, rating, approved_at)
  values ('Andaman Express (Demo)', 'Andaman Express (Demo) Pvt Ltd', 'bus', 'ops@thirty8.app', '9800000001', 'approved', 4.3, now())
  returning id into v_operator_id;

  insert into public.user_roles (user_id, role, operator_id)
  values (v_op_admin_user, 'operator_admin', v_operator_id);

  insert into public.buses (operator_id, registration_number, bus_type, total_seats, amenities)
  values (v_operator_id, 'AN01-DEMO-0001', 'ac_seater', 36, array['charging_point', 'water_bottle', 'wifi'])
  returning id into v_bus_id;

  insert into public.bus_layouts (bus_id, name, deck_count, is_active, layout_json)
  values (v_bus_id, 'Demo 2+2 seater', 1, true, '{"rows": 9, "cols": 4, "aisle_after_col": 2}'::jsonb)
  returning id into v_layout_id;

  for v_row in 1..9 loop
    for v_col in 1..4 loop
      insert into public.seats (bus_layout_id, seat_code, deck, row_no, col_no, seat_type)
      values (v_layout_id, v_row::text || v_letters[v_col], 1, v_row, v_col, 'seater');
    end loop;
  end loop;

  insert into public.bus_routes (operator_id, source_city_id, destination_city_id, distance_km)
  values (v_operator_id, v_pb, v_dg, 320)
  returning id into v_route_id;

  insert into public.boarding_points (route_id, name, address, sequence_no)
  values (v_route_id, 'Port Blair Bus Stand', 'Junglighat, Port Blair', 1)
  returning id into v_bp_id;

  insert into public.dropping_points (route_id, name, address, sequence_no)
  values (v_route_id, 'Diglipur Bus Stand', 'Main Road, Diglipur', 1)
  returning id into v_dp_id;

  insert into public.bus_services (
    operator_id, route_id, bus_id, service_code, service_name,
    service_source_city_id, service_dest_city_id,
    default_departure_time, default_arrival_offset_minutes, status
  )
  values (
    v_operator_id, v_route_id, v_bus_id, 'AE-PB-DG-01', 'Port Blair - Diglipur Express',
    v_pb, v_dg, '06:00', 600, 'active'
  )
  returning id into v_service_id;

  insert into public.fare_rules (service_id, seat_type, base_fare_cents, effective_from)
  values (v_service_id, 'seater', 45000, current_date);

  -- One trip per day for the next 7 days.
  for v_day in 0..6 loop
    insert into public.bus_trips (
      service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at,
      min_fare_cents, max_fare_cents, status
    )
    values (
      v_service_id, v_operator_id, v_route_id, v_bus_id,
      current_date + v_day,
      (current_date + v_day) + time '06:00',
      (current_date + v_day) + time '16:00',
      45000, 45000, 'scheduled'
    )
    returning id into v_trip_id;
    -- trip_seats + available_seats are populated by the generate_trip_seats trigger.
  end loop;
end $$;
