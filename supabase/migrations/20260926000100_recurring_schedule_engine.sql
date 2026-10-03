-- =========================================================================
-- Centralized recurring schedule + rolling booking window engine.
--
-- Architecture (reuses the existing tables — no parallel scheduling system):
--   A. Recurring schedule template  = public.bus_services (+ operating_days,
--      pause/automation flags, booking-close / boarding-cut-off overrides)
--   B. Departure instance           = public.bus_trips   (unique per
--      service + travel_date; each owns its public.trip_seats inventory)
--   C. Booking window configuration = scheduling_settings (global default and
--      bounds), route_booking_windows (per-route admin override) and
--      operator_booking_window_overrides (admin-approved, optional).
--
-- The backend (pg_cron -> private.run_rolling_schedule_generation) is the only
-- thing that creates future departures for recurring services. Customers see
-- only what the backend says is inside the effective booking horizon.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Configuration tables (admin-controlled)
-- -------------------------------------------------------------------------

create table public.scheduling_settings (
  id boolean primary key default true check (id),   -- singleton row
  timezone text not null default 'Asia/Kolkata',
  default_advance_days integer not null default 30,
  min_advance_days integer not null default 1,
  max_advance_days integer not null default 180,
  allow_operator_overrides boolean not null default false,
  -- Booking closing / boarding cut-off rules (minutes before departure).
  default_booking_close_minutes integer not null default 0,
  max_booking_close_minutes integer not null default 240,
  default_boarding_cutoff_minutes integer not null default 15,
  max_boarding_cutoff_minutes integer not null default 120,
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
-- 2. Template + instance columns
-- -------------------------------------------------------------------------

alter table public.bus_services
  add column operating_days smallint[] not null default '{1,2,3,4,5,6,7}',   -- ISO: 1 = Monday .. 7 = Sunday
  add column auto_generate boolean not null default true,
  add column booking_close_minutes integer check (booking_close_minutes >= 0),
  add column boarding_cutoff_minutes integer check (boarding_cutoff_minutes >= 0),
  add column last_generated_at timestamptz,
  add column generated_through date,
  add constraint bus_services_operating_days_chk
    check (cardinality(operating_days) >= 1 and operating_days <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]);

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

create index bus_trips_travel_date_idx on public.bus_trips (travel_date);
create index bus_trips_cancellation_requested_idx on public.bus_trips (cancellation_requested_at)
  where cancellation_request_status = 'requested';

-- Temporary service suspension (date range, inclusive). A single day is a
-- range with start = end. Date-specific cancellation of an already-published
-- departure is NOT done here; it goes through request_trip_cancellation().
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

-- Generation tracking
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
-- 3. Backfill — BEFORE any engine trigger exists, so nothing regenerates.
-- -------------------------------------------------------------------------

-- Infer operating days of existing services from their already-published
-- future departures (keeps today's behaviour); services without any keep all 7.
update public.bus_services s
set operating_days = d.days
from (
  select t.service_id, array_agg(distinct extract(isodow from t.travel_date)::smallint order by extract(isodow from t.travel_date)::smallint) as days
  from public.bus_trips t
  where t.travel_date >= current_date and t.status <> 'cancelled'
  group by t.service_id
) d
where d.service_id = s.id;

-- Existing future, non-cancelled departures are adopted by the engine. They are
-- never deleted by it once a booking or live hold exists (see reconcile below).
update public.bus_trips
set generated_by = 'migrated'
where travel_date >= current_date and status = 'scheduled';

-- -------------------------------------------------------------------------
-- 4. Audit (reuses public.audit_logs)
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
  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, before, after)
  values (
    (select auth.uid()),
    lower(tg_op),
    tg_argv[0],
    case when v_id ~* '^[0-9a-f-]{36}$' then v_id::uuid end,
    v_old,
    v_new
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

-- Only schedule-defining changes to a service are audited (not bookkeeping
-- columns such as last_generated_at, which the engine rewrites daily).
create or replace function private.audit_service_schedule_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (new.status, new.operating_days, new.default_departure_time, new.default_arrival_offset_minutes,
      new.bus_id, new.auto_generate, new.booking_close_minutes, new.boarding_cutoff_minutes)
     is distinct from
     (old.status, old.operating_days, old.default_departure_time, old.default_arrival_offset_minutes,
      old.bus_id, old.auto_generate, old.booking_close_minutes, old.boarding_cutoff_minutes) then
    insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, before, after)
    values ((select auth.uid()), 'update', 'recurring_schedule', new.id, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

create trigger audit_schedule_change after update on public.bus_services
  for each row execute function private.audit_service_schedule_change();

-- -------------------------------------------------------------------------
-- 5. Booking window resolution (single source of truth)
--    Precedence: route override -> admin-approved operator override -> global.
--    The result is always clamped to the admin min/max.
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

-- "Today" in the platform timezone (Asia/Kolkata by default).
create or replace function private.platform_today()
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (now() at time zone (select timezone from public.scheduling_settings where id))::date;
$$;

-- Last travel date (inclusive) a customer may book on this route. Computed
-- from today + the effective window — never stored, so it rolls forward by
-- itself and follows admin changes immediately.
create or replace function private.booking_horizon_date(p_route_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select private.platform_today() + (select w.advance_days from private.effective_booking_window(p_route_id) w);
$$;

-- Public, read-only: shown in the operator app (read-only) and used by the
-- customer app to bound its date picker. Reveals nothing but the number.
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

-- Latest bookable travel date for a source/destination pair (max over the
-- services serving it); falls back to the global default horizon.
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
     where sv.status in ('active', 'paused')
       and sv.service_source_city_id = p_source_city_id
       and sv.service_dest_city_id = p_destination_city_id),
    private.platform_today() + (select default_advance_days from public.scheduling_settings where id)
  );
