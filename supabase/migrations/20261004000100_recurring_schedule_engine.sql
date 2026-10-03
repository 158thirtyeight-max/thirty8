-- =========================================================================
-- Centralized recurring schedule + rolling booking window engine (v2).
--
-- Written against the LIVE schema (which already has the per-bus schedule
-- model: bus_services.operating_days / booking_cutoff_min / boarding_cutoff_min /
-- schedule_configured, save_bus_schedule, generate_bus_trips,
-- private.trip_is_open_for_booking, operator write lockdown via RPCs).
-- It supersedes the unapplied 20260926000100 draft.
--
--   A. Recurring template  = public.bus_services          (existing)
--   B. Departure instance  = public.bus_trips (+ trip_seats via existing trigger)
--   C. Booking window      = scheduling_settings / route_booking_windows /
--                            operator_booking_window_overrides   (new, admin only)
--
-- Single enforcement point for customers: private.trip_is_open_for_booking
-- (already used by search_trips and create_seat_hold) now includes the horizon.
-- Single generator: private.generate_service_trips (cron + immediate triggers);
-- the old manual public.generate_bus_trips becomes a thin wrapper around it.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Admin-controlled configuration
-- -------------------------------------------------------------------------

create table public.scheduling_settings (
  id boolean primary key default true check (id),          -- singleton
  timezone text not null default 'Asia/Kolkata',
  default_advance_days integer not null default 30,
  min_advance_days integer not null default 1,
  max_advance_days integer not null default 180,
  allow_operator_overrides boolean not null default false,
  default_booking_close_minutes integer not null default 0,
  max_booking_close_minutes integer not null default 1440,
  default_boarding_cutoff_minutes integer not null default 15,
  max_boarding_cutoff_minutes integer not null default 1440,
  allow_operator_booking_rules boolean not null default true,
  updated_by uuid references public.profiles (id),
  updated_at timestamptz not null default now(),
  constraint scheduling_settings_advance_bounds_chk
    check (min_advance_days >= 1 and min_advance_days <= default_advance_days and default_advance_days <= max_advance_days),
  constraint scheduling_settings_rule_bounds_chk
    check (default_booking_close_minutes between 0 and max_booking_close_minutes
       and default_boarding_cutoff_minutes between 0 and max_boarding_cutoff_minutes)
);
insert into public.scheduling_settings (id) values (true);

