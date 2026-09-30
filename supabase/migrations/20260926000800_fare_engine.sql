-- =========================================================================
-- Fare configuration and the single authoritative fare engine (Phase 9)
--
-- Before this migration fares were computed in three places that disagreed:
--   * search_trips returned bus_trips.min/max_fare_cents (static, per trip)
--   * get_trip_seat_map / create_seat_hold used trip_seats.fare_cents
--   * create_booking summed trip_seats.fare_cents and ignored the boarding /
--     dropping points it stored
-- Now every price comes from private.resolve_seat_fare(): the most specific
-- active fare rule for (service, seat, boarding point, dropping point, date),
-- plus the service's extra charges, falling back to the legacy per-trip fare
-- when no rule exists. search, seat map, hold quote and booking all call it.
--
-- Also gates customer-facing availability on private.is_bus_bookable()
-- (operator approved + bus active + bus lifecycle active). Existing legacy
-- buses are active, so they stay bookable.
-- =========================================================================

-- ---------------------------------------------------------------------
-- Data model
-- ---------------------------------------------------------------------
alter table public.seats
  add column category text check (category is null or category ~ '^[a-z_]{2,20}$');

alter table public.fare_rules
  add column from_boarding_point_id uuid references public.boarding_points (id) on delete cascade,
  add column to_dropping_point_id uuid references public.dropping_points (id) on delete cascade,
  add column berth text check (berth is null or berth in ('upper', 'lower')),
  add column seat_category text check (seat_category is null or seat_category ~ '^[a-z_]{2,20}$'),
  add constraint fare_rules_amount_chk check (base_fare_cents <= 10000000),
  add constraint fare_rules_dates_chk check (effective_to is null or effective_to >= effective_from);

create index fare_rules_from_point_idx on public.fare_rules (from_boarding_point_id) where from_boarding_point_id is not null;
create index fare_rules_to_point_idx on public.fare_rules (to_dropping_point_id) where to_dropping_point_id is not null;

