-- =========================================================================
-- Operator services (Bus / Cargo / Shopping) selected per operator.
--
--   * operator_services: one row per operator + service, with a state machine
--     (not_selected, selected, setup_required, pending_approval, active,
--      suspended, disabled). Selecting a service never implies approval.
--   * state is derived from the operator's approval (private.operator_service_auto_state)
--     and kept in sync by a trigger on operators. Platform admins can approve a
--     service that is not covered by the operator's onboarding business_type, or
--     suspend one.
--   * disabling a service NEVER deletes data. It is only blocked from creating
--     new buses / trips; existing trips, bookings and financial history stay.
--   * Additive only. operators.business_type is left untouched (it still drives
--     onboarding document requirements).
-- =========================================================================

create type public.operator_service_type as enum ('bus', 'cargo', 'shopping');
create type public.operator_service_state as enum (
  'not_selected', 'selected', 'setup_required', 'pending_approval', 'active', 'suspended', 'disabled'
);

create table public.operator_services (
  operator_id uuid not null references public.operators (id) on delete cascade,
  service_type public.operator_service_type not null,
  state public.operator_service_state not null default 'not_selected',
  admin_approved boolean not null default false,
  suspension_source text check (suspension_source in ('operator_status', 'admin')),
  suspension_reason text,
  enabled_at timestamptz,
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (operator_id, service_type)
);

create trigger set_updated_at
  before update on public.operator_services
  for each row execute function private.set_updated_at();

alter table public.operator_services enable row level security;

create policy operator_services_select on public.operator_services
  for select to authenticated
  using (private.is_operator_staff(operator_id) or private.is_platform_admin());

revoke all on public.operator_services from anon, authenticated;
grant select on public.operator_services to authenticated;

-- ---------------------------------------------------------------------
-- State derivation
-- ---------------------------------------------------------------------
create or replace function private.operator_service_auto_state(
  p_operator_id uuid,
  p_service public.operator_service_type
) returns public.operator_service_state
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_op public.operators%rowtype;
  v_svc public.operator_services%rowtype;
  v_covered boolean;
begin
  select * into v_op from public.operators where id = p_operator_id;
  if not found then return 'not_selected'; end if;
  select * into v_svc from public.operator_services
    where operator_id = p_operator_id and service_type = p_service;

  if v_op.status = 'suspended' then return 'suspended'; end if;
  if v_op.status <> 'approved' or v_op.application_status <> 'approved' then
    if v_op.application_status in ('draft', 'changes_requested') then return 'setup_required'; end if;
    return 'pending_approval';
  end if;

  v_covered := (p_service = 'bus' and v_op.business_type in ('bus', 'both'))
            or (p_service = 'cargo' and v_op.business_type in ('cargo', 'both'));
  if v_covered or coalesce(v_svc.admin_approved, false) then return 'active'; end if;
  return 'pending_approval';
end;
$$;
revoke execute on function private.operator_service_auto_state(uuid, public.operator_service_type) from public, anon, authenticated;

create or replace function private.operator_service_active(
  p_operator_id uuid,
  p_service public.operator_service_type
) returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.operator_services s
    where s.operator_id = p_operator_id and s.service_type = p_service and s.state = 'active'
  );
$$;
revoke execute on function private.operator_service_active(uuid, public.operator_service_type) from public, anon;
grant execute on function private.operator_service_active(uuid, public.operator_service_type) to authenticated;

-- Keep rows in sync with operators (insert, approval changes, business_type changes).
create or replace function private.sync_operator_services()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.operator_service_type;
  v_covered boolean;
begin
  foreach v_svc in array array['bus', 'cargo']::public.operator_service_type[] loop
    v_covered := (v_svc = 'bus' and new.business_type in ('bus', 'both'))
              or (v_svc = 'cargo' and new.business_type in ('cargo', 'both'));

    if v_covered then
      insert into public.operator_services (operator_id, service_type, state, enabled_at)
      values (new.id, v_svc, private.operator_service_auto_state(new.id, v_svc), now())
      on conflict (operator_id, service_type) do nothing;
    end if;

    -- re-derive automatic states; leave operator-disabled and admin-suspended alone
    update public.operator_services s
       set state = private.operator_service_auto_state(new.id, v_svc),
           suspension_source = case when private.operator_service_auto_state(new.id, v_svc) = 'suspended'
                                    then 'operator_status' else null end
     where s.operator_id = new.id and s.service_type = v_svc
       and (
         s.state in ('selected', 'setup_required', 'pending_approval', 'active')
         or (s.state = 'suspended' and s.suspension_source = 'operator_status')
       );

    -- business_type narrowed during onboarding: drop never-approved selections
    if not v_covered then
      update public.operator_services s
         set state = 'not_selected', disabled_at = now()
       where s.operator_id = new.id and s.service_type = v_svc
         and s.admin_approved = false and s.state in ('setup_required', 'pending_approval');
    end if;
  end loop;
  return new;
