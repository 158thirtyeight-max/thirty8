-- Rolls back 20261002001700_realtime_seat_inventory.sql (restores the previous function bodies).
drop policy if exists trip_ops_broadcast_listen on realtime.messages;
drop policy if exists trip_seats_broadcast_listen on realtime.messages;

drop trigger if exists ping_ops_boarding_ins on public.boarding_events;
drop trigger if exists ping_ops_refunds_upd on public.refunds;
drop trigger if exists ping_ops_refunds_ins on public.refunds;
drop trigger if exists ping_ops_payments_upd on public.payments;
drop trigger if exists ping_ops_payments_ins on public.payments;
drop trigger if exists ping_ops_items_upd on public.booking_items;
drop trigger if exists ping_ops_items_ins on public.booking_items;
drop function if exists private.ping_trip_ops();
drop trigger if exists broadcast_trip_seat_changes on public.trip_seats;
drop function if exists private.broadcast_trip_seat_changes();

drop function if exists public.get_operator_trip_seat_map(uuid);
drop function if exists public.operator_block_seats(uuid, uuid[], text);
drop function if exists public.operator_release_seats(uuid, uuid[], text);
drop function if exists private.operator_seat_change(uuid, uuid[], text, boolean);
drop function if exists public.renew_seat_hold(uuid, integer);

-- previous handle_payment_failure (20260923001300)
create or replace function public.handle_payment_failure(p_order_reference text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_hold_ids uuid[];
begin
  select * into v_order from public.orders where order_reference = p_order_reference for update;
  if v_order.id is null then
    raise exception 'Order not found: %', p_order_reference;
  end if;

  update public.orders set status = 'failed' where id = v_order.id;

  if v_order.orderable_type = 'booking' then
    select array_agg(distinct ts.hold_id) into v_hold_ids
    from public.booking_items bi
    join public.trip_seats ts on ts.id = bi.trip_seat_id
    where bi.booking_id = v_order.orderable_id and ts.hold_id is not null;

    update public.bookings set status = 'failed' where id = v_order.orderable_id;
    update public.booking_items set status = 'failed' where booking_id = v_order.orderable_id;

    update public.trip_seats ts
    set status = 'available', hold_id = null
    from public.booking_items bi
    where bi.booking_id = v_order.orderable_id and bi.trip_seat_id = ts.id;

    if v_hold_ids is not null then
      update public.seat_holds set status = 'expired' where id = any (v_hold_ids);
    end if;

    insert into public.booking_status_history (booking_id, from_status, to_status)
    values (v_order.orderable_id, 'payment_pending', 'failed');

  elsif v_order.orderable_type = 'cargo_shipment' then
    update public.cargo_shipments set status = 'failed' where id = v_order.orderable_id;
  end if;
end;
$$;

-- previous expire_stale_seat_holds (20260923001400)
create or replace function private.expire_stale_seat_holds()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.trip_seats ts
  set status = 'available', hold_id = null
  from public.seat_holds sh
  where ts.hold_id = sh.id
    and ts.status = 'held'
    and sh.status = 'active'
    and sh.expires_at < now();

  update public.seat_holds
  set status = 'expired'
  where status = 'active'
    and expires_at < now();

  update public.bus_trips t
  set available_seats = (select count(*) from public.trip_seats where trip_id = t.id and status = 'available')
  where t.id in (
    select distinct trip_id from public.trip_seats
    where updated_at > now() - interval '2 minutes'
  );
end;
$$;

-- previous get_trip_seat_map (20261002000300)
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
    and private.trip_is_open_for_booking(t.id)
  group by t.id, t.bus_id, t.service_id, t.travel_date, bl.layout_json, bl.deck_count;

  return v_result;
end;
$function$;

drop function if exists private.effective_seat_status(public.trip_seat_status, uuid);
drop trigger if exists refresh_available_seats_del on public.trip_seats;
drop trigger if exists refresh_available_seats_upd on public.trip_seats;
drop trigger if exists refresh_available_seats_ins on public.trip_seats;
drop function if exists private.refresh_trip_available_seats();
drop trigger if exists bump_trip_seat_rev on public.trip_seats;
drop function if exists private.bump_trip_seat_rev();
alter table public.seat_holds drop column if exists renewal_count;
alter table public.trip_seats drop column if exists rev;