create unique index fare_rules_dedupe_idx on public.fare_rules (
  service_id, seat_type, coalesce(berth, ''), coalesce(seat_category, ''),
  coalesce(from_boarding_point_id, '00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(to_dropping_point_id, '00000000-0000-0000-0000-000000000000'::uuid),
  effective_from
);

-- Extra charges added on top of every seat's fare (e.g. platform/convenience fee, GST).
create table public.fare_charges (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.bus_services (id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  kind text not null check (kind in ('flat', 'percent')),
  flat_cents integer check (flat_cents is null or (flat_cents >= 0 and flat_cents <= 10000000)),
  percent numeric(5, 2) check (percent is null or (percent >= 0 and percent <= 100)),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint fare_charges_kind_value_chk check (
    (kind = 'flat' and flat_cents is not null and percent is null)
    or (kind = 'percent' and percent is not null and flat_cents is null)
  )
);

create index fare_charges_service_id_idx on public.fare_charges (service_id);

alter table public.fare_charges enable row level security;
create policy fare_charges_select_public on public.fare_charges for select to anon, authenticated using (true);
create policy fare_charges_operator_manage on public.fare_charges for all to authenticated
  using (exists (select 1 from public.bus_services s where s.id = fare_charges.service_id and private.is_operator_staff(s.operator_id)))
  with check (exists (select 1 from public.bus_services s where s.id = fare_charges.service_id and private.is_operator_staff(s.operator_id)));
create policy fare_charges_admin_all on public.fare_charges for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- A hold remembers the points and per-seat prices it was quoted at.
alter table public.seat_holds
  add column boarding_point_id uuid references public.boarding_points (id),
  add column dropping_point_id uuid references public.dropping_points (id),
  add column quoted_fares jsonb;

create index seat_holds_boarding_point_idx on public.seat_holds (boarding_point_id) where boarding_point_id is not null;
create index seat_holds_dropping_point_idx on public.seat_holds (dropping_point_id) where dropping_point_id is not null;

-- ---------------------------------------------------------------------
-- Bookability gate
-- ---------------------------------------------------------------------
create or replace function private.is_bus_bookable(p_bus_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.buses b
    join public.operators o on o.id = b.operator_id
    where b.id = p_bus_id
      and b.status = 'active'
      and b.lifecycle_status = 'active'
      and o.status = 'approved'
  );
$$;

revoke execute on function private.is_bus_bookable(uuid) from public;
grant execute on function private.is_bus_bookable(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- THE fare engine. Everything that shows or charges a price calls this.
--
-- Most specific rule wins:
--   boarding + dropping pair  >  dropping only  >  boarding only  >  base,
-- then a seat-category match, then a berth match, then the newest rule.
-- A rule only applies when its point/berth/category columns are null or equal
-- the seat's/journey's. Charges (flat per seat, percent of the fare) are added.
-- With no matching rule the legacy per-trip fare is used (p_fallback_cents).
-- ---------------------------------------------------------------------
create or replace function private.resolve_seat_fare(
  p_service_id uuid,
  p_travel_date date,
  p_seat_id uuid,
  p_boarding_point_id uuid,
  p_dropping_point_id uuid,
  p_fallback_cents integer
)
returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_seat public.seats;
  v_base integer;
  v_flat integer;
  v_pct numeric;
begin
  select * into v_seat from public.seats where id = p_seat_id;

  select fr.base_fare_cents into v_base
  from public.fare_rules fr
  where fr.service_id = p_service_id
    and fr.seat_type = v_seat.seat_type
    and (fr.berth is null or fr.berth = v_seat.berth)
    and (fr.seat_category is null or fr.seat_category = v_seat.category)
    and (fr.from_boarding_point_id is null or fr.from_boarding_point_id = p_boarding_point_id)
    and (fr.to_dropping_point_id is null or fr.to_dropping_point_id = p_dropping_point_id)
    and fr.effective_from <= p_travel_date
    and (fr.effective_to is null or fr.effective_to >= p_travel_date)
  order by
    case when fr.from_boarding_point_id is not null and fr.to_dropping_point_id is not null then 3
         when fr.to_dropping_point_id is not null then 2
         when fr.from_boarding_point_id is not null then 1
         else 0 end desc,
    (fr.seat_category is not null) desc,
    (fr.berth is not null) desc,
    fr.effective_from desc, fr.created_at desc, fr.id
  limit 1;

  v_base := coalesce(v_base, p_fallback_cents, 0);

  select coalesce(sum(flat_cents) filter (where kind = 'flat'), 0),
         coalesce(sum(percent) filter (where kind = 'percent'), 0)
    into v_flat, v_pct
  from public.fare_charges where service_id = p_service_id and active;

  return v_base + v_flat + round(v_base * v_pct / 100.0)::integer;
end;
$$;

revoke execute on function private.resolve_seat_fare(uuid, date, uuid, uuid, uuid, integer) from public;
grant execute on function private.resolve_seat_fare(uuid, date, uuid, uuid, uuid, integer) to anon, authenticated;

-- Fare of one seat of one trip for a boarding/dropping choice (points may be null).
create or replace function private.calc_seat_fare(
  p_trip_id uuid,
  p_seat_id uuid,
  p_boarding_point_id uuid,
  p_dropping_point_id uuid
)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select private.resolve_seat_fare(
    t.service_id, t.travel_date, p_seat_id, p_boarding_point_id, p_dropping_point_id,
    coalesce(ts.fare_cents, t.min_fare_cents, 0)
  )
  from public.bus_trips t
  left join public.trip_seats ts on ts.trip_id = t.id and ts.seat_id = p_seat_id
  where t.id = p_trip_id;
$$;

revoke execute on function private.calc_seat_fare(uuid, uuid, uuid, uuid) from public;
grant execute on function private.calc_seat_fare(uuid, uuid, uuid, uuid) to anon, authenticated;

-- Raises unless the points are a valid boarding -> dropping choice for the trip's
-- route. Both null is allowed (base-fare / legacy path). On routes built by the
-- setup wizard sequence numbers are shared, so boarding must come before
-- dropping; legacy routes number the two lists independently, so the order
-- check is skipped there.
create or replace function private.validate_trip_points(
  p_trip_id uuid,
  p_boarding_point_id uuid,
  p_dropping_point_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_route_id uuid;
  v_wizard boolean;
  v_bseq integer;
  v_dseq integer;
begin
  if p_boarding_point_id is null and p_dropping_point_id is null then
    return;
  end if;
  if p_boarding_point_id is null or p_dropping_point_id is null then
    raise exception 'invalid_points: choose both a boarding and a dropping point';
  end if;

  select t.route_id into v_route_id from public.bus_trips t where t.id = p_trip_id;
  select (r.bus_id is not null) into v_wizard from public.bus_routes r where r.id = v_route_id;

  select sequence_no into v_bseq from public.boarding_points
  where id = p_boarding_point_id and route_id = v_route_id and is_active;
  select sequence_no into v_dseq from public.dropping_points
  where id = p_dropping_point_id and route_id = v_route_id and is_active;

  if v_bseq is null or v_dseq is null then
    raise exception 'invalid_points: the boarding or dropping point does not belong to this trip''s route';
  end if;
  if v_wizard and v_bseq >= v_dseq then
    raise exception 'invalid_points: the dropping point must come after the boarding point';
  end if;
end;
$$;

revoke execute on function private.validate_trip_points(uuid, uuid, uuid) from public;
grant execute on function private.validate_trip_points(uuid, uuid, uuid) to anon, authenticated;

-- Cheapest / dearest seat fare of a trip for a source -> destination city
-- search. Considers every boarding/dropping pair on the route whose stops are
-- in those cities (stops without a city belong to the service's own source /
-- destination city, which keeps legacy routes working); falls back to base
-- fares when there is no such pair.
create or replace function private.trip_fare_range(p_trip_id uuid, p_src_city_id uuid, p_dst_city_id uuid)
returns table (min_cents integer, max_cents integer)
language sql
stable
security definer
set search_path = ''
as $$
  with trip as (
    select t.id, t.service_id, t.route_id, t.travel_date, sv.service_source_city_id as src, sv.service_dest_city_id as dst,
           (r.bus_id is not null) as wizard
    from public.bus_trips t
    join public.bus_services sv on sv.id = t.service_id
    join public.bus_routes r on r.id = t.route_id
    where t.id = p_trip_id
  ),
  pairs as (
    select b.id as b_id, d.id as d_id
    from trip tr
    join public.boarding_points b on b.route_id = tr.route_id and b.is_active
    join public.dropping_points d on d.route_id = tr.route_id and d.is_active
    where coalesce(b.city_id, tr.src) = p_src_city_id
      and coalesce(d.city_id, tr.dst) = p_dst_city_id
      and (not tr.wizard or d.sequence_no > b.sequence_no)
  ),
  chosen as (
    select b_id, d_id from pairs
    union all
    select null::uuid, null::uuid where not exists (select 1 from pairs)
  ),
  seats as (
    select ts.seat_id, ts.fare_cents
    from public.trip_seats ts
    where ts.trip_id = p_trip_id
      and (ts.status = 'available'
           or not exists (select 1 from public.trip_seats x where x.trip_id = p_trip_id and x.status = 'available'))
  ),
  fares as (
    select private.resolve_seat_fare(tr.service_id, tr.travel_date, s.seat_id, c.b_id, c.d_id, s.fare_cents) as f
    from trip tr cross join chosen c cross join seats s
  )
  select min(f)::integer, max(f)::integer from fares;
$$;

revoke execute on function private.trip_fare_range(uuid, uuid, uuid) from public;
grant execute on function private.trip_fare_range(uuid, uuid, uuid) to anon, authenticated;

-- Trip inventory is priced by the engine (base fares; points are unknown at creation).
create or replace function private.generate_trip_seats()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.trip_seats (trip_id, seat_id, status, fare_cents)
  select
    new.id, s.id, 'available',
    private.resolve_seat_fare(new.service_id, new.travel_date, s.id, null, null, new.min_fare_cents)
  from public.seats s
  join public.bus_layouts bl on bl.id = s.bus_layout_id
  where bl.bus_id = new.bus_id
    and bl.is_active
    and s.kind = 'bookable';

  update public.bus_trips
  set available_seats = (select count(*) from public.trip_seats where trip_id = new.id and status = 'available')
  where id = new.id;

  return new;
end;
$$;

-- NOTE: search_trips and get_trip_seat_map are now SECURITY DEFINER. Invoker-rights
-- plpgsql cannot call into the `private` schema (no USAGE for anon/authenticated),
-- and both functions only return data that is already public (bookable trips of
-- approved operators), so definer rights add no exposure.
--
-- ---------------------------------------------------------------------
-- search_trips: fares from the engine, only bookable buses, and services whose
-- route passes through the searched cities (not just whole-route matches).
-- ---------------------------------------------------------------------
create or replace function public.search_trips(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date
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
    'currency_code', t.currency_code
  ) order by t.departure_at), '[]'::jsonb)
  into v_direct
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  join public.operators o on o.id = t.operator_id
  join public.buses bs on bs.id = t.bus_id
  join public.bus_routes r on r.id = t.route_id
  cross join lateral private.trip_fare_range(t.id, p_source_city_id, p_destination_city_id) fr
  where t.travel_date = p_travel_date
    and t.status = 'scheduled'
    and private.is_bus_bookable(t.bus_id)
    and (
      (sv.service_source_city_id = p_source_city_id and sv.service_dest_city_id = p_destination_city_id)
      or exists (
        select 1
        from public.boarding_points b
        join public.dropping_points d on d.route_id = b.route_id
        where b.route_id = t.route_id and b.is_active and d.is_active
          and b.city_id = p_source_city_id and d.city_id = p_destination_city_id
          and r.bus_id is not null and d.sequence_no > b.sequence_no
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
    and t2.departure_at >= t1.arrival_at + interval '15 minutes'
    and t2.departure_at <= t1.arrival_at + interval '6 hours';

  return jsonb_build_object('direct', v_direct, 'connected', v_connected);
end;
$$;

-- ---------------------------------------------------------------------
-- get_trip_seat_map: per-seat fares from the engine for the chosen points.
-- The old one-argument signature is dropped so PostgREST has no ambiguous overload;
-- callers passing only the trip id keep working through the defaults.
-- ---------------------------------------------------------------------
drop function public.get_trip_seat_map(uuid);

create or replace function public.get_trip_seat_map(
  p_trip_id uuid,
  p_boarding_point_id uuid default null,
  p_dropping_point_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform private.validate_trip_points(p_trip_id, p_boarding_point_id, p_dropping_point_id);

  select jsonb_build_object(
    'trip_id', t.id,
    'bus_id', t.bus_id,
    'layout', bl.layout_json,
    'deck_count', bl.deck_count,
    'boarding_point_id', p_boarding_point_id,
    'dropping_point_id', p_dropping_point_id,
    'seats', coalesce(jsonb_agg(jsonb_build_object(
      'trip_seat_id', ts.id,
      'seat_id', s.id,
      'seat_code', s.seat_code,
      'deck', s.deck,
      'row_no', s.row_no,
      'col_no', s.col_no,
      'seat_type', s.seat_type,
      'berth', s.berth,
      'category', s.category,
      'gender_restriction', s.gender_restriction,
      'status', ts.status,
      'fare_cents', private.resolve_seat_fare(t.service_id, t.travel_date, s.id, p_boarding_point_id, p_dropping_point_id, ts.fare_cents)
    ) order by s.deck, s.row_no, s.col_no), '[]'::jsonb)
  )
  into v_result
  from public.bus_trips t
  join public.bus_layouts bl on bl.bus_id = t.bus_id and bl.is_active
  join public.trip_seats ts on ts.trip_id = t.id
  join public.seats s on s.id = ts.seat_id
  where t.id = p_trip_id
    and private.is_bus_bookable(t.bus_id)
  group by t.id, t.bus_id, t.service_id, t.travel_date, bl.layout_json, bl.deck_count;

  return v_result;
end;
$$;

grant execute on function public.get_trip_seat_map(uuid, uuid, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- create_seat_hold: validates points, quotes per-seat prices from the engine
-- and stores the quote on the hold. Same locking as before.
-- ---------------------------------------------------------------------
drop function public.create_seat_hold(uuid, uuid[], integer);

create or replace function public.create_seat_hold(
  p_trip_id uuid,
  p_seat_ids uuid[],
  p_ttl_seconds integer default 300,
  p_boarding_point_id uuid default null,
  p_dropping_point_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_hold_id uuid;
  v_expires_at timestamptz := now() + make_interval(secs => p_ttl_seconds);
  v_locked_count integer;
  v_seat_count integer := coalesce(array_length(p_seat_ids, 1), 0);
  v_unavailable_count integer;
  v_bus_id uuid;
  v_quote jsonb;
begin
  if v_user_id is null then
    raise exception 'Must be authenticated to hold seats';
  end if;
  if v_seat_count = 0 then
    raise exception 'No seats specified';
  end if;

  select bus_id into v_bus_id from public.bus_trips where id = p_trip_id;
  if v_bus_id is null or not private.is_bus_bookable(v_bus_id) then
    raise exception 'bus_unavailable: this bus is not available for booking';
  end if;
  perform private.validate_trip_points(p_trip_id, p_boarding_point_id, p_dropping_point_id);

  -- Lock the candidate rows first: concurrent callers for the same seats
  -- serialize here, so only one transaction proceeds past this point at a time.
  perform 1
  from public.trip_seats ts
  where ts.trip_id = p_trip_id
    and ts.seat_id = any (p_seat_ids)
  for update;

  select count(*) into v_locked_count
  from public.trip_seats ts
  where ts.trip_id = p_trip_id and ts.seat_id = any (p_seat_ids);

  if v_locked_count <> v_seat_count then
    raise exception 'One or more seats do not exist on this trip';
  end if;

  -- Opportunistically reclaim seats whose hold expired but pg_cron hasn't
  -- swept them yet, so a caller isn't blocked by a stale hold.
  update public.trip_seats ts
  set status = 'available', hold_id = null
  from public.seat_holds sh
  where ts.hold_id = sh.id
    and ts.trip_id = p_trip_id
    and ts.seat_id = any (p_seat_ids)
    and ts.status = 'held'
    and sh.status = 'active'
    and sh.expires_at < now();

  select count(*) into v_unavailable_count
  from public.trip_seats ts
  where ts.trip_id = p_trip_id
    and ts.seat_id = any (p_seat_ids)
    and ts.status <> 'available';

  if v_unavailable_count > 0 then
    raise exception 'seat_unavailable: one or more selected seats are no longer available';
  end if;

  select jsonb_object_agg(sid::text, private.calc_seat_fare(p_trip_id, sid, p_boarding_point_id, p_dropping_point_id))
    into v_quote
  from unnest(p_seat_ids) sid;

  insert into public.seat_holds (trip_id, user_id, expires_at, boarding_point_id, dropping_point_id, quoted_fares)
  values (p_trip_id, v_user_id, v_expires_at, p_boarding_point_id, p_dropping_point_id, v_quote)
  returning id into v_hold_id;

  update public.trip_seats ts
  set status = 'held', hold_id = v_hold_id
  where ts.trip_id = p_trip_id and ts.seat_id = any (p_seat_ids);

  update public.bus_trips t
  set available_seats = (select count(*) from public.trip_seats where trip_id = t.id and status = 'available')
  where t.id = p_trip_id;

  return jsonb_build_object(
    'hold_id', v_hold_id,
    'hold_token', (select hold_token from public.seat_holds where id = v_hold_id),
    'expires_at', v_expires_at,
    'seat_ids', p_seat_ids,
    'quoted_fares', v_quote,
    'total_fare_cents', (select coalesce(sum(value::text::integer), 0) from jsonb_each(v_quote))
  );
end;
$$;

revoke execute on function public.create_seat_hold(uuid, uuid[], integer, uuid, uuid) from public, anon;
grant execute on function public.create_seat_hold(uuid, uuid[], integer, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- create_booking: the final, authoritative price. Recomputed here from the
-- engine for the points actually booked; must agree with the hold's quote
-- when the hold was quoted for points (otherwise fare_changed / points_changed).
-- Signature unchanged.
-- ---------------------------------------------------------------------
create or replace function public.create_booking(
  p_hold_token uuid,
  p_contact_email text,
  p_contact_phone text,
  p_passengers jsonb,
  p_boarding_point_id uuid,
  p_dropping_point_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_hold public.seat_holds;
  v_bus_id uuid;
  v_booking_id uuid;
  v_booking_reference text;
  v_order_id uuid;
  v_order_reference text;
  v_total_fare integer := 0;
  v_fare integer;
  v_seat record;
  v_passenger jsonb;
  v_passenger_id uuid;
  v_seat_ids uuid[];
begin
  if v_user_id is null then
    raise exception 'Must be authenticated';
  end if;

  select * into v_hold from public.seat_holds where hold_token = p_hold_token for update;
  if v_hold.id is null or v_hold.user_id <> v_user_id then
    raise exception 'Hold not found';
  end if;
  if v_hold.status <> 'active' or v_hold.expires_at < now() then
    raise exception 'Hold has expired';
  end if;

  select bus_id into v_bus_id from public.bus_trips where id = v_hold.trip_id;
  if v_bus_id is null or not private.is_bus_bookable(v_bus_id) then
    raise exception 'bus_unavailable: this bus is not available for booking';
  end if;
  perform private.validate_trip_points(v_hold.trip_id, p_boarding_point_id, p_dropping_point_id);

  if v_hold.boarding_point_id is not null
     and (v_hold.boarding_point_id is distinct from p_boarding_point_id
          or v_hold.dropping_point_id is distinct from p_dropping_point_id) then
    raise exception 'points_changed: the boarding / dropping points differ from the ones the seats were held for';
  end if;

  select array_agg(seat_id) into v_seat_ids from public.trip_seats where hold_id = v_hold.id;
  if v_seat_ids is null or array_length(v_seat_ids, 1) <> jsonb_array_length(p_passengers) then
    raise exception 'Passenger count must match held seat count';
  end if;

  v_booking_reference := 'TH' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  insert into public.bookings (booking_reference, customer_id, contact_email, contact_phone, status)
  values (v_booking_reference, v_user_id, p_contact_email, p_contact_phone, 'payment_pending')
  returning id into v_booking_id;

  for v_seat in
    select ts.id as trip_seat_id, ts.seat_id, (row_number() over (order by ts.id) - 1)::int as rn
    from public.trip_seats ts
    where ts.hold_id = v_hold.id
  loop
    v_passenger := p_passengers -> v_seat.rn;
    v_fare := private.calc_seat_fare(v_hold.trip_id, v_seat.seat_id, p_boarding_point_id, p_dropping_point_id);

    if v_hold.quoted_fares is not null and v_hold.boarding_point_id is not null
       and (v_hold.quoted_fares ->> v_seat.seat_id::text)::integer is distinct from v_fare then
      raise exception 'fare_changed: the fare changed since the seats were held; please review and try again';
    end if;

    insert into public.passengers (booking_id, full_name, age, gender, phone)
    values (
      v_booking_id,
      v_passenger ->> 'full_name',
      (v_passenger ->> 'age')::smallint,
      (v_passenger ->> 'gender')::public.passenger_gender,
      v_passenger ->> 'phone'
    )
    returning id into v_passenger_id;

    insert into public.booking_items (
      booking_id, trip_id, trip_seat_id, passenger_id,
      boarding_point_id, dropping_point_id, fare_cents, status
    )
    values (
      v_booking_id, v_hold.trip_id, v_seat.trip_seat_id, v_passenger_id,
      p_boarding_point_id, p_dropping_point_id, v_fare, 'payment_pending'
    );

    v_total_fare := v_total_fare + v_fare;
  end loop;

  update public.bookings set total_fare_cents = v_total_fare where id = v_booking_id;

  insert into public.booking_status_history (booking_id, from_status, to_status, changed_by)
  values (v_booking_id, 'draft', 'payment_pending', v_user_id);

  v_order_reference := 'ORD' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  insert into public.orders (order_reference, orderable_type, orderable_id, customer_id, amount_cents, status)
  values (v_order_reference, 'booking', v_booking_id, v_user_id, v_total_fare, 'created')
  returning id into v_order_id;

  return jsonb_build_object(
    'booking_id', v_booking_id,
    'booking_reference', v_booking_reference,
    'order_id', v_order_id,
    'order_reference', v_order_reference,
    'amount_cents', v_total_fare
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Operator fare setup for one bus
-- ---------------------------------------------------------------------
create or replace function public.validate_bus_fares(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc uuid;
  v_errors text[] := '{}';
  r record;
  v_rules integer;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  v_svc := private.bus_primary_service(p_bus_id);
  if v_svc is null then
    return jsonb_build_object('valid', false, 'errors', jsonb_build_array('Configure the route before setting fares'),
                              'stats', jsonb_build_object('rules', 0));
  end if;

  select count(*) into v_rules from public.fare_rules where service_id = v_svc;

  -- Every kind of bookable seat needs a base fare (no boarding/dropping restriction).
  for r in
    select distinct s.seat_type, s.berth
    from public.seats s join public.bus_layouts bl on bl.id = s.bus_layout_id
    where bl.bus_id = p_bus_id and bl.is_active and s.kind = 'bookable'
  loop
    if not exists (
      select 1 from public.fare_rules fr
      where fr.service_id = v_svc and fr.seat_type = r.seat_type
        and fr.from_boarding_point_id is null and fr.to_dropping_point_id is null
        and fr.seat_category is null
        and (fr.berth is null or fr.berth = r.berth)
        and fr.effective_from <= current_date and (fr.effective_to is null or fr.effective_to >= current_date)
    ) then
      v_errors := v_errors || format('No base fare for %s%s seats', r.seat_type, coalesce(' (' || r.berth || ' berth)', ''));
    end if;
  end loop;

  if not exists (select 1 from public.seats s join public.bus_layouts bl on bl.id = s.bus_layout_id
                 where bl.bus_id = p_bus_id and bl.is_active and s.kind = 'bookable') then
    v_errors := array_append(v_errors, 'Configure the seat layout before setting fares');
  end if;

  if exists (select 1 from public.fare_rules where service_id = v_svc and base_fare_cents = 0) then
    v_errors := array_append(v_errors, 'A fare of zero is not allowed');
  end if;

  return jsonb_build_object('valid', coalesce(array_length(v_errors, 1), 0) = 0,
                            'errors', to_jsonb(v_errors), 'stats', jsonb_build_object('rules', v_rules, 'service_id', v_svc));
end;
$$;

revoke execute on function public.validate_bus_fares(uuid) from public, anon;
grant execute on function public.validate_bus_fares(uuid) to authenticated;

-- Replaces the bus's fare rules and charges atomically.
--   p_rules:   [{seat_type, berth, seat_category, from_point_id, to_point_id,
--                base_fare_cents, effective_from, effective_to}]
--   p_charges: [{name, kind: flat|percent, flat_cents, percent}]
-- Editable while the bus is being set up, and also once approved/active
-- (fares are operational); locked only while under review or suspended.
create or replace function public.save_bus_fares(p_bus_id uuid, p_rules jsonb, p_charges jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc public.bus_services;
  v_route public.bus_routes;
  v_rule jsonb;
  v_charge jsonb;
  v_from uuid;
  v_to uuid;
  v_fseq integer;
  v_tseq integer;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_staff(v_bus.operator_id) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
  if not (v_bus.is_legacy or v_bus.lifecycle_status in ('draft', 'changes_requested', 'approved', 'active')) then
    raise exception 'Fares are locked while the bus is %', v_bus.lifecycle_status;
  end if;
  if jsonb_typeof(p_rules) <> 'array' or jsonb_array_length(p_rules) > 300 then
    raise exception 'Rules must be an array of at most 300 entries';
  end if;
  if jsonb_typeof(p_charges) <> 'array' or jsonb_array_length(p_charges) > 20 then
    raise exception 'Charges must be an array of at most 20 entries';
  end if;

  select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);
  if v_svc.id is null then raise exception 'Configure the route before setting fares'; end if;
  select * into v_route from public.bus_routes where id = v_svc.route_id;

  delete from public.fare_rules where service_id = v_svc.id;
  delete from public.fare_charges where service_id = v_svc.id;

  for v_rule in select * from jsonb_array_elements(p_rules) loop
    v_from := nullif(v_rule ->> 'from_point_id', '')::uuid;
    v_to := nullif(v_rule ->> 'to_point_id', '')::uuid;
    if v_from is not null then
      select sequence_no into v_fseq from public.boarding_points where id = v_from and route_id = v_route.id and is_active;
      if v_fseq is null then raise exception 'A fare refers to a boarding point that is not on this route'; end if;
    end if;
    if v_to is not null then
      select sequence_no into v_tseq from public.dropping_points where id = v_to and route_id = v_route.id and is_active;
      if v_tseq is null then raise exception 'A fare refers to a dropping point that is not on this route'; end if;
    end if;
    if v_from is not null and v_to is not null and v_route.bus_id is not null and v_fseq >= v_tseq then
      raise exception 'A point-to-point fare must go from an earlier stop to a later stop';
    end if;
    if coalesce((v_rule ->> 'base_fare_cents')::integer, 0) <= 0 then
      raise exception 'Fares must be greater than zero';
    end if;

    insert into public.fare_rules (
      service_id, seat_type, berth, seat_category, from_boarding_point_id, to_dropping_point_id,
      base_fare_cents, effective_from, effective_to
    ) values (
      v_svc.id, (v_rule ->> 'seat_type')::public.seat_type, nullif(v_rule ->> 'berth', ''),
      nullif(v_rule ->> 'seat_category', ''), v_from, v_to,
      (v_rule ->> 'base_fare_cents')::integer,
      coalesce(nullif(v_rule ->> 'effective_from', '')::date, current_date),
      nullif(v_rule ->> 'effective_to', '')::date
    );
  end loop;

  for v_charge in select * from jsonb_array_elements(p_charges) loop
    insert into public.fare_charges (service_id, name, kind, flat_cents, percent)
    values (
      v_svc.id, btrim(v_charge ->> 'name'), v_charge ->> 'kind',
      case when v_charge ->> 'kind' = 'flat' then (v_charge ->> 'flat_cents')::integer end,
      case when v_charge ->> 'kind' = 'percent' then (v_charge ->> 'percent')::numeric end
    );
  end loop;

  perform private.write_audit(
    'bus.fares_saved', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'rules', jsonb_array_length(p_rules), 'charges', jsonb_array_length(p_charges))
  );
  return public.validate_bus_fares(p_bus_id);
end;
$$;

revoke execute on function public.save_bus_fares(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.save_bus_fares(uuid, jsonb, jsonb) to authenticated;

-- Seat categories (e.g. 'premium') travel with the layout.
create or replace function public.save_bus_layout(
  p_bus_id uuid,
  p_layout jsonb,
  p_seats jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_old public.bus_layouts;
  v_layout_id uuid;
  v_decks integer := coalesce((p_layout ->> 'decks')::integer, 1);
  v_in_use boolean := false;
  v_version integer := 1;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then
    raise exception 'Bus not found';
  end if;
  if not private.is_operator_staff(v_bus.operator_id) then
    raise exception 'Not authorized';
  end if;
  if not private.operator_is_approved(v_bus.operator_id) then
    raise exception 'The operator account is not approved';
  end if;
  if not (v_bus.lifecycle_status in ('draft', 'changes_requested') or v_bus.is_legacy) then
    raise exception 'The seat layout is locked while the bus is %', v_bus.lifecycle_status;
  end if;
  if v_decks not in (1, 2) then
    raise exception 'Decks must be 1 or 2';
  end if;
  if jsonb_typeof(p_seats) <> 'array' or jsonb_array_length(p_seats) > 200 then
    raise exception 'Seats must be an array of at most 200 entries';
  end if;

  select * into v_old from public.bus_layouts where bus_id = p_bus_id and is_active order by version desc limit 1;

  if v_old.id is not null then
    select exists (
      select 1 from public.trip_seats ts join public.seats s on s.id = ts.seat_id
      where s.bus_layout_id = v_old.id
    ) into v_in_use;
    v_version := v_old.version;
  end if;

  if v_old.id is not null and not v_in_use then
    delete from public.seats where bus_layout_id = v_old.id;
    update public.bus_layouts set layout_json = p_layout, deck_count = v_decks where id = v_old.id;
    v_layout_id := v_old.id;
  else
    if v_old.id is not null then
      update public.bus_layouts set is_active = false where id = v_old.id;
      v_version := v_old.version + 1;
    end if;
    insert into public.bus_layouts (bus_id, name, deck_count, layout_json, version, is_active)
    values (p_bus_id, 'Layout v' || v_version, v_decks, p_layout, v_version, true)
    returning id into v_layout_id;
  end if;

  insert into public.seats (bus_layout_id, seat_code, deck, row_no, col_no, seat_type, berth, kind, category)
  select
    v_layout_id,
    btrim(e ->> 'seat_code'),
    (e ->> 'deck')::smallint,
    (e ->> 'row_no')::smallint,
    (e ->> 'col_no')::smallint,
    (e ->> 'seat_type')::public.seat_type,
    nullif(e ->> 'berth', ''),
    coalesce(nullif(e ->> 'kind', ''), 'bookable'),
    nullif(e ->> 'category', '')
  from jsonb_array_elements(p_seats) e;

  perform private.write_audit(
    'bus.layout_saved', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'layout_id', v_layout_id, 'version', v_version,
                       'seats', jsonb_array_length(p_seats), 'versioned', v_in_use)
  );
  return public.validate_bus_layout(p_bus_id);
end;
$$;
