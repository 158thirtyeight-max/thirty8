-- =========================================================================
-- Real-time seat inventory (extends the existing authoritative model; no
-- parallel inventory).
--
--   * trip_seats.rev: monotonic per-seat revision so clients can reject stale updates
--   * available_seats is recomputed by a statement trigger on every seat change
--   * expired-but-not-yet-collected holds read as 'available' (effective status)
--   * hold renewal (one renewal, 600 s from creation at most)
--   * operator seat block / release (available <-> blocked only, audited)
--   * handle_payment_failure can no longer free a seat that now belongs to someone else
--   * expiry cron locks rows and tolerates concurrent sessions
--   * Realtime Broadcast from triggers on PRIVATE channels:
--       trip:<id>:seats  seat id/status/rev only (no hold, user or booking data) - anyone may listen
--       trip:<id>:ops    "something changed" ping, no amounts/PII - trip's operator staff + admins
--   * get_operator_trip_seat_map: booking reference + status per seat, never passenger data
-- The backend stays the source of truth; Broadcast only tells clients to re-read.
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. per-seat revision
-- ---------------------------------------------------------------------
alter table public.trip_seats add column rev bigint not null default 1;
alter table public.seat_holds add column renewal_count integer not null default 0;

create or replace function private.bump_trip_seat_rev()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.rev := old.rev + 1;
  return new;
end;
$$;

create trigger bump_trip_seat_rev
  before update on public.trip_seats
  for each row execute function private.bump_trip_seat_rev();

-- ---------------------------------------------------------------------
-- 2. available_seats follows seat changes (replaces the 2-minute cron heuristic)
-- ---------------------------------------------------------------------
create or replace function private.refresh_trip_available_seats()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    update public.bus_trips t
       set available_seats = (select count(*) from public.trip_seats s where s.trip_id = t.id and s.status = 'available')
     where t.id in (select distinct trip_id from old_rows);
  else
    update public.bus_trips t
       set available_seats = (select count(*) from public.trip_seats s where s.trip_id = t.id and s.status = 'available')
     where t.id in (select distinct trip_id from new_rows);
  end if;
  return null;
end;
$$;

create trigger refresh_available_seats_ins
  after insert on public.trip_seats
  referencing new table as new_rows
  for each statement execute function private.refresh_trip_available_seats();
create trigger refresh_available_seats_upd
  after update on public.trip_seats
  referencing new table as new_rows old table as old_rows
  for each statement execute function private.refresh_trip_available_seats();
create trigger refresh_available_seats_del
  after delete on public.trip_seats
  referencing old table as old_rows
  for each statement execute function private.refresh_trip_available_seats();

