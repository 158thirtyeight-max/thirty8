-- =========================================================================
-- Operator trip list for Operations -> Bus -> Trips.
--
-- One authoritative read: route names, bus registration, times and per-trip seat
-- counts computed from trip_seats (never from ticket counts):
--   sold  = booked + boarded seats
--   held  = seats under an active, unexpired hold (an expired hold counts as free)
-- Buckets are status driven: upcoming = scheduled, active = boarding/departed,
-- completed = arrived, cancelled = cancelled.
-- =========================================================================

create or replace function public.list_operator_trips(
  p_operator_id uuid,
  p_bucket text default 'upcoming',
  p_bus_id uuid default null,
  p_limit int default 50,
  p_offset int default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_items jsonb;
  v_counts jsonb;
begin
  if not (private.is_operator_staff(p_operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  if p_bucket not in ('upcoming', 'active', 'completed', 'cancelled') then
    raise exception 'Unknown bucket %', p_bucket;
  end if;

  select jsonb_build_object(
    'upcoming',  count(*) filter (where t.status = 'scheduled'),
    'active',    count(*) filter (where t.status in ('boarding', 'departed')),
    'completed', count(*) filter (where t.status = 'arrived'),
    'cancelled', count(*) filter (where t.status = 'cancelled')
  ) into v_counts
  from public.bus_trips t
  where t.operator_id = p_operator_id and (p_bus_id is null or t.bus_id = p_bus_id);

  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.sort_key), '[]'::jsonb) into v_items
  from (
    select
      t.id,
      t.bus_id,
      b.registration_number as bus_registration,
      b.name as bus_name,
      src.name as source_name,
      dst.name as destination_name,
      t.travel_date,
      t.departure_at,
      t.arrival_at,
      t.status,
      seats.total_seats,
      seats.sold_seats,
      seats.held_seats,
      seats.blocked_seats,
      seats.total_seats - seats.sold_seats - seats.held_seats - seats.blocked_seats as available_seats,
      case when p_bucket in ('upcoming', 'active')
           then extract(epoch from t.departure_at) else -extract(epoch from t.departure_at) end as sort_key
    from public.bus_trips t
    join public.buses b on b.id = t.bus_id
    join public.bus_routes r on r.id = t.route_id
    left join public.locations src on src.id = r.source_city_id
    left join public.locations dst on dst.id = r.destination_city_id
    cross join lateral (
      select
        count(*)::int as total_seats,
        count(*) filter (where ts.status in ('booked', 'boarded'))::int as sold_seats,
        count(*) filter (where ts.status = 'held' and exists (
          select 1 from public.seat_holds h
          where h.id = ts.hold_id and h.status = 'active' and h.expires_at > now()))::int as held_seats,
        count(*) filter (where ts.status = 'blocked')::int as blocked_seats
      from public.trip_seats ts where ts.trip_id = t.id
    ) seats
    where t.operator_id = p_operator_id
      and (p_bus_id is null or t.bus_id = p_bus_id)
      and (case p_bucket
             when 'upcoming' then t.status = 'scheduled'
             when 'active' then t.status in ('boarding', 'departed')
             when 'completed' then t.status = 'arrived'
             else t.status = 'cancelled' end)
    order by 16
    limit greatest(least(p_limit, 200), 1) offset greatest(p_offset, 0)
  ) x;

  return jsonb_build_object('counts', v_counts, 'items', v_items);
end;
$$;
revoke execute on function public.list_operator_trips(uuid, text, uuid, int, int) from public, anon;
grant execute on function public.list_operator_trips(uuid, text, uuid, int, int) to authenticated;
