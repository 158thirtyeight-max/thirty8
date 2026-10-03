-- =========================================================================
-- Timeline scheduling: the server independently validates the chronology of a journey
-- (offsets are minutes after the origin departs; departure = arrival + dwell is computed by the clients
-- and persisted in the existing arrival_offset_min / departure_offset_min columns).
--   * origin departs at offset 0, destination arrives exactly at the journey duration
--   * stops are chronological, dwell <= 6 h, journey <= 72 h
--   * a generated reverse route no longer copies outbound clock times: its departure is left for the
--     user to set (stop order, pickup / drop and dwell times are mirrored)
-- =========================================================================

create or replace function private.validate_route_journey(
  p_route_id uuid, p_source uuid, p_dest uuid, p_departure time, p_duration integer,
  p_days smallint[], p_stops jsonb, p_strict boolean default true
)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  e text[] := '{}';
  n integer;
  idx integer := 0;
  stop jsonb;
  city uuid;
  loc public.locations;
  used boolean;
  seen uuid[] := '{}';
  is_b boolean;
  is_d boolean;
  arr integer;
  dep integer;
  last_end integer := null;
  missing integer := 0;
begin
  if p_source is null or p_dest is null or p_source = p_dest then
    e := e || 'Origin and destination must be two different cities'::text;
  end if;
  if p_departure is null then e := e || 'Departure time is required'::text; end if;
  if p_duration is null or p_duration < 1 then e := e || 'Estimated journey duration is required'::text; end if;
  if p_days is null or coalesce(array_length(p_days, 1), 0) = 0 then e := e || 'Select at least one operating day'::text; end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then return e || 'Stops must be an array'::text; end if;
  n := jsonb_array_length(p_stops);
  if n < 2 or n > 30 then return e || 'A route needs between 2 and 30 stops'::text; end if;
  if not coalesce((p_stops -> 0 ->> 'is_boarding')::boolean, false) then e := e || 'The origin must be a boarding point'::text; end if;
  if not coalesce((p_stops -> (n - 1) ->> 'is_dropping')::boolean, false) then e := e || 'The destination must be a dropping point'::text; end if;

  for stop in select * from jsonb_array_elements(p_stops) loop
    idx := idx + 1;
    city := nullif(stop ->> 'city_id', '')::uuid;
    if city is null then e := e || format('Stop %s needs a location', idx); continue; end if;
    select * into loc from public.locations where id = city;
    if loc.id is null then e := e || format('Stop %s: location not found', idx); continue; end if;
    used := p_route_id is not null and (
      exists (select 1 from public.boarding_points bp where bp.route_id = p_route_id and bp.city_id = city)
      or exists (select 1 from public.dropping_points dp where dp.route_id = p_route_id and dp.city_id = city));
    is_b := coalesce((stop ->> 'is_boarding')::boolean, false);
    is_d := coalesce((stop ->> 'is_dropping')::boolean, false);
    if not loc.is_active and not used then e := e || format('Stop %s: %s is disabled', idx, loc.name); end if;
    if (idx = 1 or idx = n) and not loc.is_main_route_enabled and not used then
      e := e || format('Stop %s: %s is not a main route location', idx, loc.name);
    end if;
    if idx = 1 and city is distinct from p_source then e := e || 'The first stop must be the origin location'::text; end if;
    if idx = n and city is distinct from p_dest then e := e || 'The last stop must be the destination location'::text; end if;
    if city = any (seen) then e := e || format('A location can appear only once on a route (stop %s)', idx); end if;
    seen := seen || city;
    if not is_b and not is_d then e := e || format('Stop %s: choose pickup, drop or both', idx); end if;
    if is_b and not loc.is_pickup_enabled and not used then e := e || format('Stop %s: pickup is not enabled at %s', idx, loc.name); end if;
    if is_d and not loc.is_drop_enabled and not used then e := e || format('Stop %s: drop is not enabled at %s', idx, loc.name); end if;

    if p_strict then
      arr := nullif(stop ->> 'arrival_offset_min', '')::integer;
      dep := nullif(stop ->> 'departure_offset_min', '')::integer;
      if (is_b and dep is null) or (is_d and arr is null) then missing := missing + 1; end if;
      if arr is not null and last_end is not null and arr < last_end then
        e := e || format('Stop %s is reached before the previous stop is left', idx);
      end if;
      if arr is not null and dep is not null and dep < arr then
        e := e || format('Stop %s departs before it arrives', idx);
      end if;
      last_end := coalesce(dep, arr, last_end);
      -- schedule shape: the origin departs at offset 0, the destination arrives exactly at the journey
      -- duration, intermediate stops dwell for a bounded time
      if idx = 1 and ((arr is not null and arr <> 0) or (dep is not null and dep <> 0)) then
        e := e || 'The origin must depart at the start of the journey'::text;
      end if;
      if idx = n and arr is not null and p_duration is not null and arr <> p_duration then
        e := e || 'The destination arrival must match the journey duration'::text;
      end if;
      if idx > 1 and idx < n and arr is not null and dep is not null and dep - arr > 360 then
        e := e || format('Stop %s waits over 6 hours', idx);
      end if;
    end if;
  end loop;

  if p_strict then
    if missing > 0 then e := e || 'Arrival / departure times are missing for some stops'::text; end if;
    if p_duration is not null and last_end is not null and last_end > p_duration then
      e := e || 'Stop times run past the estimated journey duration'::text;
    end if;
    if p_duration is not null and p_duration > 72 * 60 then e := e || 'Journey duration looks too long (over 72 hours)'::text; end if;
  end if;
  return e;
