-- =========================================================================
-- Phase 4 repair: close the legacy direct-write paths for operators
--   Operators could write bus_routes, boarding_points, dropping_points,
--   bus_services, bus_trips, fare_rules and fare_charges directly through
--   FOR ALL RLS policies that checked only operator ownership. That bypassed the
--   approval/lifecycle rules enforced by the RPCs (save_bus_route, save_bus_fares,
--   save_bus_schedule, generate_bus_trips): fares and routes of an approved bus
--   could be changed without review, and a trip could reference another
--   operator's bus.
--
--   1. public.set_trip_status(trip, status): the one controlled way an operator
--      (or admin) moves a trip along scheduled -> boarding -> departed -> arrived,
--      or cancels it. It replaces the operator app's direct UPDATE of
--      bus_trips.status. A trip with pending/confirmed bookings cannot be cancelled
--      here (that needs the refund workflow, a later phase).
--   2. Ownership guard triggers on bus_routes, bus_services and bus_trips: the bus,
--      service and route referenced by a row must belong to the row's operator.
--      They apply to everyone, including admin writes.
--   3. The seven operator `*_operator_manage` FOR ALL policies are dropped and
--      replaced by SELECT-only operator policies (so reads keep working when the
--      public read policies are tightened later). Writes now go through the RPCs
--      (SECURITY DEFINER) or platform admin (`*_admin_all`, unchanged).
--
--   Operator app: the legacy Routes / Trips screens must stop writing these tables
--   first (changed in the same release): apps/operator_app/lib/features/bus_ops/*.
--   Rollback: supabase/rollbacks/20261002000400_operator_write_lockdown.down.sql
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. Controlled trip status transitions
-- ---------------------------------------------------------------------
create or replace function public.set_trip_status(p_trip_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_trip public.bus_trips;
  v_new public.bus_trip_status;
  v_is_admin boolean := private.is_platform_admin();
  v_active_bookings integer;
begin
  if (select auth.uid()) is null then
    raise exception 'Must be authenticated';
  end if;

  begin
    v_new := p_status::public.bus_trip_status;
  exception when invalid_text_representation then
    raise exception 'invalid_status: unknown trip status %', p_status;
  end;

  select * into v_trip from public.bus_trips where id = p_trip_id for update;
  if v_trip.id is null then
    raise exception 'Trip not found';
  end if;
  if not (v_is_admin or private.is_operator_staff(v_trip.operator_id)) then
    raise exception 'Not authorized';
  end if;
  if not v_is_admin and not private.operator_is_approved(v_trip.operator_id) then
    raise exception 'Operator is not approved';
  end if;

  if not (
    (v_trip.status = 'scheduled' and v_new in ('boarding', 'cancelled'))
    or (v_trip.status = 'boarding' and v_new in ('departed', 'cancelled'))
    or (v_trip.status = 'departed' and v_new = 'arrived')
  ) then
    raise exception 'invalid_transition: a % trip cannot be set to %', v_trip.status, v_new;
  end if;

  if v_new = 'cancelled' then
    select count(*) into v_active_bookings
    from public.booking_items bi
    where bi.trip_id = p_trip_id and bi.status in ('payment_pending', 'confirmed');
    if v_active_bookings > 0 then
      raise exception 'trip_has_bookings: % passenger booking(s) exist for this trip; cancelling it needs the refund workflow', v_active_bookings;
    end if;
  end if;

  update public.bus_trips set status = v_new where id = p_trip_id;

  perform private.write_audit(
    'trip.status_changed', 'trip', p_trip_id,
    jsonb_build_object('status', v_trip.status),
    jsonb_build_object('status', v_new, 'operator_id', v_trip.operator_id)
  );

  return jsonb_build_object('trip_id', p_trip_id, 'status', v_new);
end;
$function$;

revoke execute on function public.set_trip_status(uuid, text) from public, anon;
grant execute on function public.set_trip_status(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Ownership guards
-- ---------------------------------------------------------------------
create or replace function private.guard_bus_route_ownership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if tg_op = 'UPDATE' and new.bus_id is not distinct from old.bus_id and new.operator_id = old.operator_id then
    return new;
  end if;
  if new.bus_id is not null and not exists (
    select 1 from public.buses b where b.id = new.bus_id and b.operator_id = new.operator_id
  ) then
    raise exception 'ownership_mismatch: the bus does not belong to this operator' using errcode = 'check_violation';
  end if;
  return new;
end;
$function$;

create or replace function private.guard_bus_service_ownership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if tg_op = 'UPDATE'
     and new.bus_id is not distinct from old.bus_id
     and new.route_id is not distinct from old.route_id
     and new.operator_id = old.operator_id then
    return new;
  end if;
  if new.bus_id is not null and not exists (
    select 1 from public.buses b where b.id = new.bus_id and b.operator_id = new.operator_id
  ) then
    raise exception 'ownership_mismatch: the bus does not belong to this operator' using errcode = 'check_violation';
  end if;
  if new.route_id is not null and not exists (
    select 1 from public.bus_routes r where r.id = new.route_id and r.operator_id = new.operator_id
  ) then
    raise exception 'ownership_mismatch: the route does not belong to this operator' using errcode = 'check_violation';
  end if;
  return new;
end;
$function$;

create or replace function private.guard_bus_trip_ownership()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_svc public.bus_services;
begin
  if tg_op = 'UPDATE'
     and new.bus_id is not distinct from old.bus_id
     and new.service_id is not distinct from old.service_id
     and new.route_id is not distinct from old.route_id
     and new.operator_id = old.operator_id then
    return new;
  end if;

  select * into v_svc from public.bus_services where id = new.service_id;
  if v_svc.id is null or v_svc.operator_id <> new.operator_id then
    raise exception 'ownership_mismatch: the service does not belong to this operator' using errcode = 'check_violation';
  end if;
  if v_svc.route_id is distinct from new.route_id then
    raise exception 'ownership_mismatch: the trip route differs from its service route' using errcode = 'check_violation';
  end if;
  if v_svc.bus_id is not null and v_svc.bus_id is distinct from new.bus_id then
    raise exception 'ownership_mismatch: the trip bus differs from its service bus' using errcode = 'check_violation';
  end if;
  if new.bus_id is not null and not exists (
    select 1 from public.buses b where b.id = new.bus_id and b.operator_id = new.operator_id
  ) then
    raise exception 'ownership_mismatch: the bus does not belong to this operator' using errcode = 'check_violation';
  end if;
  return new;
end;
$function$;

revoke execute on function private.guard_bus_route_ownership() from public, anon, authenticated;
revoke execute on function private.guard_bus_service_ownership() from public, anon, authenticated;
revoke execute on function private.guard_bus_trip_ownership() from public, anon, authenticated;

create trigger guard_bus_route_ownership before insert or update on public.bus_routes
  for each row execute function private.guard_bus_route_ownership();
create trigger guard_bus_service_ownership before insert or update on public.bus_services
  for each row execute function private.guard_bus_service_ownership();
create trigger guard_bus_trip_ownership before insert or update on public.bus_trips
  for each row execute function private.guard_bus_trip_ownership();

-- ---------------------------------------------------------------------
-- 3. Operators keep read access, lose direct write access
-- ---------------------------------------------------------------------
drop policy bus_routes_operator_manage on public.bus_routes;
drop policy bus_services_operator_manage on public.bus_services;
drop policy bus_trips_operator_manage on public.bus_trips;
drop policy boarding_points_operator_manage on public.boarding_points;
drop policy dropping_points_operator_manage on public.dropping_points;
drop policy fare_rules_operator_manage on public.fare_rules;
drop policy fare_charges_operator_manage on public.fare_charges;

create policy bus_routes_operator_select on public.bus_routes
  for select to authenticated using (private.is_operator_staff(operator_id));
create policy bus_services_operator_select on public.bus_services
  for select to authenticated using (private.is_operator_staff(operator_id));
create policy bus_trips_operator_select on public.bus_trips
  for select to authenticated using (private.is_operator_staff(operator_id));
create policy boarding_points_operator_select on public.boarding_points
  for select to authenticated using (exists (
    select 1 from public.bus_routes r where r.id = boarding_points.route_id and private.is_operator_staff(r.operator_id)));
create policy dropping_points_operator_select on public.dropping_points
  for select to authenticated using (exists (
    select 1 from public.bus_routes r where r.id = dropping_points.route_id and private.is_operator_staff(r.operator_id)));
create policy fare_rules_operator_select on public.fare_rules
  for select to authenticated using (exists (
    select 1 from public.bus_services s where s.id = fare_rules.service_id and private.is_operator_staff(s.operator_id)));
create policy fare_charges_operator_select on public.fare_charges
  for select to authenticated using (exists (
    select 1 from public.bus_services s where s.id = fare_charges.service_id and private.is_operator_staff(s.operator_id)));
