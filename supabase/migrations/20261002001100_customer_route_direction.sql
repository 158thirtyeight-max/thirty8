-- =========================================================================
-- Customer read functions expose the journey direction (outbound / return) and the
-- service schedule. Additive only: existing keys are unchanged. Customers still read
-- nothing but the live, approved routes (revision tables have no customer access).
-- =========================================================================

drop function public.search_trips(uuid, uuid, date, uuid, uuid);
create or replace function public.search_trips(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date,
  p_pickup_location_id uuid default null,
  p_drop_location_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_direct jsonb;
  v_connected jsonb;
begin
  -- Only active main locations are searchable.
  if not exists (select 1 from public.locations where id = p_source_city_id and is_active and is_main_route_enabled)
     or not exists (select 1 from public.locations where id = p_destination_city_id and is_active and is_main_route_enabled) then
    return jsonb_build_object('direct', '[]'::jsonb, 'connected', '[]'::jsonb);
  end if;

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
    'min_fare_cents', fr.min_cents,
    'max_fare_cents', fr.max_cents,
    'currency_code', t.currency_code,
    'direction', sv.direction
  ) order by t.departure_at), '[]'::jsonb)
  into v_direct
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  join public.operators o on o.id = t.operator_id
  join public.buses bs on bs.id = t.bus_id
  join public.bus_routes r on r.id = t.route_id
  cross join lateral private.trip_fare_range(t.id, p_source_city_id, p_destination_city_id, p_pickup_location_id, p_drop_location_id) fr
  where t.travel_date = p_travel_date
    and t.status = 'scheduled'
    and private.trip_is_open_for_booking(t.id)
    and private.is_bus_bookable(t.bus_id)
    and (
      (p_pickup_location_id is null and p_drop_location_id is null
       and sv.service_source_city_id = p_source_city_id and sv.service_dest_city_id = p_destination_city_id)
      or exists (
        select 1
        from public.boarding_points bs
        join public.dropping_points dd on dd.route_id = bs.route_id and dd.sequence_no > bs.sequence_no
        where bs.route_id = t.route_id and bs.is_active and dd.is_active
          and bs.city_id = p_source_city_id and dd.city_id = p_destination_city_id
          -- an exact pickup / drop location must be a stop the bus serves between the searched ends
          and (p_pickup_location_id is null or exists (
                select 1 from public.boarding_points bp
                where bp.route_id = t.route_id and bp.is_active and bp.city_id = p_pickup_location_id
                  and bp.sequence_no >= bs.sequence_no and bp.sequence_no < dd.sequence_no))
          and (p_drop_location_id is null or exists (
                select 1 from public.dropping_points dp
                where dp.route_id = t.route_id and dp.is_active and dp.city_id = p_drop_location_id
                  and dp.sequence_no > bs.sequence_no and dp.sequence_no <= dd.sequence_no))
      )
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'transfer_city_id', s1.service_dest_city_id,
    'leg1', jsonb_build_object(
      'trip_id', t1.id, 'service_id', s1.id, 'operator_id', o1.id, 'operator_name', o1.name,
      'departure_at', t1.departure_at, 'arrival_at', t1.arrival_at,
      'min_fare_cents', f1.min_cents, 'available_seats', t1.available_seats
    ),
    'leg2', jsonb_build_object(
      'trip_id', t2.id, 'service_id', s2.id, 'operator_id', o2.id, 'operator_name', o2.name,
      'departure_at', t2.departure_at, 'arrival_at', t2.arrival_at,
      'min_fare_cents', f2.min_cents, 'available_seats', t2.available_seats
    ),
    'total_min_fare_cents', coalesce(f1.min_cents, 0) + coalesce(f2.min_cents, 0)
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
  cross join lateral private.trip_fare_range(t1.id, s1.service_source_city_id, s1.service_dest_city_id) f1
  cross join lateral private.trip_fare_range(t2.id, s2.service_source_city_id, s2.service_dest_city_id) f2
  where s1.service_source_city_id = p_source_city_id
    and private.is_bus_bookable(t1.bus_id)
    and private.is_bus_bookable(t2.bus_id)
    and private.trip_is_open_for_booking(t1.id)
    and private.trip_is_open_for_booking(t2.id)
    and p_pickup_location_id is null and p_drop_location_id is null
    and t2.departure_at >= t1.arrival_at + interval '15 minutes'
    and t2.departure_at <= t1.arrival_at + interval '6 hours';

  return jsonb_build_object('direct', v_direct, 'connected', v_connected);
end;
$$;

revoke execute on function public.search_trips(uuid, uuid, date, uuid, uuid) from public;
grant execute on function public.search_trips(uuid, uuid, date, uuid, uuid) to anon, authenticated;

-- Stops of a bookable trip plus its direction and the service schedule.
create or replace function public.get_trip_points(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_route uuid;
  v_dir text;
  v_dep time;
  v_days smallint[];
  v_src text;
  v_dst text;
begin
  select t.route_id, sv.direction, sv.default_departure_time, sv.operating_days, ls.name, ld.name
  into v_route, v_dir, v_dep, v_days, v_src, v_dst
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  left join public.locations ls on ls.id = sv.service_source_city_id
  left join public.locations ld on ld.id = sv.service_dest_city_id
  where t.id = p_trip_id
    and private.is_bus_bookable(t.bus_id)
    and private.trip_is_open_for_booking(t.id);
  if v_route is null then
    return null;
  end if;

  return jsonb_build_object(
    'route_id', v_route,
    'direction', v_dir,
    'source_name', v_src,
    'destination_name', v_dst,
    'departure_time', v_dep,
    'operating_days', to_jsonb(v_days),
    'boarding', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.sequence_no)
      from public.boarding_points b where b.route_id = v_route and b.is_active), '[]'::jsonb),
    'dropping', coalesce((
      select jsonb_agg(to_jsonb(d) order by d.sequence_no)
      from public.dropping_points d where d.route_id = v_route and d.is_active), '[]'::jsonb)
  );
end;
$function$;

revoke execute on function public.get_trip_points(uuid) from public;
grant execute on function public.get_trip_points(uuid) to anon, authenticated;
