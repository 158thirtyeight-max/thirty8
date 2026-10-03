-- =========================================================================
-- Per-trip booking analytics for the operator dashboard.
--   get_trip_booking_stats: capacity / confirmed / pending reservations / available / blocked /
--     cancelled, computed from the seat inventory (a booking with 3 seats counts 3), plus a
--     status distribution for the chart.
--   get_trip_booking_trend: cumulative confirmed seats over time from the booking status
--     history (confirmations add the booking's seats on this trip, cancellations of confirmed
--     bookings subtract them), with the departure time for a "days before departure" axis.
-- Staff of the trip's operator (or platform admins) only. No passenger data.
-- =========================================================================

create or replace function public.get_trip_booking_stats(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips := private.trip_for_staff(p_trip_id, false);
  c record;
  v_cancelled_bookings int; v_cancelled_seats int; v_failed int;
begin
  select
    count(*)::int as total,
    (count(*) filter (where st in ('booked', 'boarded')))::int as confirmed,
    (count(*) filter (where st = 'held'))::int as pending,
    (count(*) filter (where st = 'available'))::int as available,
    (count(*) filter (where st = 'blocked'))::int as blocked
  into c
  from (select private.effective_seat_status(ts.status, ts.hold_id) as st from public.trip_seats ts where ts.trip_id = p_trip_id) q;

  select count(distinct bi.booking_id)::int, count(*)::int into v_cancelled_bookings, v_cancelled_seats
    from public.booking_items bi where bi.trip_id = p_trip_id and bi.status = 'cancelled';
  select count(distinct bi.booking_id)::int into v_failed
    from public.booking_items bi where bi.trip_id = p_trip_id and bi.status in ('failed', 'expired');

  return jsonb_build_object(
    'trip_id', v_trip.id,
    'as_of', now(),
    'capacity', c.total,
    'confirmed_seats', c.confirmed,
    'pending_reservations', c.pending,
    'available_seats', c.available,
    'blocked_seats', c.blocked,
    'cancelled_bookings', v_cancelled_bookings,
    'cancelled_seats', v_cancelled_seats,
    'failed_or_expired_bookings', v_failed,
    'occupancy_pct', case when c.total = 0 then 0 else round(100.0 * c.confirmed / c.total, 1) end,
    'distribution', jsonb_build_array(
      jsonb_build_object('status', 'confirmed', 'seats', c.confirmed),
      jsonb_build_object('status', 'pending', 'seats', c.pending),
      jsonb_build_object('status', 'cancelled', 'seats', v_cancelled_seats),
      jsonb_build_object('status', 'blocked', 'seats', c.blocked),
      jsonb_build_object('status', 'available', 'seats', c.available))
  );
end;
$$;

create or replace function public.get_trip_booking_trend(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips := private.trip_for_staff(p_trip_id, false);
  v_capacity int;
  v_points jsonb;
begin
  select count(*)::int into v_capacity from public.trip_seats where trip_id = p_trip_id;

  with seats_per as (
    select bi.booking_id, count(*)::int as n from public.booking_items bi where bi.trip_id = p_trip_id group by bi.booking_id
  ), ev as (
    select h.created_at as at,
           case when h.to_status = 'confirmed' then sp.n else -sp.n end as delta
    from public.booking_status_history h
    join seats_per sp on sp.booking_id = h.booking_id
    where h.to_status = 'confirmed' or (h.from_status = 'confirmed' and h.to_status = 'cancelled')
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'at', e.at, 'delta', e.delta, 'cumulative_seats', e.cum,
      'days_before_departure', round(extract(epoch from (v_trip.departure_at - e.at)) / 86400.0, 2)) order by e.at), '[]'::jsonb)
  into v_points
  from (select at, delta, sum(delta) over (order by at, delta rows unbounded preceding)::int as cum from ev) e;

  return jsonb_build_object('trip_id', p_trip_id, 'departure_at', v_trip.departure_at, 'capacity', v_capacity, 'points', v_points);
end;
$$;

revoke execute on function public.get_trip_booking_stats(uuid) from public, anon;
revoke execute on function public.get_trip_booking_trend(uuid) from public, anon;
grant execute on function public.get_trip_booking_stats(uuid) to authenticated;
grant execute on function public.get_trip_booking_trend(uuid) to authenticated;