create table public.route_booking_windows (
  route_id uuid primary key references public.bus_routes (id) on delete cascade,
  advance_days integer not null check (advance_days >= 1),
  override_enabled boolean not null default true,
  note text,
  updated_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.operator_booking_window_overrides (
  operator_id uuid primary key references public.operators (id) on delete cascade,
  advance_days integer not null check (advance_days >= 1),
  is_enabled boolean not null default true,
  note text,
  approved_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at before update on public.route_booking_windows
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.operator_booking_window_overrides
  for each row execute function private.set_updated_at();

-- -------------------------------------------------------------------------
-- 2. Template / instance columns
-- -------------------------------------------------------------------------

-- schedule_paused is the OPERATOR's pause of future generation. It is kept
-- separate from bus_services.status, which the bus approval lifecycle owns.
alter table public.bus_services
  add column schedule_paused boolean not null default false,
  add column last_generated_at timestamptz,
  add column generated_through date;

alter table public.bus_trips
  add column boarding_cutoff_at timestamptz,
  add column generated_by text not null default 'manual' check (generated_by in ('manual', 'scheduler', 'migrated')),
  add column cancellation_request_status text not null default 'none'
    check (cancellation_request_status in ('none', 'requested', 'approved', 'rejected')),
  add column cancellation_reason text,
  add column cancellation_requested_by uuid references public.profiles (id),
  add column cancellation_requested_at timestamptz,
  add column cancellation_decided_by uuid references public.profiles (id),
  add column cancellation_decided_at timestamptz,
  add column cancellation_decision_note text;

create index bus_trips_cancellation_requested_idx on public.bus_trips (cancellation_requested_at)
  where cancellation_request_status = 'requested';

-- Existing future departures are adopted by the engine (never deleted once a
-- booking or live hold exists — see reconcile below). Done before any new
-- trigger exists so nothing regenerates during the migration.
update public.bus_trips set generated_by = 'migrated'
where travel_date >= current_date and status = 'scheduled';

create table public.schedule_exceptions (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.bus_services (id) on delete cascade,
  exception_type text not null default 'suspension' check (exception_type in ('suspension')),
  start_date date not null,
  end_date date not null,
  reason text,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  constraint schedule_exceptions_range_chk check (end_date >= start_date)
);
create index schedule_exceptions_service_idx on public.schedule_exceptions (service_id, start_date, end_date);

create table public.schedule_generation_runs (
  id uuid primary key default gen_random_uuid(),
  trigger_source text not null,
  status text not null default 'running' check (status in ('running', 'completed', 'completed_with_errors', 'failed')),
  services_processed integer not null default 0,
  trips_created integer not null default 0,
  error_count integer not null default 0,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index schedule_generation_runs_started_idx on public.schedule_generation_runs (started_at desc);

create table public.schedule_generation_errors (
  id uuid primary key default gen_random_uuid(),
  run_id uuid references public.schedule_generation_runs (id) on delete cascade,
  service_id uuid references public.bus_services (id) on delete cascade,
  error_code text not null,
  message text not null,
  created_at timestamptz not null default now()
);
create index schedule_generation_errors_run_idx on public.schedule_generation_errors (run_id);
create index schedule_generation_errors_service_idx on public.schedule_generation_errors (service_id, created_at desc);
create index schedule_generation_errors_created_idx on public.schedule_generation_errors (created_at desc);

-- -------------------------------------------------------------------------
-- 3. Audit (existing public.audit_logs)
-- -------------------------------------------------------------------------

create or replace function private.audit_scheduling_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_id text := coalesce(v_new, v_old) ->> tg_argv[1];
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return new;
  end if;
  perform private.write_audit(
    lower(tg_op), tg_argv[0],
    case when v_id ~* '^[0-9a-f-]{36}$' then v_id::uuid end,
    v_old, v_new
  );
  return coalesce(new, old);
end;
$$;

create trigger audit_change after insert or update or delete on public.scheduling_settings
  for each row execute function private.audit_scheduling_change('scheduling_settings', 'none');
create trigger audit_change after insert or update or delete on public.route_booking_windows
  for each row execute function private.audit_scheduling_change('route_booking_window', 'route_id');
create trigger audit_change after insert or update or delete on public.operator_booking_window_overrides
  for each row execute function private.audit_scheduling_change('operator_booking_window', 'operator_id');
create trigger audit_change after insert or update or delete on public.schedule_exceptions
  for each row execute function private.audit_scheduling_change('schedule_exception', 'id');

create or replace function private.audit_service_schedule_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (new.status, new.schedule_paused, new.schedule_configured, new.operating_days, new.default_departure_time,
      new.default_arrival_offset_minutes, new.bus_id, new.booking_cutoff_min, new.boarding_cutoff_min)
     is distinct from
     (old.status, old.schedule_paused, old.schedule_configured, old.operating_days, old.default_departure_time,
      old.default_arrival_offset_minutes, old.bus_id, old.booking_cutoff_min, old.boarding_cutoff_min) then
    perform private.write_audit('schedule.updated', 'recurring_schedule', new.id, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

create trigger audit_schedule_change after update on public.bus_services
  for each row execute function private.audit_service_schedule_change();

-- -------------------------------------------------------------------------
-- 4. Booking window resolution (single source of truth)
--    route override -> admin-approved operator override -> global default,
--    always clamped to the admin min/max.
-- -------------------------------------------------------------------------

create or replace function private.effective_booking_window(p_route_id uuid)
returns table (advance_days integer, source text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s public.scheduling_settings;
  v_operator_id uuid;
  v_days integer;
  v_source text;
begin
  select * into s from public.scheduling_settings where id;
  select r.operator_id into v_operator_id from public.bus_routes r where r.id = p_route_id;

  select rw.advance_days into v_days
  from public.route_booking_windows rw
  where rw.route_id = p_route_id and rw.override_enabled;
  if found then
    v_source := 'route';
  elsif s.allow_operator_overrides then
    select oo.advance_days into v_days
    from public.operator_booking_window_overrides oo
    where oo.operator_id = v_operator_id and oo.is_enabled;
    if found then
      v_source := 'operator';
    end if;
  end if;

  if v_days is null then
    v_days := s.default_advance_days;
    v_source := 'global';
  end if;

  return query select least(s.max_advance_days, greatest(s.min_advance_days, v_days)), v_source;
end;
$$;

create or replace function private.platform_today()
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (now() at time zone (select timezone from public.scheduling_settings where id))::date;
$$;

-- Last bookable travel date (inclusive). Computed, never stored: it rolls
-- forward daily and follows admin changes immediately.
create or replace function private.booking_horizon_date(p_route_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select private.platform_today() + (select w.advance_days from private.effective_booking_window(p_route_id) w);
$$;

create or replace function public.get_effective_booking_window(p_route_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'advance_days', w.advance_days,
    'source', w.source,
    'timezone', (select timezone from public.scheduling_settings where id),
    'today', private.platform_today(),
    'horizon_date', private.platform_today() + w.advance_days
  )
  from private.effective_booking_window(p_route_id) w;
$$;

-- Latest bookable date for a source/destination pair; falls back to the global
-- default so the customer app never has to invent a window itself.
create or replace function public.get_max_booking_date(p_source_city_id uuid, p_destination_city_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select max(private.booking_horizon_date(sv.route_id))
     from public.bus_services sv
     where sv.status = 'active' and not sv.schedule_paused
       and sv.service_source_city_id = p_source_city_id
       and sv.service_dest_city_id = p_destination_city_id),
    private.platform_today() + (select default_advance_days from public.scheduling_settings where id)
  );
$$;

-- THE customer-facing gate. search_trips and create_seat_hold already call this,
-- so adding the horizon (and pending-cancellation) here enforces both.
create or replace function private.trip_is_open_for_booking(p_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.bus_trips t
    where t.id = p_trip_id
      and t.status = 'scheduled'
      and t.cancellation_request_status <> 'requested'
      and t.departure_at > now()
      and t.booking_open_at <= now()
      and coalesce(t.booking_close_at, t.departure_at) > now()
      and t.travel_date <= private.booking_horizon_date(t.route_id)
  );
$$;

-- -------------------------------------------------------------------------
-- 5. Generation engine
-- -------------------------------------------------------------------------

create or replace function private.log_generation_error(p_run_id uuid, p_service_id uuid, p_code text, p_message text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.schedule_generation_errors (run_id, service_id, error_code, message)
  values (p_run_id, p_service_id, p_code, p_message);
$$;

-- Withdraws engine-owned future departures that no longer match the template
-- (time, bus, removed operating day, suspension) — only if nothing depends on
-- them: no booking items and no live seat hold. Booked departures are never touched.
create or replace function private.reconcile_service_trips(p_service_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
  v_tz text;
  v_deleted integer;
begin
  select * into v_svc from public.bus_services where id = p_service_id;
  select timezone into v_tz from public.scheduling_settings where id;

  delete from public.bus_trips t
  where t.service_id = p_service_id
    and t.generated_by in ('scheduler', 'migrated')
    and t.status = 'scheduled'
    and t.travel_date >= private.platform_today()
    and not exists (select 1 from public.booking_items bi where bi.trip_id = t.id)
    and not exists (select 1 from public.seat_holds sh where sh.trip_id = t.id and sh.status = 'active' and sh.expires_at > now())
    and (
      not (extract(isodow from t.travel_date)::smallint = any (v_svc.operating_days))
      or t.bus_id <> v_svc.bus_id
      or t.departure_at <> ((t.travel_date + v_svc.default_departure_time) at time zone v_tz)
      or t.arrival_at is distinct from (((t.travel_date + v_svc.default_departure_time) at time zone v_tz)
                                        + make_interval(mins => v_svc.default_arrival_offset_minutes))
      or exists (
        select 1 from public.schedule_exceptions e
        where e.service_id = p_service_id and t.travel_date between e.start_date and e.end_date
      )
    );
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- Idempotent, concurrency-safe generation for ONE service: creates only the
-- missing departures in [today, today + effective advance days] on operating
-- days, never touching existing rows. Same eligibility gates as the live
-- manual generator (approved operator, active bus, configured + active service).
create or replace function private.generate_service_trips(p_service_id uuid, p_run_id uuid default null, p_log_missing_setup boolean default true)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
  s public.scheduling_settings;
  v_route_active boolean;
  v_today date;
  v_horizon date;
  v_days integer;
  v_close integer;
  v_cutoff integer;
  v_seats integer;
  v_created integer := 0;
  v_no_fare integer := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended('thirty8.service_generation:' || p_service_id::text, 0));

  select * into v_svc from public.bus_services where id = p_service_id;
  if v_svc.id is null or v_svc.status <> 'active' or v_svc.schedule_paused or not v_svc.schedule_configured then
    return 0;
  end if;
  select r.active into v_route_active from public.bus_routes r where r.id = v_svc.route_id;
  if not coalesce(v_route_active, false)
     or not private.operator_is_approved(v_svc.operator_id)
     or not private.is_bus_bookable(v_svc.bus_id) then
    return 0;   -- nothing is published for unapproved operators / inactive buses or routes
  end if;

  select * into s from public.scheduling_settings where id;
  v_today := private.platform_today();
  select w.advance_days into v_days from private.effective_booking_window(v_svc.route_id) w;
  v_horizon := v_today + v_days;

  perform private.reconcile_service_trips(p_service_id);

  select count(*) into v_seats
  from public.seats se
  join public.bus_layouts bl on bl.id = se.bus_layout_id
  where bl.bus_id = v_svc.bus_id and bl.is_active and se.kind = 'bookable';
  if v_seats = 0 then
    if p_log_missing_setup then
      perform private.log_generation_error(p_run_id, p_service_id, 'no_seat_layout',
        'Bus has no active seat layout; no departures were generated');
    end if;
    return 0;
  end if;

  v_close := case when s.allow_operator_booking_rules
                  then least(v_svc.booking_cutoff_min, s.max_booking_close_minutes)
                  else s.default_booking_close_minutes end;
  v_cutoff := case when s.allow_operator_booking_rules
                   then least(v_svc.boarding_cutoff_min, s.max_boarding_cutoff_minutes)
                   else s.default_boarding_cutoff_minutes end;

  -- Dates with no fare rule would be sold at ₹0 (resolve_seat_fare falls back to 0): skip and report.
  select count(*) into v_no_fare
  from generate_series(v_today, v_horizon, interval '1 day') g(d)
  where extract(isodow from g.d)::smallint = any (v_svc.operating_days)
    and not exists (select 1 from public.schedule_exceptions e where e.service_id = v_svc.id and g.d::date between e.start_date and e.end_date)
    and not exists (select 1 from public.bus_trips t where t.service_id = v_svc.id and t.travel_date = g.d::date)
    and not exists (
      select 1 from public.fare_rules fr
      where fr.service_id = v_svc.id and fr.effective_from <= g.d::date and (fr.effective_to is null or fr.effective_to >= g.d::date)
    );

  insert into public.bus_trips (
    service_id, operator_id, route_id, bus_id, travel_date, departure_at, arrival_at,
    booking_open_at, booking_close_at, boarding_cutoff_at, generated_by
  )
  select
    v_svc.id, v_svc.operator_id, v_svc.route_id, v_svc.bus_id, g.d::date,
    dep.ts,
    dep.ts + make_interval(mins => v_svc.default_arrival_offset_minutes),
    now(),
    dep.ts - make_interval(mins => v_close),
    dep.ts - make_interval(mins => v_cutoff),
    'scheduler'
  from generate_series(v_today, v_horizon, interval '1 day') g(d)
  cross join lateral (select ((g.d::date + v_svc.default_departure_time) at time zone s.timezone) as ts) dep
  where extract(isodow from g.d)::smallint = any (v_svc.operating_days)
    and dep.ts > now()
    and not exists (select 1 from public.schedule_exceptions e where e.service_id = v_svc.id and g.d::date between e.start_date and e.end_date)
    and exists (
      select 1 from public.fare_rules fr
      where fr.service_id = v_svc.id and fr.effective_from <= g.d::date and (fr.effective_to is null or fr.effective_to >= g.d::date)
    )
  on conflict (service_id, travel_date) do nothing;
  get diagnostics v_created = row_count;
  -- trip_seats come from the existing generate_trip_seats trigger, one set per new trip.

  -- Keep close / cut-off in step with the rules for engine-owned, not-yet-departed trips.
  update public.bus_trips t
  set booking_close_at = t.departure_at - make_interval(mins => v_close),
      boarding_cutoff_at = t.departure_at - make_interval(mins => v_cutoff)
  where t.service_id = v_svc.id
    and t.generated_by in ('scheduler', 'migrated')
    and t.status = 'scheduled'
    and t.travel_date >= v_today
    and (t.booking_close_at is distinct from t.departure_at - make_interval(mins => v_close)
      or t.boarding_cutoff_at is distinct from t.departure_at - make_interval(mins => v_cutoff));

  if v_no_fare > 0 and p_log_missing_setup then
    perform private.log_generation_error(p_run_id, p_service_id, 'no_fare_rule',
      format('%s eligible departure date(s) skipped: no fare rule configured for the service', v_no_fare));
  end if;

  -- The operator-facing legacy column mirrors the admin window (read-only for operators).
  update public.bus_services
  set last_generated_at = now(), generated_through = v_horizon,
      booking_open_days_before = v_days
  where id = p_service_id;

  return v_created;
end;
$$;

create or replace function private.run_rolling_schedule_generation(p_trigger text default 'cron')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run uuid;
  r record;
  v_created integer;
  v_total integer := 0;
  v_services integer := 0;
  v_errors integer;
begin
  insert into public.schedule_generation_runs (trigger_source) values (p_trigger) returning id into v_run;

  for r in
    select id from public.bus_services
    where status = 'active' and not schedule_paused and schedule_configured
    order by id
  loop
    v_services := v_services + 1;
    begin
      v_created := private.generate_service_trips(r.id, v_run);
      v_total := v_total + coalesce(v_created, 0);
    exception when others then
      perform private.log_generation_error(v_run, r.id, 'exception', sqlstate || ': ' || sqlerrm);
    end;
  end loop;

  select count(*) into v_errors from public.schedule_generation_errors where run_id = v_run;
  update public.schedule_generation_runs
  set services_processed = v_services, trips_created = v_total, error_count = v_errors,
      status = case when v_errors > 0 then 'completed_with_errors' else 'completed' end,
      finished_at = now()
  where id = v_run;

  delete from public.schedule_generation_runs where started_at < now() - interval '90 days';
  return v_run;
end;
$$;

-- Trigger-path generation must never fail the caller's save: errors are logged instead.
create or replace function private.generate_service_trips_safe(p_service_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.generate_service_trips(p_service_id, null, false);
exception when others then
  perform private.log_generation_error(null, p_service_id, 'exception', sqlstate || ': ' || sqlerrm);
end;
$$;

create or replace function private.generate_for_route(p_route_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select id from public.bus_services
           where route_id = p_route_id and status = 'active' and not schedule_paused and schedule_configured loop
    perform private.generate_service_trips_safe(r.id);
  end loop;
end;
$$;

-- -------------------------------------------------------------------------
-- 6. Triggers: changes take effect immediately (cron is the safety net)
-- -------------------------------------------------------------------------

create or replace function private.on_service_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status <> 'active' or new.schedule_paused or not new.schedule_configured then
    return null;
  end if;
  if tg_op = 'INSERT'
     or (old.status, old.schedule_paused, old.schedule_configured, old.operating_days, old.default_departure_time,
         old.default_arrival_offset_minutes, old.bus_id, old.booking_cutoff_min, old.boarding_cutoff_min)
        is distinct from
        (new.status, new.schedule_paused, new.schedule_configured, new.operating_days, new.default_departure_time,
         new.default_arrival_offset_minutes, new.bus_id, new.booking_cutoff_min, new.boarding_cutoff_min) then
    perform private.generate_service_trips_safe(new.id);
  end if;
  return null;
end;
$$;

create trigger generate_on_service_change after insert or update on public.bus_services
  for each row execute function private.on_service_changed();

create or replace function private.on_route_window_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.generate_for_route(coalesce(new.route_id, old.route_id));
  return null;
end;
$$;

create trigger generate_on_route_window_change after insert or update or delete on public.route_booking_windows
  for each row execute function private.on_route_window_changed();

create or replace function private.on_global_window_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.run_rolling_schedule_generation('config_change');
  return null;
end;
$$;

create trigger generate_on_settings_change after update on public.scheduling_settings
  for each statement execute function private.on_global_window_changed();
create trigger generate_on_operator_override_change after insert or update or delete on public.operator_booking_window_overrides
  for each statement execute function private.on_global_window_changed();

-- -------------------------------------------------------------------------
-- 7. Existing manual entry points now delegate to the central engine
-- -------------------------------------------------------------------------

-- Signature kept for app compatibility. The date range is ignored: the
-- horizon is admin-controlled, and generation is idempotent.
create or replace function public.generate_bus_trips(p_bus_id uuid, p_from date, p_to date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc record;
  v_count integer := 0;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not private.is_operator_staff(v_bus.operator_id) then raise exception 'Not authorized'; end if;
  if not private.is_bus_bookable(p_bus_id) then
    raise exception 'Trips can only be generated for an active bus of an approved operator';
  end if;
  if not exists (select 1 from public.bus_services where bus_id = p_bus_id and schedule_configured) then
    raise exception 'Confirm the schedule before generating trips';
  end if;

  for v_svc in
    select id from public.bus_services
    where bus_id = p_bus_id and status = 'active' and not schedule_paused and schedule_configured
    order by direction desc, created_at
  loop
    v_count := v_count + private.generate_service_trips(v_svc.id, null, true);
  end loop;

  perform private.write_audit('bus.trips_generated', 'bus', p_bus_id, null,
    jsonb_build_object('operator_id', v_bus.operator_id, 'created', v_count, 'engine', 'central'));
  return v_count;
end;
$$;

-- Same contract as before, but operators can no longer set the booking horizon:
-- p_booking_open_days_before is ignored (mirrored from the admin window), and
-- cut-offs are validated against the admin maximums.
create or replace function public.save_bus_schedule(
  p_bus_id uuid, p_departure_time time, p_operating_days smallint[],
  p_booking_open_days_before integer, p_booking_cutoff_min integer, p_boarding_cutoff_min integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_svc uuid;
  v_route uuid;
  s public.scheduling_settings;
  v_close integer := p_booking_cutoff_min;
  v_cutoff integer := p_boarding_cutoff_min;
  v_days integer;
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
  if not (p_operating_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]) then
    raise exception 'Operating days must be between 1 (Mon) and 7 (Sun)';
  end if;

  v_svc := private.bus_primary_service(p_bus_id);
  if v_svc is null then raise exception 'Configure the route before the schedule'; end if;
  select route_id into v_route from public.bus_services where id = v_svc;

  select * into s from public.scheduling_settings where id;
  if s.allow_operator_booking_rules then
    if v_close < 0 or v_cutoff < 0 or v_close > s.max_booking_close_minutes or v_cutoff > s.max_boarding_cutoff_minutes then
      raise exception 'Booking close / boarding cut-off must be between 0 and % / % minutes',
        s.max_booking_close_minutes, s.max_boarding_cutoff_minutes;
    end if;
  else
    v_close := s.default_booking_close_minutes;
    v_cutoff := s.default_boarding_cutoff_minutes;
  end if;
  select w.advance_days into v_days from private.effective_booking_window(v_route) w;

  update public.bus_services
  set default_departure_time = p_departure_time,
      operating_days = p_operating_days,
      booking_open_days_before = v_days,          -- admin-controlled; the parameter is ignored
      booking_cutoff_min = v_close,
      boarding_cutoff_min = v_cutoff,
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

-- -------------------------------------------------------------------------
-- 8. Operator RPCs: pause / resume / suspend / cancellation request / overview
-- -------------------------------------------------------------------------

create or replace function private.assert_bus_schedule_access(p_bus_id uuid, p_mutating boolean)
returns public.buses
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (private.is_operator_staff(v_bus.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  if p_mutating and not private.is_platform_admin() and not private.operator_is_approved(v_bus.operator_id) then
    raise exception 'The operator account is not approved';
  end if;
  return v_bus;
end;
$$;

-- Pause / resume future generation for every service of the bus. Existing
-- departures and bookings are untouched. Resuming generates the missing departures.
create or replace function public.set_bus_schedule_paused(p_bus_id uuid, p_paused boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assert_bus_schedule_access(p_bus_id, true);
  update public.bus_services set schedule_paused = coalesce(p_paused, false) where bus_id = p_bus_id and status <> 'retired';
  return jsonb_build_object('bus_id', p_bus_id, 'paused', coalesce(p_paused, false));
end;
$$;

-- Temporary suspension for a date range (all services of the bus). Unsold
-- departures in the range are withdrawn; departures that already have bookings
-- are flagged for the admin cancellation/refund workflow, never auto-cancelled.
create or replace function public.suspend_bus_dates(p_bus_id uuid, p_start date, p_end date, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc record;
  v_removed integer := 0;
  v_flagged integer := 0;
  v_n integer;
begin
  perform private.assert_bus_schedule_access(p_bus_id, true);
  if p_start is null or p_end is null or p_end < p_start then raise exception 'Invalid date range'; end if;
  if p_start < private.platform_today() then raise exception 'Suspension cannot start in the past'; end if;

  for v_svc in select id from public.bus_services where bus_id = p_bus_id and status <> 'retired' loop
    insert into public.schedule_exceptions (service_id, start_date, end_date, reason, created_by)
    values (v_svc.id, p_start, p_end, p_reason, (select auth.uid()));

    v_removed := v_removed + private.reconcile_service_trips(v_svc.id);

    update public.bus_trips t
    set cancellation_request_status = 'requested',
        cancellation_reason = coalesce(nullif(p_reason, ''), 'Temporary service suspension'),
        cancellation_requested_by = (select auth.uid()),
        cancellation_requested_at = now()
    where t.service_id = v_svc.id
      and t.travel_date between p_start and p_end
      and t.status = 'scheduled'
      and t.cancellation_request_status <> 'requested'
      and exists (select 1 from public.booking_items bi where bi.trip_id = t.id and bi.status in ('confirmed', 'payment_pending'));
    get diagnostics v_n = row_count;
    v_flagged := v_flagged + v_n;
  end loop;

  return jsonb_build_object('removed_departures', v_removed, 'cancellation_requests', v_flagged);
end;
$$;

create or replace function public.remove_bus_suspension(p_exception_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_service_id uuid;
  v_bus_id uuid;
begin
  select e.service_id, s.bus_id into v_service_id, v_bus_id
  from public.schedule_exceptions e join public.bus_services s on s.id = e.service_id
  where e.id = p_exception_id;
  if v_service_id is null then raise exception 'Suspension not found'; end if;
  perform private.assert_bus_schedule_access(v_bus_id, true);
  delete from public.schedule_exceptions where id = p_exception_id;
  perform private.generate_service_trips_safe(v_service_id);
  return jsonb_build_object('service_id', v_service_id);
end;
$$;

-- Operator asks to cancel ONE departure. The admin decides; approval runs the
-- existing cancel_booking -> refund request -> admin refund approval workflow.
create or replace function public.request_trip_cancellation(p_trip_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
begin
  select * into v_trip from public.bus_trips where id = p_trip_id for update;
  if v_trip.id is null then raise exception 'Departure not found'; end if;
  if not (private.is_operator_staff(v_trip.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;
  if not private.is_platform_admin() and not private.operator_is_approved(v_trip.operator_id) then
    raise exception 'Operator is not approved';
  end if;
  if v_trip.status <> 'scheduled' then
    raise exception 'Only scheduled departures can be cancelled (status is %)', v_trip.status;
  end if;
  if v_trip.cancellation_request_status = 'requested' then
    return jsonb_build_object('trip_id', p_trip_id, 'status', 'requested', 'already_requested', true);
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'A reason is required'; end if;

  update public.bus_trips
  set cancellation_request_status = 'requested', cancellation_reason = p_reason,
      cancellation_requested_by = (select auth.uid()), cancellation_requested_at = now(),
      cancellation_decided_by = null, cancellation_decided_at = null, cancellation_decision_note = null
  where id = p_trip_id;

  perform private.write_audit('trip.cancellation_requested', 'trip', p_trip_id, null,
    jsonb_build_object('operator_id', v_trip.operator_id, 'reason', p_reason));
  return jsonb_build_object('trip_id', p_trip_id, 'status', 'requested');
end;
$$;

create or replace function public.admin_decide_trip_cancellation(p_trip_id uuid, p_approve boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
  v_booking uuid;
  v_cancelled integer := 0;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can decide cancellations'; end if;
  select * into v_trip from public.bus_trips where id = p_trip_id for update;
  if v_trip.id is null or v_trip.cancellation_request_status <> 'requested' then
    raise exception 'No pending cancellation request for this departure';
  end if;

  if not p_approve then
    update public.bus_trips
    set cancellation_request_status = 'rejected', cancellation_decided_by = (select auth.uid()),
        cancellation_decided_at = now(), cancellation_decision_note = p_note
    where id = p_trip_id;
    perform private.write_audit('trip.cancellation_rejected', 'trip', p_trip_id, null, jsonb_build_object('note', p_note));
    return jsonb_build_object('trip_id', p_trip_id, 'status', 'rejected');
  end if;

  update public.bus_trips
  set status = 'cancelled', cancellation_request_status = 'approved', cancellation_decided_by = (select auth.uid()),
      cancellation_decided_at = now(), cancellation_decision_note = p_note
  where id = p_trip_id;

  for v_booking in
    select distinct bi.booking_id from public.booking_items bi
    where bi.trip_id = p_trip_id and bi.status in ('confirmed', 'payment_pending')
  loop
    perform public.cancel_booking(v_booking, 'Departure cancelled: ' || coalesce(v_trip.cancellation_reason, 'operator request'));
    v_cancelled := v_cancelled + 1;
  end loop;

  update public.seat_holds set status = 'released' where trip_id = p_trip_id and status = 'active';
  update public.trip_seats set status = 'cancelled', hold_id = null where trip_id = p_trip_id and status in ('available', 'held');

  perform private.write_audit('trip.cancellation_approved', 'trip', p_trip_id, null,
    jsonb_build_object('bookings_cancelled', v_cancelled, 'note', p_note));
  return jsonb_build_object('trip_id', p_trip_id, 'status', 'cancelled', 'bookings_cancelled', v_cancelled);
end;
$$;

-- Dynamic, read-only values for the schedule setup screen (the displayed
-- window is never hardcoded in the app).
create or replace function public.preview_bus_schedule(p_bus_id uuid, p_operating_days smallint[], p_departure_time time)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_route uuid;
  w record;
  s public.scheduling_settings;
  v_today date := private.platform_today();
  v_next date;
  v_count integer;
begin
  perform private.assert_bus_schedule_access(p_bus_id, false);
  select route_id into v_route from public.bus_services where id = private.bus_primary_service(p_bus_id);
  if v_route is null then raise exception 'Configure the route before the schedule'; end if;
  select * into s from public.scheduling_settings where id;
  select * into w from private.effective_booking_window(v_route);

  select min(g.d::date), count(*) into v_next, v_count
  from generate_series(v_today, v_today + w.advance_days, interval '1 day') g(d)
  where extract(isodow from g.d)::smallint = any (p_operating_days)
    and ((g.d::date + p_departure_time) at time zone s.timezone) > now();

  return jsonb_build_object(
    'advance_days', w.advance_days, 'source', w.source, 'timezone', s.timezone,
    'horizon_date', v_today + w.advance_days,
    'next_departure_date', v_next, 'departures_in_window', coalesce(v_count, 0),
    'booking_close_minutes_max', s.max_booking_close_minutes,
    'boarding_cutoff_minutes_max', s.max_boarding_cutoff_minutes,
    'operator_can_set_booking_rules', s.allow_operator_booking_rules
  );
end;
$$;

create or replace function public.get_bus_schedule_overview(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := private.platform_today();
begin
  perform private.assert_bus_schedule_access(p_bus_id, false);
  return jsonb_build_object(
    'bus_id', p_bus_id,
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
        'service_id', sv.id, 'direction', sv.direction, 'status', sv.status, 'paused', sv.schedule_paused,
        'advance_days', w.advance_days, 'source', w.source, 'horizon_date', v_today + w.advance_days,
        'generated_through', sv.generated_through, 'last_generated_at', sv.last_generated_at,
        'next_departure_at', (select min(t.departure_at) from public.bus_trips t
                              where t.service_id = sv.id and t.status = 'scheduled' and t.departure_at > now()),
        'upcoming_departures', (select count(*) from public.bus_trips t
                                where t.service_id = sv.id and t.status = 'scheduled' and t.departure_at > now()
                                  and t.travel_date <= v_today + w.advance_days),
        'suspensions', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'start_date', e.start_date,
                                   'end_date', e.end_date, 'reason', e.reason) order by e.start_date)
                                 from public.schedule_exceptions e
                                 where e.service_id = sv.id and e.end_date >= v_today), '[]'::jsonb),
        'recent_errors', coalesce((select jsonb_agg(jsonb_build_object('code', x.error_code, 'message', x.message, 'at', x.created_at)
                                   order by x.created_at desc)
                                   from (select * from public.schedule_generation_errors er
                                         where er.service_id = sv.id order by er.created_at desc limit 3) x), '[]'::jsonb)
      ) order by sv.direction desc)
      from public.bus_services sv
      cross join lateral private.effective_booking_window(sv.route_id) w
      where sv.bus_id = p_bus_id and sv.status <> 'retired'
    ), '[]'::jsonb)
  );
end;
$$;

-- -------------------------------------------------------------------------
-- 9. Admin RPCs
-- -------------------------------------------------------------------------

create or replace function public.admin_route_booking_windows()
returns table (
  route_id uuid, operator_id uuid, operator_name text, bus_label text, source_city text, destination_city text,
  override_enabled boolean, override_days integer, effective_days integer, effective_source text,
  horizon_date date, updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then
    raise exception 'Only platform admins can view booking window configuration';
  end if;
  return query
  select r.id, r.operator_id, o.name, coalesce(b.name, b.registration_number), sc.name, dc.name,
         rw.override_enabled, rw.advance_days, w.advance_days, w.source,
         private.platform_today() + w.advance_days, rw.updated_at
  from public.bus_routes r
  join public.operators o on o.id = r.operator_id
  join public.locations sc on sc.id = r.source_city_id
  join public.locations dc on dc.id = r.destination_city_id
  left join public.buses b on b.id = r.bus_id
  left join public.route_booking_windows rw on rw.route_id = r.id
  cross join lateral private.effective_booking_window(r.id) w
  where r.active
  order by sc.name, dc.name, o.name;
end;
$$;

create or replace function public.admin_run_schedule_generation()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can run schedule generation'; end if;
  return private.run_rolling_schedule_generation('admin');
end;
$$;

-- -------------------------------------------------------------------------
-- 10. RLS & grants (operators already have SELECT-only on bus_services /
--     bus_trips / fare_rules; all their writes go through the RPCs above)
-- -------------------------------------------------------------------------

alter table public.scheduling_settings enable row level security;
alter table public.route_booking_windows enable row level security;
alter table public.operator_booking_window_overrides enable row level security;
alter table public.schedule_exceptions enable row level security;
alter table public.schedule_generation_runs enable row level security;
alter table public.schedule_generation_errors enable row level security;

create policy scheduling_settings_read on public.scheduling_settings for select to authenticated using (true);
create policy scheduling_settings_admin_all on public.scheduling_settings for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy route_booking_windows_read on public.route_booking_windows for select to authenticated
  using (private.is_platform_admin() or exists (
    select 1 from public.bus_routes r where r.id = route_booking_windows.route_id and private.is_operator_staff(r.operator_id)));
create policy route_booking_windows_admin_all on public.route_booking_windows for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy operator_booking_window_overrides_read on public.operator_booking_window_overrides for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy operator_booking_window_overrides_admin_all on public.operator_booking_window_overrides for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy schedule_exceptions_read on public.schedule_exceptions for select to authenticated
  using (private.is_platform_admin() or exists (
    select 1 from public.bus_services s where s.id = schedule_exceptions.service_id and private.is_operator_staff(s.operator_id)));
create policy schedule_exceptions_admin_all on public.schedule_exceptions for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy schedule_generation_runs_admin_select on public.schedule_generation_runs for select to authenticated
  using (private.is_platform_admin());
create policy schedule_generation_errors_read on public.schedule_generation_errors for select to authenticated
  using (private.is_platform_admin() or exists (
    select 1 from public.bus_services s where s.id = schedule_generation_errors.service_id and private.is_operator_staff(s.operator_id)));

-- New private functions are internal only (called from SECURITY DEFINER code, triggers, cron).
revoke execute on function
  private.effective_booking_window(uuid), private.platform_today(), private.booking_horizon_date(uuid),
  private.log_generation_error(uuid, uuid, text, text), private.reconcile_service_trips(uuid),
  private.generate_service_trips(uuid, uuid, boolean), private.run_rolling_schedule_generation(text),
  private.generate_service_trips_safe(uuid), private.generate_for_route(uuid),
  private.assert_bus_schedule_access(uuid, boolean)
from public, anon, authenticated;

revoke execute on function
  public.set_bus_schedule_paused(uuid, boolean),
  public.suspend_bus_dates(uuid, date, date, text),
  public.remove_bus_suspension(uuid),
  public.request_trip_cancellation(uuid, text),
  public.admin_decide_trip_cancellation(uuid, boolean, text),
  public.preview_bus_schedule(uuid, smallint[], time),
  public.get_bus_schedule_overview(uuid),
  public.admin_route_booking_windows(),
  public.admin_run_schedule_generation()
from public, anon;
grant execute on function
  public.set_bus_schedule_paused(uuid, boolean),
  public.suspend_bus_dates(uuid, date, date, text),
  public.remove_bus_suspension(uuid),
  public.request_trip_cancellation(uuid, text),
  public.admin_decide_trip_cancellation(uuid, boolean, text),
  public.preview_bus_schedule(uuid, smallint[], time),
  public.get_bus_schedule_overview(uuid),
  public.admin_route_booking_windows(),
  public.admin_run_schedule_generation()
to authenticated;

grant execute on function public.get_effective_booking_window(uuid) to anon, authenticated;
grant execute on function public.get_max_booking_date(uuid, uuid) to anon, authenticated;

-- -------------------------------------------------------------------------
-- 11. Scheduled jobs: hourly (idempotent, self-healing) + just after
--     midnight Asia/Kolkata (18:35 UTC) so the new day's horizon appears at once.
-- -------------------------------------------------------------------------

select cron.schedule('rolling-schedule-generation-hourly', '10 * * * *', $$select private.run_rolling_schedule_generation('cron');$$);
select cron.schedule('rolling-schedule-generation-midnight-ist', '35 18 * * *', $$select private.run_rolling_schedule_generation('cron-midnight-ist');$$);