$$;

-- A departure is bookable only if the backend says so. Used by the seat-hold
-- guard below (the choke point every booking passes through).
create or replace function private.is_trip_bookable(t public.bus_trips)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select t.status = 'scheduled'
    and t.cancellation_request_status <> 'requested'
    and now() >= t.booking_open_at
    and (t.booking_close_at is null or now() < t.booking_close_at)
    and t.departure_at > now()
    and t.travel_date <= private.booking_horizon_date(t.route_id);
$$;

create or replace function private.guard_seat_hold_trip()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trip public.bus_trips;
begin
  select * into v_trip from public.bus_trips where id = new.trip_id;
  if v_trip.id is null or not private.is_trip_bookable(v_trip) then
    raise exception 'trip_not_bookable: this departure is not open for booking';
  end if;
  return new;
end;
$$;

create trigger guard_trip_bookable before insert on public.seat_holds
  for each row execute function private.guard_seat_hold_trip();

-- Operators must go through the admin-controlled cancellation workflow.
create or replace function private.guard_trip_cancellation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'cancelled' and old.status <> 'cancelled'
     and coalesce(current_setting('thirty8.system_action', true), '') <> '1'
     and (select auth.uid()) is not null
     and not private.is_platform_admin() then
    raise exception 'Departures are cancelled through the cancellation request workflow (request_trip_cancellation)';
  end if;
  return new;
end;
$$;

create trigger guard_trip_cancellation before update of status on public.bus_trips
  for each row execute function private.guard_trip_cancellation();

-- -------------------------------------------------------------------------
-- 6. Generation engine
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

-- Removes (only) engine-owned future departures that no longer match the
-- service configuration — changed times/bus, a removed operating day, or a
-- suspension — and only when nothing depends on them: no booking items and no
-- active seat hold. Anything with a booking is left exactly as sold.
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

-- Idempotent, concurrency-safe generation for ONE service. Creates only the
-- missing departures inside [today, today + effective advance days] on
-- operating days, never touching existing rows.
create or replace function private.generate_service_trips(p_service_id uuid, p_run_id uuid default null, p_log_missing_setup boolean default true)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
  s public.scheduling_settings;
  v_operator_ok boolean;
  v_today date;
  v_horizon date;
  v_days integer;
  v_close integer;
  v_cutoff integer;
  v_seats integer;
  v_created integer := 0;
  v_no_fare integer := 0;