-- ---------------------------------------------------------------------
-- 3. effective status: a hold that has timed out reads as available even before the cron runs
-- ---------------------------------------------------------------------
create or replace function private.effective_seat_status(p_status public.trip_seat_status, p_hold_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_status = 'held' and not exists (
      select 1 from public.seat_holds h
      where h.id = p_hold_id and h.status = 'active' and h.expires_at > now())
    then 'available'
    else p_status::text
  end;
$$;
revoke execute on function private.effective_seat_status(public.trip_seat_status, uuid) from public, anon;
grant execute on function private.effective_seat_status(public.trip_seat_status, uuid) to authenticated, anon;

-- customer seat map: effective status + per-seat rev + as_of (everything else unchanged)
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
as $function$
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
    'as_of', now(),
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
      'status', private.effective_seat_status(ts.status, ts.hold_id),
      'rev', ts.rev,
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
    and private.trip_is_open_for_booking(t.id)
  group by t.id, t.bus_id, t.service_id, t.travel_date, bl.layout_json, bl.deck_count;

  return v_result;
end;
$function$;

-- ---------------------------------------------------------------------
-- 4. expiry cron: lock seat rows first (same order as create_seat_hold), skip rows others hold
-- ---------------------------------------------------------------------
create or replace function private.expire_stale_seat_holds()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  with locked as (
    select ts.id, ts.hold_id
    from public.trip_seats ts
    join public.seat_holds sh on sh.id = ts.hold_id
    where ts.status = 'held'
      and sh.status <> 'confirmed'
      and (sh.status <> 'active' or sh.expires_at < now())
    for update of ts skip locked
  ), freed as (
    update public.trip_seats ts
       set status = 'available', hold_id = null
      from locked l
     where ts.id = l.id
    returning l.hold_id
  )
  update public.seat_holds h
     set status = 'expired'
   where h.status = 'active'
     and h.id in (select hold_id from freed)
     and not exists (select 1 from public.trip_seats x where x.hold_id = h.id and x.status = 'held');

  -- holds that no longer cover any seat
  update public.seat_holds h
     set status = 'expired'
   where h.status = 'active' and h.expires_at < now()
     and not exists (select 1 from public.trip_seats x where x.hold_id = h.id and x.status = 'held');
end;
$$;

-- ---------------------------------------------------------------------
-- 5. a stale payment-failure webhook must not free someone else's seat
-- ---------------------------------------------------------------------
create or replace function public.handle_payment_failure(p_order_reference text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_booking public.bookings;
  v_hold_ids uuid[];
begin
  select * into v_order from public.orders where order_reference = p_order_reference for update;
  if v_order.id is null then
    raise exception 'Order not found: %', p_order_reference;
  end if;

  -- a failure event for an order that is already paid/refunded/closed is stale
  if v_order.status in ('paid', 'refunded', 'failed', 'cancelled') then
    return;
  end if;

  update public.orders set status = 'failed' where id = v_order.id;

  if v_order.orderable_type = 'booking' then
    select * into v_booking from public.bookings where id = v_order.orderable_id for update;

    -- free only seats still held by THIS customer's hold on that trip; never a seat resold to someone else
    with mine as (
      select ts.id, ts.hold_id
      from public.booking_items bi
      join public.trip_seats ts on ts.id = bi.trip_seat_id
      join public.seat_holds sh on sh.id = ts.hold_id
      where bi.booking_id = v_booking.id
        and ts.status = 'held'
        and sh.user_id = v_booking.customer_id
        and sh.trip_id = ts.trip_id
      for update of ts
    ), freed as (
      update public.trip_seats ts
         set status = 'available', hold_id = null
        from mine m
       where ts.id = m.id
      returning m.hold_id
    )
    select array_agg(distinct hold_id) into v_hold_ids from freed;

    update public.bookings set status = 'failed' where id = v_booking.id and status = 'payment_pending';
    update public.booking_items set status = 'failed' where booking_id = v_booking.id and status = 'payment_pending';

    if v_hold_ids is not null then
      update public.seat_holds set status = 'expired' where id = any (v_hold_ids) and status = 'active';
    end if;

    insert into public.booking_status_history (booking_id, from_status, to_status)
    values (v_booking.id, 'payment_pending', 'failed');

  elsif v_order.orderable_type = 'cargo_shipment' then
    update public.cargo_shipments set status = 'failed' where id = v_order.orderable_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. hold renewal
-- ---------------------------------------------------------------------
create or replace function public.renew_seat_hold(p_hold_token uuid, p_ttl_seconds integer default 300)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hold public.seat_holds;
  v_ttl integer := least(greatest(coalesce(p_ttl_seconds, 300), 30), 600);
  v_new_expiry timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception 'Must be authenticated to renew a hold';
  end if;

  select * into v_hold from public.seat_holds where hold_token = p_hold_token for update;
  if v_hold.id is null or v_hold.user_id <> (select auth.uid()) then
    raise exception 'Hold not found';
  end if;
  if v_hold.status <> 'active' or v_hold.expires_at <= now() then
    raise exception 'hold_expired: Hold has expired';
  end if;
  if v_hold.renewal_count >= 1 then
    raise exception 'renewal_not_allowed: this hold was already extended';
  end if;
  if not private.trip_is_open_for_booking(v_hold.trip_id) then
    raise exception 'trip_closed: this trip is no longer open for booking';
  end if;

  v_new_expiry := least(now() + make_interval(secs => v_ttl), v_hold.created_at + interval '600 seconds');
  if v_new_expiry <= v_hold.expires_at then
    raise exception 'renewal_not_allowed: the hold cannot be extended further';
  end if;

  update public.seat_holds set expires_at = v_new_expiry, renewal_count = renewal_count + 1 where id = v_hold.id;
  -- touch the seats so subscribers see the renewal (rev bump + broadcast)
  update public.trip_seats set hold_id = hold_id where hold_id = v_hold.id and status = 'held';

  return jsonb_build_object('hold_token', v_hold.hold_token, 'expires_at', v_new_expiry);
end;
$$;
revoke execute on function public.renew_seat_hold(uuid, integer) from public, anon;
grant execute on function public.renew_seat_hold(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 7. operator seat block / release
-- ---------------------------------------------------------------------
create or replace function private.operator_seat_change(
  p_trip_id uuid, p_seat_ids uuid[], p_reason text, p_block boolean
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_locked int;
  v_bad int;
  v_codes text[];
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  if not private.is_operator_staff(v_trip.operator_id) then raise exception 'Not authorized'; end if;
  if not private.operator_service_active(v_trip.operator_id, 'bus') then
    raise exception 'service_inactive: the Bus service is not active for this operator';
  end if;
  if v_trip.status not in ('scheduled', 'boarding') then
    raise exception 'trip_not_editable: seats can only be changed before departure';
  end if;
  if coalesce(array_length(p_seat_ids, 1), 0) = 0 then raise exception 'No seats specified'; end if;
  if p_block and coalesce(btrim(p_reason), '') = '' then raise exception 'A reason is required to block seats'; end if;

  select count(*) into v_locked from (
    select 1 from public.trip_seats where trip_id = p_trip_id and seat_id = any (p_seat_ids) for update
  ) l;
  if v_locked <> cardinality(p_seat_ids) then raise exception 'One or more seats do not exist on this trip'; end if;

  if p_block then
    -- free holds that already timed out so those seats can be blocked
    update public.trip_seats ts set status = 'available', hold_id = null
      from public.seat_holds sh
     where ts.trip_id = p_trip_id and ts.seat_id = any (p_seat_ids) and ts.hold_id = sh.id
       and ts.status = 'held' and (sh.status <> 'active' or sh.expires_at < now());
    select count(*) into v_bad from public.trip_seats
      where trip_id = p_trip_id and seat_id = any (p_seat_ids) and status <> 'available';
    if v_bad > 0 then raise exception 'seat_unavailable: only available seats can be blocked'; end if;
    update public.trip_seats set status = 'blocked' where trip_id = p_trip_id and seat_id = any (p_seat_ids);
  else
    select count(*) into v_bad from public.trip_seats
      where trip_id = p_trip_id and seat_id = any (p_seat_ids) and status <> 'blocked';
    if v_bad > 0 then raise exception 'seat_not_blocked: only blocked seats can be released'; end if;
    update public.trip_seats set status = 'available' where trip_id = p_trip_id and seat_id = any (p_seat_ids);
  end if;

  select array_agg(s.seat_code order by s.seat_code) into v_codes from public.seats s where s.id = any (p_seat_ids);
  perform private.write_audit(case when p_block then 'trip_seat.block' else 'trip_seat.release' end, 'bus_trip', p_trip_id,
    null, jsonb_build_object('seats', v_codes, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'seats', v_codes);
end;
$$;
revoke execute on function private.operator_seat_change(uuid, uuid[], text, boolean) from public, anon, authenticated;

create or replace function public.operator_block_seats(p_trip_id uuid, p_seat_ids uuid[], p_reason text)
returns jsonb language sql security definer set search_path = ''
as $$ select private.operator_seat_change(p_trip_id, p_seat_ids, p_reason, true) $$;
create or replace function public.operator_release_seats(p_trip_id uuid, p_seat_ids uuid[], p_reason text default null)
returns jsonb language sql security definer set search_path = ''
as $$ select private.operator_seat_change(p_trip_id, p_seat_ids, p_reason, false) $$;
revoke execute on function public.operator_block_seats(uuid, uuid[], text) from public, anon;
revoke execute on function public.operator_release_seats(uuid, uuid[], text) from public, anon;
grant execute on function public.operator_block_seats(uuid, uuid[], text) to authenticated;
grant execute on function public.operator_release_seats(uuid, uuid[], text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. Realtime Broadcast (private channels). A failed send never breaks a booking.
-- ---------------------------------------------------------------------
create or replace function private.broadcast_trip_seat_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    select n.trip_id,
           jsonb_agg(jsonb_build_object(
             'seat_id', n.seat_id,
             'status', private.effective_seat_status(n.status, n.hold_id),
             'rev', n.rev) order by n.seat_id) as seats
    from new_rows n
    group by n.trip_id
  loop
    begin
      perform realtime.send(jsonb_build_object('trip_id', r.trip_id, 'seats', r.seats),
                            'seat_changes', 'trip:' || r.trip_id || ':seats', true);
    exception when others then
      null;
    end;
  end loop;
  return null;
end;
$$;
revoke execute on function private.broadcast_trip_seat_changes() from public, anon, authenticated;

create trigger broadcast_trip_seat_changes
  after update on public.trip_seats
  referencing new table as new_rows
  for each statement execute function private.broadcast_trip_seat_changes();

create or replace function private.ping_trip_ops()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip uuid;
  v_kind text := tg_argv[0];
begin
  if tg_table_name = 'booking_items' then
    for v_trip in select distinct trip_id from new_rows loop
      begin
        perform realtime.send(jsonb_build_object('kind', v_kind, 'at', now()), 'changed', 'trip:' || v_trip || ':ops', true);
      exception when others then null; end;
    end loop;
  elsif tg_table_name = 'payments' then
    for v_trip in
      select distinct bi.trip_id from new_rows p
      join public.orders o on o.id = p.order_id and o.orderable_type = 'booking'
      join public.booking_items bi on bi.booking_id = o.orderable_id
    loop
      begin
        perform realtime.send(jsonb_build_object('kind', v_kind, 'at', now()), 'changed', 'trip:' || v_trip || ':ops', true);
      exception when others then null; end;
    end loop;
  elsif tg_table_name = 'refunds' then
    for v_trip in
      select distinct bi.trip_id from new_rows r
      join public.payments p on p.id = r.payment_id
      join public.orders o on o.id = p.order_id and o.orderable_type = 'booking'
      join public.booking_items bi on bi.booking_id = o.orderable_id
    loop
      begin
        perform realtime.send(jsonb_build_object('kind', v_kind, 'at', now()), 'changed', 'trip:' || v_trip || ':ops', true);
      exception when others then null; end;
    end loop;
  elsif tg_table_name = 'boarding_events' then
    for v_trip in select distinct trip_id from new_rows loop
      begin
        perform realtime.send(jsonb_build_object('kind', v_kind, 'at', now()), 'changed', 'trip:' || v_trip || ':ops', true);
      exception when others then null; end;
    end loop;
  end if;
  return null;
end;
$$;
revoke execute on function private.ping_trip_ops() from public, anon, authenticated;

create trigger ping_ops_items_ins after insert on public.booking_items
  referencing new table as new_rows for each statement execute function private.ping_trip_ops('booking');
create trigger ping_ops_items_upd after update on public.booking_items
  referencing new table as new_rows for each statement execute function private.ping_trip_ops('booking');
create trigger ping_ops_payments_ins after insert on public.payments
  referencing new table as new_rows for each statement execute function private.ping_trip_ops('payment');
create trigger ping_ops_payments_upd after update on public.payments
  referencing new table as new_rows for each statement execute function private.ping_trip_ops('payment');
create trigger ping_ops_refunds_ins after insert on public.refunds
  referencing new table as new_rows for each statement execute function private.ping_trip_ops('refund');
create trigger ping_ops_refunds_upd after update on public.refunds
  referencing new table as new_rows for each statement execute function private.ping_trip_ops('refund');
create trigger ping_ops_boarding_ins after insert on public.boarding_events
  referencing new table as new_rows for each statement execute function private.ping_trip_ops('boarding');

-- who may listen: seat channels carry no personal data; ops channels are trip-operator only
create policy trip_seats_broadcast_listen on realtime.messages
  for select to authenticated, anon
  using (realtime.messages.extension = 'broadcast'
         and (select realtime.topic()) ~ '^trip:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:seats$');

create policy trip_ops_broadcast_listen on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) ~ '^trip:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:ops$'
    and exists (
      select 1 from public.bus_trips t
      where t.id = split_part((select realtime.topic()), ':', 2)::uuid
        and (private.is_operator_staff(t.operator_id) or private.is_platform_admin())
    )
  );

-- ---------------------------------------------------------------------
-- 9. operator / admin seat map: status + booking reference/status per seat, no passenger data
-- ---------------------------------------------------------------------
create or replace function public.get_operator_trip_seat_map(p_trip_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_layout public.bus_layouts;
  v_seats jsonb;
  v_counts jsonb;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id;
  if v_trip.id is null then raise exception 'Trip not found'; end if;
  if not (private.is_operator_staff(v_trip.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  select * into v_layout from public.bus_layouts bl
    where bl.bus_id = v_trip.bus_id
      and bl.id = (select s.bus_layout_id from public.trip_seats ts join public.seats s on s.id = ts.seat_id
                    where ts.trip_id = p_trip_id limit 1);
  if v_layout.id is null then
    select * into v_layout from public.bus_layouts bl where bl.bus_id = v_trip.bus_id and bl.is_active;
  end if;

  select coalesce(jsonb_agg(x.j order by x.deck, x.row_no, x.col_no), '[]'::jsonb) into v_seats
  from (
    select s.deck, s.row_no, s.col_no,
      jsonb_build_object(
        'trip_seat_id', ts.id,
        'seat_id', s.id,
        'seat_code', s.seat_code,
        'deck', s.deck, 'row_no', s.row_no, 'col_no', s.col_no,
        'seat_type', s.seat_type, 'berth', s.berth, 'category', s.category,
        'status', private.effective_seat_status(ts.status, ts.hold_id),
        'rev', ts.rev,
        'fare_cents', ts.fare_cents,
        'booking_reference', b.booking_reference,
        'booking_status', b.status
      ) as j
    from public.trip_seats ts
    join public.seats s on s.id = ts.seat_id
    left join lateral (
      select bk.booking_reference, bk.status
      from public.booking_items bi
      join public.bookings bk on bk.id = bi.booking_id
      where bi.trip_seat_id = ts.id and bi.status in ('payment_pending', 'confirmed', 'completed')
      order by bi.created_at desc limit 1
    ) b on true
    where ts.trip_id = p_trip_id
  ) x;

  select jsonb_build_object(
    'total', count(*),
    'booked', count(*) filter (where st = 'booked'),
    'boarded', count(*) filter (where st = 'boarded'),
    'held', count(*) filter (where st = 'held'),
    'blocked', count(*) filter (where st = 'blocked'),
    'available', count(*) filter (where st = 'available'),
    'occupancy_pct', case when count(*) = 0 then 0
                     else round(100.0 * count(*) filter (where st in ('booked', 'boarded')) / count(*), 1) end
  ) into v_counts
  from (select private.effective_seat_status(ts.status, ts.hold_id) as st from public.trip_seats ts where ts.trip_id = p_trip_id) q;

  return jsonb_build_object(
    'trip_id', v_trip.id,
    'trip_status', v_trip.status,
    'bus_id', v_trip.bus_id,
    'departure_at', v_trip.departure_at,
    'layout', v_layout.layout_json,
    'deck_count', v_layout.deck_count,
    'as_of', now(),
    'counts', v_counts,
    'seats', v_seats
  );
end;
$$;
revoke execute on function public.get_operator_trip_seat_map(uuid) from public, anon;
grant execute on function public.get_operator_trip_seat_map(uuid) to authenticated;
