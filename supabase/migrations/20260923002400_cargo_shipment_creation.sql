-- =========================================================================
-- Cargo shipment creation: quote + create, dispatch-style operator
-- assignment (the customer never picks an operator — the cheapest matching
-- route/vehicle across all approved operators is selected automatically,
-- same as the plan's 5-step "Get Quote" -> "Confirm & Pay" flow implies).
--
-- Locks down cargo_shipments so price/status can never be set by the client
-- directly (same principle as bookings): no INSERT policy at all, and the
-- previous customer UPDATE policy is dropped — cancellation still goes
-- through cancel_shipment() (already built in Phase 1).
-- =========================================================================

drop policy if exists cargo_shipments_insert_own on public.cargo_shipments;
drop policy if exists cargo_shipments_update_own_draft on public.cargo_shipments;

-- Shared quote logic: cheapest active (route, vehicle_type) match for a
-- source/destination/cargo_type/weight, across all approved operators.
-- Not exposed via API (lives in `private`).
create or replace function private.select_best_cargo_quote(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_cargo_type_id uuid,
  p_weight_kg numeric
)
returns table (
  route_id uuid,
  operator_id uuid,
  vehicle_type_id uuid,
  distance_km numeric,
  base_fare_cents integer,
  distance_fare_cents integer,
  weight_fare_cents integer,
  surcharge_cents integer,
  total_fare_cents integer
)
language sql
stable
set search_path = ''
as $$
  select
    r.id as route_id,
    r.operator_id,
    vt.id as vehicle_type_id,
    coalesce(r.distance_km, 0) as distance_km,
    pr.base_fare_cents,
    round(pr.per_km_cents * coalesce(r.distance_km, 0))::integer as distance_fare_cents,
    round(pr.per_kg_cents * p_weight_kg)::integer as weight_fare_cents,
    pr.surcharge_cents,
    pr.base_fare_cents
      + round(pr.per_km_cents * coalesce(r.distance_km, 0))::integer
      + round(pr.per_kg_cents * p_weight_kg)::integer
      + pr.surcharge_cents as total_fare_cents
  from public.cargo_routes r
  join public.operators o on o.id = r.operator_id and o.status = 'approved'
  join public.cargo_pricing_rules pr on pr.route_id = r.id
    and pr.cargo_type_id = p_cargo_type_id
    and pr.effective_from <= current_date
    and (pr.effective_to is null or pr.effective_to >= current_date)
  join public.cargo_vehicle_types vt on vt.id = pr.vehicle_type_id and vt.max_weight_kg >= p_weight_kg
  where r.active
    and r.source_city_id = p_source_city_id
    and r.destination_city_id = p_destination_city_id
  order by vt.max_weight_kg asc, total_fare_cents asc
  limit 1;
$$;

-- Public quote preview (Step 5 "Get Quote" in the customer flow) — no
-- commitment, no shipment row created yet.
create or replace function public.get_cargo_quote(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_cargo_type_id uuid,
  p_weight_kg numeric
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_quote record;
begin
  select * into v_quote from private.select_best_cargo_quote(p_source_city_id, p_destination_city_id, p_cargo_type_id, p_weight_kg);

  if v_quote.route_id is null then
    raise exception 'No operator currently serves this route for the given weight/cargo type';
  end if;

  return jsonb_build_object(
    'distance_km', v_quote.distance_km,
    'base_fare_cents', v_quote.base_fare_cents,
    'distance_fare_cents', v_quote.distance_fare_cents,
    'weight_fare_cents', v_quote.weight_fare_cents,
    'surcharge_cents', v_quote.surcharge_cents,
    'total_fare_cents', v_quote.total_fare_cents
  );
end;
$$;

-- Creates the shipment (status 'draft') + its order, re-running the same
-- quote logic server-side so the client can never dictate the price.
-- p_shipment carries every customer-entered field as JSON (package details,
-- pickup/delivery, speed) — see supabase/functions/README.md (Phase 4) for
-- the expected shape once the client is built.
create or replace function public.create_shipment(p_shipment jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_quote record;
  v_shipment_id uuid;
  v_shipment_reference text;
  v_order_id uuid;
  v_order_reference text;
  v_source_city_id uuid := (p_shipment ->> 'source_city_id')::uuid;
  v_destination_city_id uuid := (p_shipment ->> 'destination_city_id')::uuid;
  v_cargo_type_id uuid := (p_shipment ->> 'cargo_type_id')::uuid;
  v_weight_kg numeric := (p_shipment ->> 'weight_kg')::numeric;
  v_pickup_type public.cargo_point_type := (p_shipment ->> 'pickup_type')::public.cargo_point_type;
  v_delivery_type public.cargo_point_type := (p_shipment ->> 'delivery_type')::public.cargo_point_type;
begin
  if v_user_id is null then
    raise exception 'Must be authenticated';
  end if;
  if v_weight_kg is null or v_weight_kg <= 0 then
    raise exception 'weight_kg is required and must be positive';
  end if;

  select * into v_quote
  from private.select_best_cargo_quote(v_source_city_id, v_destination_city_id, v_cargo_type_id, v_weight_kg);

  if v_quote.route_id is null then
    raise exception 'No operator currently serves this route for the given weight/cargo type';
  end if;

  v_shipment_reference := 'TC' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));

  insert into public.cargo_shipments (
    shipment_reference, sender_user_id, operator_id, route_id, cargo_type_id,
    description, weight_kg, length_cm, width_cm, height_cm, declared_value_cents, special_instructions,
    pickup_type, pickup_address, pickup_latitude, pickup_longitude, pickup_hub_id,
    pickup_contact_name, pickup_contact_phone, pickup_scheduled_at,
    delivery_type, delivery_address, delivery_latitude, delivery_longitude, delivery_hub_id,
    delivery_contact_name, delivery_contact_phone, delivery_scheduled_at,
    shipping_speed, currency_code,
    base_fare_cents, distance_fare_cents, weight_fare_cents, surcharge_cents, total_fare_cents,
    status
  ) values (
    v_shipment_reference, v_user_id, v_quote.operator_id, v_quote.route_id, v_cargo_type_id,
    p_shipment ->> 'description', v_weight_kg,
    (p_shipment ->> 'length_cm')::numeric, (p_shipment ->> 'width_cm')::numeric, (p_shipment ->> 'height_cm')::numeric,
    (p_shipment ->> 'declared_value_cents')::integer, p_shipment ->> 'special_instructions',
    v_pickup_type, p_shipment ->> 'pickup_address',
    (p_shipment ->> 'pickup_latitude')::numeric, (p_shipment ->> 'pickup_longitude')::numeric,
    (p_shipment ->> 'pickup_hub_id')::uuid,
    p_shipment ->> 'pickup_contact_name', p_shipment ->> 'pickup_contact_phone',
    (p_shipment ->> 'pickup_scheduled_at')::timestamptz,
    v_delivery_type, p_shipment ->> 'delivery_address',
    (p_shipment ->> 'delivery_latitude')::numeric, (p_shipment ->> 'delivery_longitude')::numeric,
    (p_shipment ->> 'delivery_hub_id')::uuid,
    p_shipment ->> 'delivery_contact_name', p_shipment ->> 'delivery_contact_phone',
    (p_shipment ->> 'delivery_scheduled_at')::timestamptz,
    coalesce(p_shipment ->> 'shipping_speed', 'standard')::public.cargo_speed, 'INR',
    v_quote.base_fare_cents, v_quote.distance_fare_cents, v_quote.weight_fare_cents, v_quote.surcharge_cents, v_quote.total_fare_cents,
    'draft'
  )
  returning id into v_shipment_id;

  insert into public.cargo_status_history (shipment_id, from_status, to_status, changed_by)
  values (v_shipment_id, null, 'draft', v_user_id);

  v_order_reference := 'ORC' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  insert into public.orders (order_reference, orderable_type, orderable_id, customer_id, amount_cents, status)
  values (v_order_reference, 'cargo_shipment', v_shipment_id, v_user_id, v_quote.total_fare_cents, 'created')
  returning id into v_order_id;

  return jsonb_build_object(
    'shipment_id', v_shipment_id,
    'shipment_reference', v_shipment_reference,
    'order_id', v_order_id,
    'order_reference', v_order_reference,
    'amount_cents', v_quote.total_fare_cents
  );
end;
$$;

revoke execute on function public.create_shipment(jsonb) from public, anon;
grant execute on function public.create_shipment(jsonb) to authenticated;
grant execute on function public.get_cargo_quote(uuid, uuid, uuid, numeric) to anon, authenticated;