begin
  -- One generator per service at a time (cron vs. operator edit vs. admin change).
  perform pg_advisory_xact_lock(hashtextextended('thirty8.service_generation:' || p_service_id::text, 0));

  select * into v_svc from public.bus_services where id = p_service_id;
  if v_svc.id is null or v_svc.status <> 'active' or not v_svc.auto_generate then
    return 0;
  end if;

  select exists (
    select 1 from public.operators o
    join public.bus_routes r on r.operator_id = o.id
    where o.id = v_svc.operator_id and o.status = 'approved' and r.id = v_svc.route_id and r.active
  ) into v_operator_ok;
  if not v_operator_ok then
    return 0;   -- unapproved operator / inactive route: nothing is published
  end if;

  select * into s from public.scheduling_settings where id;
  v_today := private.platform_today();
  select w.advance_days into v_days from private.effective_booking_window(v_svc.route_id) w;
  v_horizon := v_today + v_days;

  perform private.reconcile_service_trips(p_service_id);

  select count(*) into v_seats
  from public.seats se
  join public.bus_layouts bl on bl.id = se.bus_layout_id
  where bl.bus_id = v_svc.bus_id and bl.is_active;
  if v_seats = 0 then
    if p_log_missing_setup then
      perform private.log_generation_error(p_run_id, p_service_id, 'no_seat_layout',
        'Bus has no active seat layout; no departures were generated');
    end if;
    return 0;
  end if;

  v_close := case when s.allow_operator_booking_rules
                  then least(coalesce(v_svc.booking_close_minutes, s.default_booking_close_minutes), s.max_booking_close_minutes)
                  else s.default_booking_close_minutes end;
  v_cutoff := case when s.allow_operator_booking_rules
                   then least(coalesce(v_svc.boarding_cutoff_minutes, s.default_boarding_cutoff_minutes), s.max_boarding_cutoff_minutes)
                   else s.default_boarding_cutoff_minutes end;

  -- Dates that are otherwise eligible but have no fare configured are skipped
  -- (never publish a free departure by accident).
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
    min_fare_cents, max_fare_cents, live_tracking_enabled,
    booking_open_at, booking_close_at, boarding_cutoff_at, generated_by
  )
  select
    v_svc.id, v_svc.operator_id, v_svc.route_id, v_svc.bus_id, g.d::date,
    dep.ts,
    dep.ts + make_interval(mins => v_svc.default_arrival_offset_minutes),
    fare.mn, fare.mx, true,
    now(),
    dep.ts - make_interval(mins => v_close),
    dep.ts - make_interval(mins => v_cutoff),
    'scheduler'
  from generate_series(v_today, v_horizon, interval '1 day') g(d)
  cross join lateral (select ((g.d::date + v_svc.default_departure_time) at time zone s.timezone) as ts) dep
  cross join lateral (
    select min(f.base_fare_cents) as mn, max(f.base_fare_cents) as mx
    from (
      select distinct on (fr.seat_type) fr.base_fare_cents
      from public.fare_rules fr
      where fr.service_id = v_svc.id
        and fr.effective_from <= g.d::date
        and (fr.effective_to is null or fr.effective_to >= g.d::date)
      order by fr.seat_type, fr.effective_from desc
    ) f
  ) fare
  where extract(isodow from g.d)::smallint = any (v_svc.operating_days)
    and dep.ts > now()
    and fare.mn is not null
    and not exists (select 1 from public.schedule_exceptions e where e.service_id = v_svc.id and g.d::date between e.start_date and e.end_date)
  on conflict (service_id, travel_date) do nothing;
  get diagnostics v_created = row_count;
  -- trip_seats are created per new trip by the generate_trip_seats trigger.

  -- Keep close / cut-off in step with the rules for departures not yet sold out of scope.
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

  update public.bus_services
  set last_generated_at = now(), generated_through = v_horizon
  where id = p_service_id;

  return v_created;
end;
$$;

-- Runs every active recurring service. Each service is isolated in its own
-- sub-transaction: one failing service never blocks or rolls back the others.
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
    select id from public.bus_services where status = 'active' and auto_generate order by id
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
  set services_processed = v_services,
      trips_created = v_total,
      error_count = v_errors,
      status = case when v_errors > 0 then 'completed_with_errors' else 'completed' end,
      finished_at = now()
  where id = v_run;

  -- Keep the run history bounded.
  delete from public.schedule_generation_runs where started_at < now() - interval '90 days';
  return v_run;
end;
$$;

