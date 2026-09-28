-- =========================================================================
-- Fix: get_cargo_quote() was declared without SECURITY DEFINER, so it ran
-- as the calling role (authenticated), which has no USAGE grant on the
-- `private` schema — every call failed with "permission denied for schema
-- private" the moment it hit private.select_best_cargo_quote(). Only
-- caught via a live REST API call as a real user; direct SQL testing as
-- postgres (superuser) never exercises schema privilege checks at all.
-- =========================================================================

create or replace function public.get_cargo_quote(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_cargo_type_id uuid,
  p_weight_kg numeric
)
returns jsonb
language plpgsql
stable
security definer
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