end;
$$;
revoke execute on function private.sync_operator_services() from public, anon, authenticated;

create trigger sync_operator_services
  after insert or update of business_type, status, application_status on public.operators
  for each row execute function private.sync_operator_services();

-- Backfill existing operators (fires the same logic without touching the operators rows).
insert into public.operator_services (operator_id, service_type, state, enabled_at)
select o.id, s.svc, private.operator_service_auto_state(o.id, s.svc), now()
from public.operators o
cross join (values ('bus'::public.operator_service_type), ('cargo'::public.operator_service_type)) as s(svc)
where (s.svc = 'bus' and o.business_type in ('bus', 'both'))
   or (s.svc = 'cargo' and o.business_type in ('cargo', 'both'))
on conflict (operator_id, service_type) do nothing;

-- ---------------------------------------------------------------------
-- Disable impact (read-only)
-- ---------------------------------------------------------------------
create or replace function public.get_service_disable_impact(
  p_operator_id uuid,
  p_service public.operator_service_type
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active_trips int := 0;
  v_upcoming_trips int := 0;
  v_pending_bookings int := 0;
  v_confirmed_bookings int := 0;
  v_unsettled bigint := 0;
  v_active_shipments int := 0;
begin
  if not (private.is_operator_staff(p_operator_id) or private.is_platform_admin()) then
    raise exception 'Not authorized';
  end if;

  if p_service = 'bus' then
    select count(*) into v_active_trips
      from public.bus_trips t where t.operator_id = p_operator_id and t.status in ('boarding', 'departed');
    select count(*) into v_upcoming_trips
      from public.bus_trips t where t.operator_id = p_operator_id and t.status = 'scheduled' and t.departure_at > now();
    select count(*) into v_pending_bookings
      from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
      where t.operator_id = p_operator_id and bi.status = 'payment_pending';
    select count(*) into v_confirmed_bookings
      from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
      where t.operator_id = p_operator_id and bi.status = 'confirmed'
        and t.status in ('scheduled', 'boarding', 'departed');
    -- no settlement ledger exists yet, so confirmed/completed sales are all unsettled
    select coalesce(sum(bi.fare_cents), 0) into v_unsettled
      from public.booking_items bi join public.bus_trips t on t.id = bi.trip_id
      where t.operator_id = p_operator_id and bi.status in ('confirmed', 'completed') and t.status <> 'cancelled';
  elsif p_service = 'cargo' then
    select count(*) into v_active_shipments
      from public.cargo_shipments c
      where c.operator_id = p_operator_id
        and c.status in ('confirmed', 'picked_up', 'in_transit', 'arrived_at_hub', 'out_for_delivery');
  end if;

  return jsonb_build_object(
    'service', p_service,
    'active_trips', v_active_trips,
    'upcoming_trips', v_upcoming_trips,
    'pending_bookings', v_pending_bookings,
    'confirmed_bookings', v_confirmed_bookings,
    'active_shipments', v_active_shipments,
    'unsettled_cents', v_unsettled,
    'has_blockers', (v_active_trips + v_upcoming_trips + v_pending_bookings + v_confirmed_bookings + v_active_shipments) > 0
                    or v_unsettled > 0
  );
end;
$$;
revoke execute on function public.get_service_disable_impact(uuid, public.operator_service_type) from public, anon;
grant execute on function public.get_service_disable_impact(uuid, public.operator_service_type) to authenticated;

-- ---------------------------------------------------------------------
-- Operator enables / disables a service (owner admin only)
-- ---------------------------------------------------------------------
create or replace function public.set_operator_service(
  p_operator_id uuid,
  p_service public.operator_service_type,
  p_enable boolean,
  p_confirm boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before public.operator_services%rowtype;
  v_impact jsonb;
  v_state public.operator_service_state;
begin
  if not private.is_operator_admin(p_operator_id) then
    raise exception 'Only the operator admin can change services';
  end if;
  if p_service = 'shopping' then
    raise exception 'service_unavailable: Shopping is not available yet';
  end if;

  select * into v_before from public.operator_services
    where operator_id = p_operator_id and service_type = p_service for update;

  if p_enable then
    if v_before.state = 'suspended' and v_before.suspension_source = 'admin' then
      raise exception 'service_suspended: this service was suspended by thirty8 and cannot be re-enabled';
    end if;
    insert into public.operator_services (operator_id, service_type, state, enabled_at)
    values (p_operator_id, p_service, 'selected', now())
    on conflict (operator_id, service_type) do update
      set state = 'selected', enabled_at = now(), disabled_at = null;
    v_state := private.operator_service_auto_state(p_operator_id, p_service);
    -- selecting a service never grants approval
    update public.operator_services
       set state = v_state,
           suspension_source = case when v_state = 'suspended' then 'operator_status' else null end
     where operator_id = p_operator_id and service_type = p_service;
    perform private.write_audit('operator_service.enable', 'operator_service', p_operator_id,
      to_jsonb(v_before), jsonb_build_object('service', p_service, 'state', v_state));
    return jsonb_build_object('ok', true, 'state', v_state);
  end if;

  -- disable
  if not found or v_before.state in ('not_selected', 'disabled') then
    return jsonb_build_object('ok', true, 'state', coalesce(v_before.state, 'not_selected'));
  end if;
  v_impact := public.get_service_disable_impact(p_operator_id, p_service);
  if (v_impact ->> 'has_blockers')::boolean and not p_confirm then
    return jsonb_build_object('ok', false, 'confirmation_required', true, 'impact', v_impact);
  end if;

  update public.operator_services
     set state = 'disabled', disabled_at = now()
   where operator_id = p_operator_id and service_type = p_service;
  perform private.write_audit('operator_service.disable', 'operator_service', p_operator_id,
    to_jsonb(v_before), jsonb_build_object('service', p_service, 'impact', v_impact));
  return jsonb_build_object('ok', true, 'state', 'disabled', 'impact', v_impact);
end;
$$;
revoke execute on function public.set_operator_service(uuid, public.operator_service_type, boolean, boolean) from public, anon;
grant execute on function public.set_operator_service(uuid, public.operator_service_type, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- Platform admin: approve / suspend / restore a service
-- ---------------------------------------------------------------------
create or replace function public.admin_set_service_state(
  p_operator_id uuid,
  p_service public.operator_service_type,
  p_action text,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before public.operator_services%rowtype;
  v_state public.operator_service_state;
begin
  if not private.is_platform_admin() then
    raise exception 'Only platform admins can do this';
  end if;
  if p_action not in ('approve', 'suspend', 'restore') then
    raise exception 'Unknown action %', p_action;
  end if;

  select * into v_before from public.operator_services
    where operator_id = p_operator_id and service_type = p_service for update;
  if not found then raise exception 'Operator has not selected this service'; end if;

  if p_action = 'approve' then
    update public.operator_services set admin_approved = true where operator_id = p_operator_id and service_type = p_service;
    v_state := private.operator_service_auto_state(p_operator_id, p_service);
    update public.operator_services set state = v_state, suspension_source = null, suspension_reason = null
     where operator_id = p_operator_id and service_type = p_service;
  elsif p_action = 'suspend' then
    v_state := 'suspended';
    update public.operator_services
       set state = 'suspended', suspension_source = 'admin', suspension_reason = p_reason
     where operator_id = p_operator_id and service_type = p_service;
  else
    v_state := private.operator_service_auto_state(p_operator_id, p_service);
    update public.operator_services set state = v_state, suspension_source = null, suspension_reason = null
     where operator_id = p_operator_id and service_type = p_service;
  end if;

  perform private.write_audit('operator_service.' || p_action, 'operator_service', p_operator_id,
    to_jsonb(v_before), jsonb_build_object('service', p_service, 'state', v_state, 'reason', p_reason));
  return jsonb_build_object('ok', true, 'state', v_state);
end;
$$;
revoke execute on function public.admin_set_service_state(uuid, public.operator_service_type, text, text) from public, anon;
grant execute on function public.admin_set_service_state(uuid, public.operator_service_type, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Server-side enforcement: no NEW buses or trips unless the Bus service is
-- active. Existing trips/bookings are untouched so they can be completed.
-- Skipped for server code (no auth.uid()) and platform admins.
-- ---------------------------------------------------------------------
create or replace function private.guard_bus_service_active()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select auth.uid()) is null or private.is_platform_admin() then
    return new;
  end if;
  if not private.operator_service_active(new.operator_id, 'bus') then
    raise exception 'service_inactive: the Bus service is not active for this operator';
  end if;
  return new;
end;
$$;
revoke execute on function private.guard_bus_service_active() from public, anon;

create trigger guard_bus_service_active
  before insert on public.buses
  for each row execute function private.guard_bus_service_active();

create trigger guard_bus_service_active
  before insert on public.bus_trips
  for each row execute function private.guard_bus_service_active();