-- Generate for every service on one route (route window changed).
create or replace function private.generate_for_route(p_route_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in select id from public.bus_services where route_id = p_route_id and status = 'active' and auto_generate loop
    begin
      perform private.generate_service_trips(r.id, null, false);
    exception when others then
      perform private.log_generation_error(null, r.id, 'exception', sqlstate || ': ' || sqlerrm);
    end;
  end loop;
end;
$$;

-- -------------------------------------------------------------------------
-- 7. Triggers that make changes take effect immediately (cron is the
--    safety net, not the only path)
-- -------------------------------------------------------------------------

create or replace function private.on_service_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status <> 'active' or not new.auto_generate then
    return null;
  end if;
  if tg_op = 'INSERT'
     or (old.status, old.auto_generate, old.operating_days, old.default_departure_time,
         old.default_arrival_offset_minutes, old.bus_id, old.booking_close_minutes, old.boarding_cutoff_minutes)
        is distinct from
        (new.status, new.auto_generate, new.operating_days, new.default_departure_time,
         new.default_arrival_offset_minutes, new.bus_id, new.booking_close_minutes, new.boarding_cutoff_minutes) then
    perform private.generate_service_trips(new.id, null, false);
  end if;
  return null;
end;
$$;

create trigger generate_on_service_change after insert or update on public.bus_services
  for each row execute function private.on_service_changed();

create or replace function private.on_fare_rule_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.generate_service_trips(coalesce(new.service_id, old.service_id), null, false);
  return null;
end;
$$;

create trigger generate_on_fare_rule_change after insert or update on public.fare_rules
  for each row execute function private.on_fare_rule_changed();

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

-- A suspension removed (or a new one added) is applied by the RPCs below.

-- -------------------------------------------------------------------------
-- 8. Seat inventory safety when a bus layout gains seats later
--    Adds the new seat to FUTURE, unsold-out departures only; never rewrites
--    existing rows (booked/held seats are untouched). Seats cannot be deleted
--    from a layout once trip_seats reference them (FK), so removal is safe.
-- -------------------------------------------------------------------------

create or replace function private.sync_new_seat_to_future_trips()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus_id uuid;
begin
  select bl.bus_id into v_bus_id from public.bus_layouts bl where bl.id = new.bus_layout_id and bl.is_active;
  if v_bus_id is null then
    return null;
  end if;

  insert into public.trip_seats (trip_id, seat_id, status, fare_cents)
  select t.id, new.id, 'available',
    coalesce(
      (select fr.base_fare_cents from public.fare_rules fr
       where fr.service_id = t.service_id and fr.seat_type = new.seat_type
         and fr.effective_from <= t.travel_date and (fr.effective_to is null or fr.effective_to >= t.travel_date)
       order by fr.effective_from desc limit 1),
      t.min_fare_cents, 0)
  from public.bus_trips t
  where t.bus_id = v_bus_id and t.status = 'scheduled' and t.departure_at > now()
  on conflict (trip_id, seat_id) do nothing;

  update public.bus_trips t
  set available_seats = (select count(*) from public.trip_seats ts where ts.trip_id = t.id and ts.status = 'available')
  where t.bus_id = v_bus_id and t.status = 'scheduled' and t.departure_at > now();
  return null;
end;
$$;

create trigger sync_new_seat after insert on public.seats
  for each row execute function private.sync_new_seat_to_future_trips();

-- -------------------------------------------------------------------------
-- 9. Operator / admin RPCs
-- -------------------------------------------------------------------------

create or replace function private.assert_service_access(p_service_id uuid)
returns public.bus_services
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
begin
  select * into v_svc from public.bus_services where id = p_service_id;
  if v_svc.id is null then
    raise exception 'Schedule not found';
  end if;
  if not (private.is_operator_staff(v_svc.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized for this schedule';
  end if;
  return v_svc;
end;
$$;

-- Pause / resume the recurring schedule. Pausing only stops *future*
-- generation: existing departures and bookings are untouched.
create or replace function public.set_service_schedule_status(p_service_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
begin
  v_svc := private.assert_service_access(p_service_id);
  if p_status not in ('active', 'paused') then
    raise exception 'Status must be active or paused';
  end if;
  if v_svc.status = 'retired' then
    raise exception 'A retired schedule cannot be changed';
  end if;
  update public.bus_services set status = p_status::public.bus_service_status where id = p_service_id;
  -- The bus_services trigger generates the missing departures on resume.
  return jsonb_build_object('service_id', p_service_id, 'status', p_status);
end;
$$;

-- Temporary suspension for a date range. Unsold departures inside the range are
-- withdrawn; departures that already have bookings are flagged for the
-- admin-controlled cancellation/refund workflow (never auto-cancelled here).
create or replace function public.suspend_service_dates(p_service_id uuid, p_start date, p_end date, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
  v_id uuid;
  v_removed integer := 0;
  v_flagged integer := 0;
begin
  v_svc := private.assert_service_access(p_service_id);
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'Invalid date range';
  end if;
  if p_start < private.platform_today() then
    raise exception 'Suspension cannot start in the past';
  end if;

  insert into public.schedule_exceptions (service_id, start_date, end_date, reason, created_by)
  values (p_service_id, p_start, p_end, p_reason, (select auth.uid()))
  returning id into v_id;

  v_removed := private.reconcile_service_trips(p_service_id);

  update public.bus_trips t
  set cancellation_request_status = 'requested',
      cancellation_reason = coalesce(nullif(p_reason, ''), 'Temporary service suspension'),
      cancellation_requested_by = (select auth.uid()),
      cancellation_requested_at = now()
  where t.service_id = p_service_id
    and t.travel_date between p_start and p_end
    and t.status = 'scheduled'
    and t.cancellation_request_status <> 'requested'
    and exists (select 1 from public.booking_items bi where bi.trip_id = t.id and bi.status in ('confirmed', 'payment_pending'));
  get diagnostics v_flagged = row_count;

  return jsonb_build_object('exception_id', v_id, 'removed_departures', v_removed, 'cancellation_requests', v_flagged);
end;
$$;

create or replace function public.remove_service_suspension(p_exception_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_service_id uuid;
  v_created integer;
begin
  select service_id into v_service_id from public.schedule_exceptions where id = p_exception_id;
  if v_service_id is null then
    raise exception 'Suspension not found';
  end if;
  perform private.assert_service_access(v_service_id);
  delete from public.schedule_exceptions where id = p_exception_id;
  v_created := private.generate_service_trips(v_service_id, null, false);
  return jsonb_build_object('service_id', v_service_id, 'generated', v_created);
end;
$$;

-- Operator asks to cancel ONE departure; the admin decides (and the existing
-- cancel_booking refund path runs on approval).
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
  if v_trip.id is null then
    raise exception 'Departure not found';
  end if;
  if not (private.is_operator_staff(v_trip.operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized for this departure';
  end if;
  if v_trip.status <> 'scheduled' then
    raise exception 'Only scheduled departures can be cancelled (status is %)', v_trip.status;
  end if;
  if v_trip.cancellation_request_status = 'requested' then
    return jsonb_build_object('trip_id', p_trip_id, 'status', 'requested', 'already_requested', true);
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required';
  end if;

  update public.bus_trips
  set cancellation_request_status = 'requested',
      cancellation_reason = p_reason,
      cancellation_requested_by = (select auth.uid()),
      cancellation_requested_at = now(),
      cancellation_decided_by = null,
      cancellation_decided_at = null,
      cancellation_decision_note = null
  where id = p_trip_id;
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
  if not private.is_platform_admin() then
    raise exception 'Only platform admins can decide cancellations';
  end if;
  select * into v_trip from public.bus_trips where id = p_trip_id for update;
  if v_trip.id is null or v_trip.cancellation_request_status <> 'requested' then
    raise exception 'No pending cancellation request for this departure';
  end if;

  if not p_approve then
    update public.bus_trips
    set cancellation_request_status = 'rejected', cancellation_decided_by = (select auth.uid()),
        cancellation_decided_at = now(), cancellation_decision_note = p_note
    where id = p_trip_id;
    return jsonb_build_object('trip_id', p_trip_id, 'status', 'rejected');
  end if;

  perform set_config('thirty8.system_action', '1', true);
  update public.bus_trips
  set status = 'cancelled', cancellation_request_status = 'approved', cancellation_decided_by = (select auth.uid()),
      cancellation_decided_at = now(), cancellation_decision_note = p_note, available_seats = 0
  where id = p_trip_id;

  -- Existing cancellation + refund workflow, per affected booking.
  for v_booking in
    select distinct bi.booking_id from public.booking_items bi
    where bi.trip_id = p_trip_id and bi.status in ('confirmed', 'payment_pending')
  loop
    perform public.cancel_booking(v_booking, 'Departure cancelled: ' || coalesce(v_trip.cancellation_reason, 'operator request'));
    v_cancelled := v_cancelled + 1;
  end loop;

  update public.seat_holds set status = 'released' where trip_id = p_trip_id and status = 'active';
  update public.trip_seats set status = 'cancelled', hold_id = null where trip_id = p_trip_id and status in ('available', 'held');

  insert into public.audit_logs (actor_profile_id, action, entity_type, entity_id, after)
  values ((select auth.uid()), 'approve_cancellation', 'bus_trip', p_trip_id,
          jsonb_build_object('bookings_cancelled', v_cancelled, 'note', p_note));
  return jsonb_build_object('trip_id', p_trip_id, 'status', 'cancelled', 'bookings_cancelled', v_cancelled);
end;
$$;

-- What the operator form shows while editing days/times (dynamic, read-only).
create or replace function public.preview_service_schedule(p_route_id uuid, p_operating_days smallint[], p_departure_time time)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  w record;
  s public.scheduling_settings;
  v_today date := private.platform_today();
  v_next date;
  v_count integer;
begin
  select * into s from public.scheduling_settings where id;
  select * into w from private.effective_booking_window(p_route_id);

  select min(g.d::date), count(*) into v_next, v_count
  from generate_series(v_today, v_today + w.advance_days, interval '1 day') g(d)
  where extract(isodow from g.d)::smallint = any (p_operating_days)
    and ((g.d::date + p_departure_time) at time zone s.timezone) > now();

  return jsonb_build_object(
    'advance_days', w.advance_days,
    'source', w.source,
    'timezone', s.timezone,
    'horizon_date', v_today + w.advance_days,
    'next_departure_date', v_next,
    'departures_in_window', coalesce(v_count, 0),
    'booking_close_minutes_default', s.default_booking_close_minutes,
    'booking_close_minutes_max', s.max_booking_close_minutes,
    'boarding_cutoff_minutes_default', s.default_boarding_cutoff_minutes,
    'boarding_cutoff_minutes_max', s.max_boarding_cutoff_minutes,
    'operator_can_set_booking_rules', s.allow_operator_booking_rules
  );
end;
$$;

create or replace function public.get_service_schedule_overview(p_service_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
  w record;
begin
  v_svc := private.assert_service_access(p_service_id);
  select * into w from private.effective_booking_window(v_svc.route_id);
  return jsonb_build_object(
    'service_id', v_svc.id,
    'status', v_svc.status,
    'advance_days', w.advance_days,
    'source', w.source,
    'horizon_date', private.platform_today() + w.advance_days,
    'generated_through', v_svc.generated_through,
    'last_generated_at', v_svc.last_generated_at,
    'next_departure_at', (
      select min(t.departure_at) from public.bus_trips t
      where t.service_id = p_service_id and t.status = 'scheduled' and t.departure_at > now()
    ),
    'upcoming_departures', (
      select count(*) from public.bus_trips t
      where t.service_id = p_service_id and t.status = 'scheduled' and t.departure_at > now()
        and t.travel_date <= private.platform_today() + w.advance_days
    ),
    'suspensions', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'start_date', e.start_date, 'end_date', e.end_date, 'reason', e.reason)
                       order by e.start_date)
      from public.schedule_exceptions e
      where e.service_id = p_service_id and e.end_date >= private.platform_today()
    ), '[]'::jsonb),
    'recent_errors', coalesce((
      select jsonb_agg(jsonb_build_object('code', x.error_code, 'message', x.message, 'at', x.created_at) order by x.created_at desc)
      from (select * from public.schedule_generation_errors where service_id = p_service_id order by created_at desc limit 3) x
    ), '[]'::jsonb)
  );
end;
$$;

-- Admin overview: every route with its resolved window and where it came from.
create or replace function public.admin_route_booking_windows()
returns table (
  route_id uuid, operator_id uuid, operator_name text, source_city text, destination_city text,
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
  select r.id, r.operator_id, o.name, sc.name, dc.name,
         rw.override_enabled, rw.advance_days, w.advance_days, w.source,
         private.platform_today() + w.advance_days, rw.updated_at
  from public.bus_routes r
  join public.operators o on o.id = r.operator_id
  join public.cities sc on sc.id = r.source_city_id
  join public.cities dc on dc.id = r.destination_city_id
  left join public.route_booking_windows rw on rw.route_id = r.id
  cross join lateral private.effective_booking_window(r.id) w
  order by sc.name, dc.name, o.name;
end;
$$;

-- Admin: run the generator on demand (same code path as cron).
create or replace function public.admin_run_schedule_generation()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then
    raise exception 'Only platform admins can run schedule generation';
  end if;
  return private.run_rolling_schedule_generation('admin');
end;
$$;

-- -------------------------------------------------------------------------
-- 10. search_trips: backend decides what is visible/bookable.
--     (create or replace keeps the existing grants.)
-- -------------------------------------------------------------------------

create or replace function public.search_trips(
  p_source_city_id uuid,
  p_destination_city_id uuid,
  p_travel_date date
)
returns jsonb
language plpgsql
stable
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
    'booking_close_at', t.booking_close_at,
    'available_seats', t.available_seats,
    'min_fare_cents', t.min_fare_cents,
    'max_fare_cents', t.max_fare_cents,
    'currency_code', t.currency_code
  ) order by t.departure_at), '[]'::jsonb)
  into v_direct
  from public.bus_trips t
  join public.bus_services sv on sv.id = t.service_id
  join public.operators o on o.id = t.operator_id
  join public.buses bs on bs.id = t.bus_id
  where t.travel_date = p_travel_date
    and t.status = 'scheduled'
    and t.cancellation_request_status <> 'requested'
    and now() >= t.booking_open_at
    and (t.booking_close_at is null or now() < t.booking_close_at)
    and t.departure_at > now()
    and t.travel_date <= public.get_max_booking_date_for_route(t.route_id)
    and sv.service_source_city_id = p_source_city_id
    and sv.service_dest_city_id = p_destination_city_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'transfer_city_id', s1.service_dest_city_id,
    'leg1', jsonb_build_object(
      'trip_id', t1.id, 'service_id', s1.id, 'operator_id', o1.id, 'operator_name', o1.name,
      'departure_at', t1.departure_at, 'arrival_at', t1.arrival_at,
      'min_fare_cents', t1.min_fare_cents, 'available_seats', t1.available_seats
    ),
    'leg2', jsonb_build_object(
      'trip_id', t2.id, 'service_id', s2.id, 'operator_id', o2.id, 'operator_name', o2.name,
      'departure_at', t2.departure_at, 'arrival_at', t2.arrival_at,
      'min_fare_cents', t2.min_fare_cents, 'available_seats', t2.available_seats
    ),
    'total_min_fare_cents', coalesce(t1.min_fare_cents, 0) + coalesce(t2.min_fare_cents, 0)
  ) order by t1.departure_at), '[]'::jsonb)
  into v_connected
  from public.bus_services s1
  join public.bus_trips t1 on t1.service_id = s1.id
    and t1.travel_date = p_travel_date
    and t1.status = 'scheduled'
    and t1.cancellation_request_status <> 'requested'
    and now() >= t1.booking_open_at
    and (t1.booking_close_at is null or now() < t1.booking_close_at)
    and t1.departure_at > now()
    and t1.travel_date <= public.get_max_booking_date_for_route(t1.route_id)
  join public.operators o1 on o1.id = t1.operator_id
  join public.bus_services s2 on s2.service_source_city_id = s1.service_dest_city_id
    and s2.service_dest_city_id = p_destination_city_id
  join public.bus_trips t2 on t2.service_id = s2.id
    and t2.status = 'scheduled'
    and t2.cancellation_request_status <> 'requested'
    and now() >= t2.booking_open_at
    and (t2.booking_close_at is null or now() < t2.booking_close_at)
    and t2.departure_at > now()
    and t2.travel_date <= public.get_max_booking_date_for_route(t2.route_id)
    and t2.travel_date between p_travel_date and p_travel_date + 1
  join public.operators o2 on o2.id = t2.operator_id
  where s1.service_source_city_id = p_source_city_id
    and t2.departure_at >= t1.arrival_at + interval '15 minutes'
    and t2.departure_at <= t1.arrival_at + interval '6 hours';

  return jsonb_build_object('direct', v_direct, 'connected', v_connected);