end;
$$;

create or replace function public.generate_reverse_route(p_revision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_out public.route_revision_journeys;
  v_old public.route_revision_journeys;
  v_dur integer;
  v_dep time;
  v_off smallint;
  v_days smallint[];
  v_jid uuid;
begin
  v_rev := private.load_revision_for_edit(p_revision_id);
  select * into v_out from public.route_revision_journeys where revision_id = p_revision_id and direction = 'outbound';
  if v_out.id is null then raise exception 'Configure the outbound journey first'; end if;
  v_dur := v_out.est_duration_min;
  if v_dur is null then raise exception 'Set the outbound journey duration first'; end if;
  select * into v_old from public.route_revision_journeys where revision_id = p_revision_id and direction = 'return';

  v_off := coalesce(v_old.departure_day_offset,
    case when v_out.departure_time is not null
          and extract(epoch from v_out.departure_time) / 60 + v_dur >= 1440 then 1 else 0 end);
  -- the return keeps its own departure if it already has one; otherwise it is left for the user to
  -- set (outbound clock times are never copied). Stop order, pickup / drop and dwell times are mirrored.
  v_dep := v_old.departure_time;
  v_days := case when coalesce(array_length(v_old.operating_days, 1), 0) > 0 then v_old.operating_days
    else coalesce((select array_agg((((x - 1 + v_off) % 7) + 1)::smallint order by x)
                   from unnest(v_out.operating_days) x), '{}') end;

  delete from public.route_revision_journeys where revision_id = p_revision_id and direction = 'return';
  insert into public.route_revision_journeys (revision_id, direction, source_city_id, destination_city_id,
    departure_time, est_duration_min, operating_days, departure_day_offset, reverse_generated)
  values (p_revision_id, 'return', v_out.destination_city_id, v_out.source_city_id, v_dep, v_dur, v_days, v_off, true)
  returning id into v_jid;

  insert into public.route_revision_stops (journey_id, sequence_no, city_id, arrival_offset_min, departure_offset_min,
                                           is_boarding, is_dropping, address, latitude, longitude)
  select v_jid, (row_number() over (order by s.sequence_no desc))::integer, s.city_id,
         v_dur - coalesce(s.departure_offset_min, s.arrival_offset_min, 0),
         v_dur - coalesce(s.arrival_offset_min, s.departure_offset_min, 0),
         s.is_dropping, s.is_boarding, s.address, s.latitude, s.longitude
  from public.route_revision_stops s where s.journey_id = v_out.id;

  update public.route_revisions set trip_type = 'round_trip' where id = p_revision_id;
  return private.validate_revision(p_revision_id);
end;
$$;
