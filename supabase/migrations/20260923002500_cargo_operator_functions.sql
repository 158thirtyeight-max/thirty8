-- =========================================================================
-- Operator-side cargo functions: accept/reject the auto-dispatched
-- assignment, status/GPS updates with geofence milestone detection,
-- pickup/delivery proof confirmation, and a shaped tracking-timeline read.
-- =========================================================================

create or replace function private.haversine_km(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select 6371 * 2 * asin(sqrt(
    sin(radians(lat2 - lat1) / 2) ^ 2
    + cos(radians(lat1)) * cos(radians(lat2)) * sin(radians(lon2 - lon1) / 2) ^ 2
  ));
$$;

-- Operator assigns one of their own vehicles to a confirmed shipment,
-- signalling acceptance of the auto-dispatched assignment.
create or replace function public.accept_cargo_shipment(p_shipment_id uuid, p_vehicle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id for update;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if not private.is_operator_staff(v_shipment.operator_id) then
    raise exception 'Not authorized for this shipment';
  end if;
  if v_shipment.status <> 'confirmed' then
    raise exception 'Shipment is not awaiting acceptance (status: %)', v_shipment.status;
  end if;
  if not exists (select 1 from public.cargo_vehicles where id = p_vehicle_id and operator_id = v_shipment.operator_id) then
    raise exception 'Vehicle does not belong to this operator';
  end if;

  update public.cargo_shipments set vehicle_id = p_vehicle_id where id = p_shipment_id;

  return jsonb_build_object('shipment_id', p_shipment_id, 'vehicle_id', p_vehicle_id, 'status', 'accepted');
end;
$$;

-- Operator declines the assignment. Re-runs the dispatch quote excluding
-- this operator; if another operator can serve it, reassign (customer's
-- payment/status is untouched). If nobody else can, cancel with a refund
-- (mirrors cancel_shipment's refund-intent pattern).
create or replace function public.reject_cargo_shipment(p_shipment_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
  v_source_city_id uuid;
  v_destination_city_id uuid;
  v_next record;
  v_payment public.payments;
  v_refund_id uuid;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id for update;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if not private.is_operator_staff(v_shipment.operator_id) then
    raise exception 'Not authorized for this shipment';
  end if;
  if v_shipment.status <> 'confirmed' then
    raise exception 'Shipment is not awaiting acceptance (status: %)', v_shipment.status;
  end if;

  select source_city_id, destination_city_id into v_source_city_id, v_destination_city_id
  from public.cargo_routes where id = v_shipment.route_id;

  select r.id as route_id, r.operator_id
  into v_next
  from public.cargo_routes r
  join public.operators o on o.id = r.operator_id and o.status = 'approved'
  join public.cargo_pricing_rules pr on pr.route_id = r.id and pr.cargo_type_id = v_shipment.cargo_type_id
  where r.active
    and r.source_city_id = v_source_city_id
    and r.destination_city_id = v_destination_city_id
    and r.operator_id <> v_shipment.operator_id
  order by pr.base_fare_cents asc
  limit 1;

  insert into public.cargo_status_history (shipment_id, from_status, to_status, changed_by, note)
  values (p_shipment_id, v_shipment.status, v_shipment.status, (select auth.uid()), coalesce(p_reason, 'Rejected by operator'));

  if v_next.route_id is not null then
    update public.cargo_shipments
    set operator_id = v_next.operator_id, route_id = v_next.route_id, vehicle_id = null
    where id = p_shipment_id;

    return jsonb_build_object('shipment_id', p_shipment_id, 'status', 'reassigned', 'operator_id', v_next.operator_id);
  end if;

  update public.cargo_shipments set status = 'cancelled' where id = p_shipment_id;
  insert into public.cargo_status_history (shipment_id, from_status, to_status, changed_by, note)
  values (p_shipment_id, v_shipment.status, 'cancelled', (select auth.uid()), 'No alternate operator available');

  select p.* into v_payment
  from public.payments p
  join public.orders o on o.id = p.order_id
  where o.orderable_type = 'cargo_shipment' and o.orderable_id = p_shipment_id and p.status = 'captured'
  order by p.created_at desc
  limit 1;

  if v_payment.id is not null then
    insert into public.refunds (payment_id, amount_cents, reason, status)
    values (v_payment.id, v_payment.amount_cents, 'No operator available', 'pending')
    returning id into v_refund_id;
  end if;

  return jsonb_build_object('shipment_id', p_shipment_id, 'status', 'cancelled', 'refund_id', v_refund_id);
end;
$$;

-- Mid-journey status updates. picked_up/delivered/cancelled have their own
-- dedicated functions (extra side effects); this covers the states between.
create or replace function public.update_cargo_status(p_shipment_id uuid, p_new_status public.cargo_shipment_status, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
  v_allowed boolean := false;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id for update;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if not private.is_operator_staff(v_shipment.operator_id) then
    raise exception 'Not authorized for this shipment';
  end if;

  v_allowed := (v_shipment.status, p_new_status) in (
    ('picked_up', 'in_transit'),
    ('in_transit', 'arrived_at_hub'),
    ('in_transit', 'out_for_delivery'),
    ('arrived_at_hub', 'in_transit'),
    ('arrived_at_hub', 'out_for_delivery')
  );
  if not v_allowed then
    raise exception 'Cannot move shipment from % to %', v_shipment.status, p_new_status;
  end if;

  update public.cargo_shipments set status = p_new_status where id = p_shipment_id;
  insert into public.cargo_status_history (shipment_id, from_status, to_status, changed_by, note)
  values (p_shipment_id, v_shipment.status, p_new_status, (select auth.uid()), p_note);

  return jsonb_build_object('shipment_id', p_shipment_id, 'status', p_new_status);
end;
$$;

-- Operator's driver phone pings GPS periodically. Records the raw location,
-- and geofence-matches against this shipment's own pickup/delivery hub
-- (~200m radius) to auto-log an arrival milestone — no external maps API,
-- pure coordinate math, per the plan's "GPS Coordinate Matching" design.
create or replace function public.update_cargo_location(p_shipment_id uuid, p_latitude numeric, p_longitude numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
  v_hub record;
  v_distance_km numeric;
  v_milestone boolean := false;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id for update;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if not private.is_operator_staff(v_shipment.operator_id) then
    raise exception 'Not authorized for this shipment';
  end if;
  if v_shipment.status not in ('picked_up', 'in_transit', 'arrived_at_hub', 'out_for_delivery') then
    raise exception 'Shipment is not currently in transit (status: %)', v_shipment.status;
  end if;

  update public.cargo_shipments
  set current_latitude = p_latitude, current_longitude = p_longitude, last_location_update = now()
  where id = p_shipment_id;

  insert into public.cargo_tracking_events (shipment_id, latitude, longitude, event_type)
  values (p_shipment_id, p_latitude, p_longitude, 'location_update');

  -- Check arrival at whichever hub is next: pickup hub if not yet picked up
  -- from a hub, delivery hub if en route to one.
  select h.id, h.name, h.latitude, h.longitude into v_hub
  from public.cargo_hub h
  where h.id = case
    when v_shipment.status in ('picked_up', 'in_transit') and v_shipment.pickup_type = 'hub' then v_shipment.pickup_hub_id
    when v_shipment.status in ('in_transit', 'arrived_at_hub', 'out_for_delivery') and v_shipment.delivery_type = 'hub' then v_shipment.delivery_hub_id
  end;

  if v_hub.id is not null and v_hub.latitude is not null and v_hub.longitude is not null then
    v_distance_km := private.haversine_km(p_latitude, p_longitude, v_hub.latitude, v_hub.longitude);
    if v_distance_km <= 0.2 then
      v_milestone := true;
      insert into public.cargo_tracking_events (shipment_id, latitude, longitude, event_type, milestone_hub_id)
      values (p_shipment_id, p_latitude, p_longitude, 'milestone_arrived', v_hub.id);
    end if;
  end if;

  return jsonb_build_object('shipment_id', p_shipment_id, 'milestone_reached', v_milestone, 'hub_id', v_hub.id);
end;
$$;

create or replace function public.confirm_cargo_pickup(p_shipment_id uuid, p_proof_url text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id for update;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if not private.is_operator_staff(v_shipment.operator_id) then
    raise exception 'Not authorized for this shipment';
  end if;
  if v_shipment.status <> 'confirmed' or v_shipment.vehicle_id is null then
    raise exception 'Shipment must be accepted (vehicle assigned) before pickup';
  end if;

  update public.cargo_shipments set status = 'picked_up', pickup_proof_url = p_proof_url where id = p_shipment_id;
  insert into public.cargo_status_history (shipment_id, from_status, to_status, changed_by)
  values (p_shipment_id, 'confirmed', 'picked_up', (select auth.uid()));

  return jsonb_build_object('shipment_id', p_shipment_id, 'status', 'picked_up');
end;
$$;

create or replace function public.confirm_cargo_delivery(p_shipment_id uuid, p_proof_url text, p_recipient_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id for update;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if not private.is_operator_staff(v_shipment.operator_id) then
    raise exception 'Not authorized for this shipment';
  end if;
  if v_shipment.status not in ('out_for_delivery', 'arrived_at_hub', 'in_transit') then
    raise exception 'Shipment is not ready for delivery (status: %)', v_shipment.status;
  end if;

  update public.cargo_shipments
  set status = 'delivered', delivery_proof_url = p_proof_url, recipient_name = p_recipient_name, actual_delivered_at = now()
  where id = p_shipment_id;

  insert into public.cargo_status_history (shipment_id, from_status, to_status, changed_by)
  values (p_shipment_id, v_shipment.status, 'delivered', (select auth.uid()));

  return jsonb_build_object('shipment_id', p_shipment_id, 'status', 'delivered');
end;
$$;

-- Shaped tracking read for the customer's tracking screen: current status,
-- position, and the full status/location timeline in one call.
create or replace function public.track_cargo_shipment(p_shipment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_shipment public.cargo_shipments;
  v_history jsonb;
  v_events jsonb;
begin
  select * into v_shipment from public.cargo_shipments where id = p_shipment_id;
  if v_shipment.id is null then
    raise exception 'Shipment not found';
  end if;
  if v_shipment.sender_user_id <> (select auth.uid())
    and (v_shipment.operator_id is null or not private.is_operator_staff(v_shipment.operator_id))
    and not private.is_platform_admin() then
    raise exception 'Not authorized';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('to_status', to_status, 'note', note, 'created_at', created_at) order by created_at), '[]'::jsonb)
  into v_history
  from public.cargo_status_history where shipment_id = p_shipment_id;

  select coalesce(jsonb_agg(jsonb_build_object('event_type', event_type, 'latitude', latitude, 'longitude', longitude, 'recorded_at', recorded_at) order by recorded_at desc), '[]'::jsonb)
  into v_events
  from public.cargo_tracking_events where shipment_id = p_shipment_id
  limit 50;

  return jsonb_build_object(
    'shipment_id', v_shipment.id,
    'status', v_shipment.status,
    'current_latitude', v_shipment.current_latitude,
    'current_longitude', v_shipment.current_longitude,
    'last_location_update', v_shipment.last_location_update,
    'estimated_delivery_at', v_shipment.estimated_delivery_at,
    'status_history', v_history,
    'tracking_events', v_events
  );
end;
$$;

revoke execute on function public.accept_cargo_shipment(uuid, uuid) from public, anon;
revoke execute on function public.reject_cargo_shipment(uuid, text) from public, anon;
revoke execute on function public.update_cargo_status(uuid, public.cargo_shipment_status, text) from public, anon;
revoke execute on function public.update_cargo_location(uuid, numeric, numeric) from public, anon;
revoke execute on function public.confirm_cargo_pickup(uuid, text) from public, anon;
revoke execute on function public.confirm_cargo_delivery(uuid, text, text) from public, anon;
revoke execute on function public.track_cargo_shipment(uuid) from public, anon;

grant execute on function public.accept_cargo_shipment(uuid, uuid) to authenticated;
grant execute on function public.reject_cargo_shipment(uuid, text) to authenticated;
grant execute on function public.update_cargo_status(uuid, public.cargo_shipment_status, text) to authenticated;
grant execute on function public.update_cargo_location(uuid, numeric, numeric) to authenticated;
grant execute on function public.confirm_cargo_pickup(uuid, text) to authenticated;
grant execute on function public.confirm_cargo_delivery(uuid, text, text) to authenticated;
grant execute on function public.track_cargo_shipment(uuid) to authenticated;