end;
$$;

-- Thin public wrapper so the (non-definer) search function can use the private
-- horizon logic without granting anon access to the private schema.
create or replace function public.get_max_booking_date_for_route(p_route_id uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select private.booking_horizon_date(p_route_id);
$$;

-- -------------------------------------------------------------------------
-- 11. RLS & permissions
-- -------------------------------------------------------------------------

alter table public.scheduling_settings enable row level security;
alter table public.route_booking_windows enable row level security;
alter table public.operator_booking_window_overrides enable row level security;
alter table public.schedule_exceptions enable row level security;
alter table public.schedule_generation_runs enable row level security;
alter table public.schedule_generation_errors enable row level security;

-- Operators may READ the admin configuration; only admins write it.
create policy scheduling_settings_read on public.scheduling_settings for select to authenticated using (true);
create policy scheduling_settings_admin_all on public.scheduling_settings for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy route_booking_windows_read on public.route_booking_windows for select to authenticated using (true);
create policy route_booking_windows_admin_all on public.route_booking_windows for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

create policy operator_booking_window_overrides_read on public.operator_booking_window_overrides for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());
create policy operator_booking_window_overrides_admin_all on public.operator_booking_window_overrides for all to authenticated
  using (private.is_platform_admin()) with check (private.is_platform_admin());

