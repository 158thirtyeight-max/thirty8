-- =========================================================================
-- Schedules (Phase 10): departure, operating days, booking window and
-- cut-offs per bus service, plus a trip generator that honours them.
--
-- Stop times are stored as offsets from the origin departure (Phase 8), so
-- moving the departure time moves every stop consistently.
-- Local times are interpreted in Asia/Kolkata.
-- =========================================================================

alter table public.bus_services
  add column booking_open_days_before integer not null default 30
    check (booking_open_days_before between 1 and 365),
  add column booking_cutoff_min integer not null default 0
    check (booking_cutoff_min between 0 and 10080),
  add column boarding_cutoff_min integer not null default 0
    check (boarding_cutoff_min between 0 and 10080),
  add column schedule_configured boolean not null default false;

-- Existing services already run on a schedule; do not mark them unconfigured.
update public.bus_services set schedule_configured = true;

-- ---------------------------------------------------------------------
create or replace function public.validate_bus_schedule(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc public.bus_services;
  v_errors text[] := '{}';
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);
  if v_svc.id is null then
    return jsonb_build_object('valid', false, 'errors', jsonb_build_array('Configure the route before the schedule'));
  end if;

  if not v_svc.schedule_configured then
    v_errors := array_append(v_errors, 'The schedule has not been confirmed yet');
  end if;
  if coalesce(array_length(v_svc.operating_days, 1), 0) = 0 then
    v_errors := array_append(v_errors, 'No operating days are selected');
  end if;
  if v_svc.est_duration_min is null then
    v_errors := array_append(v_errors, 'Journey duration is missing (complete the route stop times)');
  end if;
  if v_svc.boarding_cutoff_min > v_svc.booking_cutoff_min + 1440 then
    v_errors := array_append(v_errors, 'The boarding cut-off is unreasonably earlier than the booking cut-off');
  end if;

  return jsonb_build_object('valid', coalesce(array_length(v_errors, 1), 0) = 0, 'errors', to_jsonb(v_errors),
                            'stats', jsonb_build_object('service_id', v_svc.id));
end;
$$;

revoke execute on function public.validate_bus_schedule(uuid) from public, anon;
grant execute on function public.validate_bus_schedule(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Saves the schedule of the bus's primary service.
-- Editable while setting up and once approved/active (schedules are
-- operational); locked while under review or suspended.
-- ---------------------------------------------------------------------
create or replace function public.save_bus_schedule(
  p_bus_id uuid,
  p_departure_time time,
  p_operating_days smallint[],
  p_booking_open_days_before integer,
  p_booking_cutoff_min integer,
  p_boarding_cutoff_min integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc uuid;
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_staff(v_bus.operator_id) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
  if not (v_bus.is_legacy or v_bus.lifecycle_status in ('draft', 'changes_requested', 'approved', 'active')) then
    raise exception 'The schedule is locked while the bus is %', v_bus.lifecycle_status;
  end if;
  if p_departure_time is null then raise exception 'Departure time is required'; end if;
  if p_operating_days is null or coalesce(array_length(p_operating_days, 1), 0) = 0 then
    raise exception 'Select at least one operating day';
  end if;

  v_svc := private.bus_primary_service(p_bus_id);
  if v_svc is null then raise exception 'Configure the route before the schedule'; end if;

  update public.bus_services
  set default_departure_time = p_departure_time,
      operating_days = p_operating_days,
      booking_open_days_before = p_booking_open_days_before,
      booking_cutoff_min = p_booking_cutoff_min,
      boarding_cutoff_min = p_boarding_cutoff_min,
      schedule_configured = true
  where id = v_svc;

  perform private.write_audit(
    'bus.schedule_saved', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'service_id', v_svc,
                       'departure', p_departure_time, 'days', p_operating_days)
  );
  return public.validate_bus_schedule(p_bus_id);
end;
$$;

revoke execute on function public.save_bus_schedule(uuid, time, smallint[], integer, integer, integer) from public, anon;
grant execute on function public.save_bus_schedule(uuid, time, smallint[], integer, integer, integer) to authenticated;

-- ---------------------------------------------------------------------
-- Generates dated trips for an ACTIVE bus over a date range (max 90 days),
-- on the service's operating days. Existing trips are left untouched.
-- Booking opens booking_open_days_before days ahead and closes
-- booking_cutoff_min minutes before departure. Returns the number created.
-- ---------------------------------------------------------------------
create or replace function public.generate_bus_trips(p_bus_id uuid, p_from date, p_to date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc public.bus_services;
  v_day date;
  v_dep timestamptz;
  v_count integer := 0;
  v_rows integer;
  i integer;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_staff(v_bus.operator_id) then raise exception 'Not authorized'; end if;
  if not private.is_bus_bookable(p_bus_id) then
    raise exception 'Trips can only be generated for an active bus of an approved operator';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 90 then
    raise exception 'Choose a date range of at most 90 days';
  end if;

  select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);
  if v_svc.id is null or not v_svc.schedule_configured then
    raise exception 'Confirm the schedule before generating trips';
  end if;
  if v_svc.status <> 'active' then
    raise exception 'The bus service is not active';
  end if;

  for i in 0 .. (p_to - p_from) loop
    v_day := p_from + i;
    if extract(isodow from v_day)::smallint = any (v_svc.operating_days) then
      v_dep := (v_day + v_svc.default_departure_time) at time zone 'Asia/Kolkata';
      insert into public.bus_trips (
        service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at,
        booking_open_at, booking_close_at
      ) values (
        v_svc.id, v_svc.operator_id, v_svc.route_id, v_svc.bus_id, v_day, v_dep,
        v_dep + make_interval(mins => v_svc.default_arrival_offset_minutes),
        greatest(v_dep - make_interval(days => v_svc.booking_open_days_before), now()),
        v_dep - make_interval(mins => v_svc.booking_cutoff_min)
      )
      on conflict (service_id, travel_date) do nothing;
      get diagnostics v_rows = row_count;
      v_count := v_count + v_rows;
    end if;
  end loop;

  perform private.write_audit(
    'bus.trips_generated', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'from', p_from, 'to', p_to, 'created', v_count)
  );
  return v_count;
end;
$$;

revoke execute on function public.generate_bus_trips(uuid, date, date) from public, anon;
grant execute on function public.generate_bus_trips(uuid, date, date) to authenticated;
