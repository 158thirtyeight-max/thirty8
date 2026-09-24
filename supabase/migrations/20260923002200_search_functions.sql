-- =========================================================================
-- Search: city autocomplete, trip search (direct + one-transfer), seat map.
--
-- These are plain Postgres functions exposed as PostgREST RPCs
-- (POST /rest/v1/rpc/<name>), not Deno Edge Functions — nothing here calls
-- an external service, so there's no reason to leave SQL for a second
-- runtime. Real Edge Functions start in Phase 5 (Razorpay) and Phase 6
-- (FCM), where an actual outbound HTTP call is unavoidable.
-- =========================================================================

create or replace function public.search_cities(p_query text default '', p_limit integer default 10)
returns setof public.cities
language sql
stable
set search_path = ''
as $$
  select c.*
  from public.cities c
  where c.is_active
  order by
    case when p_query is null or p_query = '' then 0 else extensions.similarity(c.name, p_query) end desc,
    c.name asc
  limit greatest(p_limit, 1);
$$;

-- Trip search for a source/destination/date: direct services plus
-- single-transfer connections through a common intermediate city (the
-- Port Blair -> Rangat -> Diglipur segment-change pattern).
create or replace function public.search_trips(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_direct jsonb;
  v_connected jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'trip_id', t.id,
    'service_id', sv.id,
    'operator_id', o.id,
    'operator_name', o.name,
    'operator_rating', o.rating,
    'bus_id', bs.id,
    'bus_type', bs.bus_type,
    'amenities', bs.amenities,
    'departure_at', t.departure_at,
    'arrival_at', t.arrival_at,
    'available_seats', t.available_seats,
    'min_fare_cents', t.min_fare_cents,
    'max_fare_cents', t.max_fare_cents,
    'currency_code', t.currency_code
  ) order by t.departure_at), '[]'::jsonb)
  into v_direct
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  join public.operators o on o.id = t.operator_id
  join public.buses bs on bs.id = t.bus_id
  where t.travel_date = p_travel_date
    and t.status = 'scheduled'
    and sv.service_source_city_id = p_source_city_id
    and sv.service_dest_city_id = p_destination_city_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'transfer_city_id', s1.service_dest_city_id,
    'leg1', jsonb_build_object(
      'trip_id', t1.id, 'service_id', s1.id, 'operator_id', o1.id, 'operator_name', o1.name,
      'departure_at', t1.departure_at, 'arrival_at', t1.arrival_at,
      'min_fare_cents', t1.min_fare_cents, 'available_seats', t1.available_seats
    ),
    'leg2', jsonb_build_object(
      'trip_id', t2.id, 'service_id', s2.id, 'operator_id', o2.id, 'operator_name', o2.name,
      'departure_at', t2.departure_at, 'arrival_at', t2.arrival_at,
      'min_fare_cents', t2.min_fare_cents, 'available_seats', t2.available_seats
    ),
    'total_min_fare_cents', coalesce(t1.min_fare_cents, 0) + coalesce(t2.min_fare_cents, 0)
  ) order by t1.departure_at), '[]'::jsonb)
  into v_connected
  from public.bus_services s1
  join public.bus_trips t1 on t1.service_id = s1.id
    and t1.travel_date = p_travel_date
    and t1.status = 'scheduled'
  join public.operators o1 on o1.id = t1.operator_id
  join public.bus_services s2 on s2.service_source_city_id = s1.service_dest_city_id
    and s2.service_dest_city_id = p_destination_city_id
  join public.bus_trips t2 on t2.service_id = s2.id
    and t2.status = 'scheduled'
    and t2.travel_date between p_travel_date and p_travel_date + 1
  join public.operators o2 on o2.id = t2.operator_id
  where s1.service_source_city_id = p_source_city_id
    and t2.departure_at >= t1.arrival_at + interval '15 minutes'
    and t2.departure_at <= t1.arrival_at + interval '6 hours';

  return jsonb_build_object('direct', v_direct, 'connected', v_connected);
end;
$$;

-- Full seat map for one trip: bus layout + every seat's live status/fare,
-- shaped so the client can render it in a single call.
create or replace function public.get_trip_seat_map(p_trip_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'trip_id', t.id,
    'bus_id', t.bus_id,
    'layout', bl.layout_json,
    'deck_count', bl.deck_count,
    'seats', coalesce(jsonb_agg(jsonb_build_object(
      'trip_seat_id', ts.id,
      'seat_id', s.id,
      'seat_code', s.seat_code,
      'deck', s.deck,
      'row_no', s.row_no,
      'col_no', s.col_no,
      'seat_type', s.seat_type,
      'gender_restriction', s.gender_restriction,
      'status', ts.status,
      'fare_cents', ts.fare_cents
    ) order by s.deck, s.row_no, s.col_no), '[]'::jsonb)
  )
  from public.bus_trips t
  join public.bus_layouts bl on bl.bus_id = t.bus_id and bl.is_active
  join public.trip_seats ts on ts.trip_id = t.id
  join public.seats s on s.id = ts.seat_id
  where t.id = p_trip_id
  group by t.id, t.bus_id, bl.layout_json, bl.deck_count;
$$;

grant execute on function public.search_cities(text, integer) to anon, authenticated;
grant execute on function public.search_trips(uuid, uuid, date) to anon, authenticated;
grant execute on function public.get_trip_seat_map(uuid) to anon, authenticated;