-- Suspensions: operators read their own; writes only via RPC.
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

-- Operators can no longer DELETE services or departures (no destructive
-- schedule management); pause / suspend / request-cancellation replace it.
drop policy bus_services_operator_manage on public.bus_services;
create policy bus_services_operator_select on public.bus_services for select to authenticated using (private.is_operator_staff(operator_id));
create policy bus_services_operator_insert on public.bus_services for insert to authenticated with check (private.is_operator_staff(operator_id));
create policy bus_services_operator_update on public.bus_services for update to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));

drop policy bus_trips_operator_manage on public.bus_trips;
create policy bus_trips_operator_insert on public.bus_trips for insert to authenticated with check (private.is_operator_staff(operator_id));
create policy bus_trips_operator_update on public.bus_trips for update to authenticated
  using (private.is_operator_staff(operator_id)) with check (private.is_operator_staff(operator_id));

-- Function privileges: nothing is callable by anon/public except the
-- read-only horizon helpers and search.
-- (The private schema stays unreachable for anon; the new private functions are
-- only ever invoked from SECURITY DEFINER code, triggers and cron.)
revoke execute on all functions in schema private from public, anon;
grant execute on function private.is_platform_admin(), private.is_operator_staff(uuid), private.is_operator_admin(uuid) to authenticated;

revoke execute on function
  public.set_service_schedule_status(uuid, text),
  public.suspend_service_dates(uuid, date, date, text),
  public.remove_service_suspension(uuid),
  public.request_trip_cancellation(uuid, text),
  public.admin_decide_trip_cancellation(uuid, boolean, text),
  public.preview_service_schedule(uuid, smallint[], time),
  public.get_service_schedule_overview(uuid),
  public.admin_route_booking_windows(),
  public.admin_run_schedule_generation()
from public, anon;
grant execute on function
  public.set_service_schedule_status(uuid, text),
  public.suspend_service_dates(uuid, date, date, text),
  public.remove_service_suspension(uuid),
  public.request_trip_cancellation(uuid, text),
  public.admin_decide_trip_cancellation(uuid, boolean, text),
  public.preview_service_schedule(uuid, smallint[], time),
  public.get_service_schedule_overview(uuid),
  public.admin_route_booking_windows(),
  public.admin_run_schedule_generation()
to authenticated;

grant execute on function public.get_effective_booking_window(uuid) to anon, authenticated;
grant execute on function public.get_max_booking_date(uuid, uuid) to anon, authenticated;
grant execute on function public.get_max_booking_date_for_route(uuid) to anon, authenticated;

-- -------------------------------------------------------------------------
-- 12. Scheduled jobs. Hourly (self-healing, idempotent) plus a run just after
--     midnight Asia/Kolkata (18:35 UTC) so the new day's horizon is
--     published immediately.
-- -------------------------------------------------------------------------

select cron.schedule('rolling-schedule-generation-hourly', '10 * * * *', $$select private.run_rolling_schedule_generation('cron');$$);
select cron.schedule('rolling-schedule-generation-midnight-ist', '35 18 * * *', $$select private.run_rolling_schedule_generation('cron-midnight-ist');$$);
