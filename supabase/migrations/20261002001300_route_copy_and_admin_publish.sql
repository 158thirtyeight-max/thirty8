-- =========================================================================
-- Route copy, admin authored revisions / direct publish, and route history.
--
-- Builds on 20261002001000_route_revisions.sql (the only route revision system):
--   * route_revisions gains an origin (operator / admin / route_copy), copy audit
--     metadata, the publishing admin, and the revision it replaced.
--   * copy_route_to_bus(): copies a route into an independent draft revision of
--     another bus. Nothing is shared between buses and no trip / booking / seat /
--     payment data is touched.
--   * Platform admins can start, edit and publish revisions themselves
--     (admin_publish_route_revision); operators still go through approval.
--   * get_route_history(): revision history with origin and responsible user.
-- All writes stay inside SECURITY DEFINER RPCs; the revision tables remain read-only
-- for every client role.
-- =========================================================================

-- ---------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------
alter table public.route_revisions
  add column origin text not null default 'operator' check (origin in ('operator', 'admin', 'route_copy')),
  -- true when a platform admin started the revision: only admins edit such a draft
  add column admin_authored boolean not null default false,
  add column source_bus_id uuid references public.buses (id) on delete set null,
  add column source_revision_id uuid references public.route_revisions (id) on delete set null,
  -- the revision that was live when this one was activated
  add column replaced_revision_id uuid references public.route_revisions (id) on delete set null,
  add column published_by uuid references public.profiles (id),
  add column published_at timestamptz;

alter table public.route_revision_events drop constraint route_revision_events_event_check;
alter table public.route_revision_events
  add constraint route_revision_events_event_check
  check (event in ('created', 'submitted', 'applied_setup', 'approved', 'rejected', 'withdrawn', 'superseded', 'copied', 'published')),
  add column meta jsonb not null default '{}'::jsonb;

-- Origin and copy metadata are fixed at creation, like the rest of the revision's content.
create or replace function private.guard_revision_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'draft' and (
       new.bus_id is distinct from old.bus_id or new.operator_id is distinct from old.operator_id
       or new.revision_no is distinct from old.revision_no or new.trip_type is distinct from old.trip_type
       or new.name is distinct from old.name or new.change_reason is distinct from old.change_reason
       or new.base_revision_id is distinct from old.base_revision_id or new.created_by is distinct from old.created_by
       or new.submitted_by is distinct from old.submitted_by or new.submitted_at is distinct from old.submitted_at
       or new.origin is distinct from old.origin or new.admin_authored is distinct from old.admin_authored
       or new.source_bus_id is distinct from old.source_bus_id
       or new.source_revision_id is distinct from old.source_revision_id)
  then
    raise exception 'A submitted route revision cannot be edited; create a new revision instead';
  end if;
  if old.status <> 'draft' and old.status <> 'pending_approval' and new.status is distinct from old.status
     and not (old.status = 'approved' and new.status = 'superseded') then
    raise exception 'Route revision is already %', old.status;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- Record which revision a newly activated one replaced (fires inside materialize_revision, for
-- every activation path: setup apply, approval and admin publish).
create or replace function private.record_replaced_revision()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.active_route_revision_id is not null
     and new.active_route_revision_id is distinct from old.active_route_revision_id then
    update public.route_revisions set replaced_revision_id = old.active_route_revision_id
    where id = new.active_route_revision_id;
  end if;
  return new;
end;
$$;
create trigger buses_record_replaced_revision after update of active_route_revision_id on public.buses
  for each row execute function private.record_replaced_revision();

-- ---------------------------------------------------------------------
-- 2. Authorization helpers
-- ---------------------------------------------------------------------
-- Only full platform admins author and publish routes (platform_support stays read / review only).
create or replace function private.is_full_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid()) and ur.role = 'platform_admin'
  );
$$;

-- Who may edit a draft: the side that started it. Admin drafts are admin-only, operator drafts are
-- operator-only (an admin clears an operator draft by withdrawing it).
create or replace function private.can_edit_revision(p_operator_id uuid, p_admin_authored boolean)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case when p_admin_authored then private.is_full_admin() else private.can_manage_routes(p_operator_id) end;
$$;

revoke execute on function private.is_full_admin(), private.can_edit_revision(uuid, boolean),
  private.record_replaced_revision() from public, anon;
grant execute on function private.is_full_admin(), private.can_edit_revision(uuid, boolean) to authenticated;

create or replace function private.load_revision_for_edit(p_revision_id uuid)
returns public.route_revisions
language plpgsql
security definer
set search_path = ''
as $$
declare v_rev public.route_revisions;
begin
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if not private.can_edit_revision(v_rev.operator_id, v_rev.admin_authored) then raise exception 'Not authorized'; end if;
  if v_rev.status <> 'draft' then
    raise exception 'This revision is % and can no longer be edited; start a new revision', v_rev.status;
  end if;
  return v_rev;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Cloning helpers (shared by start_route_revision and copy_route_to_bus)
-- ---------------------------------------------------------------------
-- Copies the journeys and stops of one revision into another. Every stop is a new row.
create or replace function private.clone_revision_journeys(p_from_revision uuid, p_to_revision uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  j public.route_revision_journeys;
  v_jid uuid;
begin
  for j in select * from public.route_revision_journeys where revision_id = p_from_revision loop
    insert into public.route_revision_journeys (revision_id, direction, source_city_id, destination_city_id,
      departure_time, est_duration_min, operating_days, departure_day_offset, reverse_generated)
    values (p_to_revision, j.direction, j.source_city_id, j.destination_city_id, j.departure_time, j.est_duration_min,
            j.operating_days, j.departure_day_offset, j.reverse_generated)
    returning id into v_jid;
    perform private.insert_journey_stops(v_jid, private.journey_stops_json(j.id));
  end loop;
end;
$$;

-- Copies a bus's LIVE route(s) (bus_routes / services / points) into a revision. Returns true when a
-- return journey was found. Used for buses whose route predates revisions.
create or replace function private.clone_live_route_into(p_revision_id uuid, p_bus_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_svc public.bus_services;
  v_route public.bus_routes;
  v_jid uuid;
  d text;
  v_has_return boolean := false;
begin
  foreach d in array array['outbound', 'return'] loop
    v_svc := null;
    if d = 'outbound' then
      select * into v_svc from public.bus_services where id = private.bus_primary_service(p_bus_id);
    else
      select * into v_svc from public.bus_services
      where bus_id = p_bus_id and direction = 'return' and status <> 'retired' order by created_at limit 1;
    end if;
    if v_svc.id is null then continue; end if;
    select * into v_route from public.bus_routes where id = v_svc.route_id;
    if not v_route.active then continue; end if;
    insert into public.route_revision_journeys (revision_id, direction, source_city_id, destination_city_id,
      departure_time, est_duration_min, operating_days)
    values (p_revision_id, d, v_route.source_city_id, v_route.destination_city_id, v_svc.default_departure_time,
            v_svc.est_duration_min, v_svc.operating_days)
    returning id into v_jid;
    perform private.insert_journey_stops(v_jid, private.live_route_stops(v_route.id));
    if d = 'return' then v_has_return := true; end if;
  end loop;
  return v_has_return;
end;
$$;

revoke execute on function private.clone_revision_journeys(uuid, uuid), private.clone_live_route_into(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. start_route_revision: now also usable by platform admins (origin 'admin')
-- ---------------------------------------------------------------------
create or replace function public.start_route_revision(p_bus_id uuid, p_base_revision_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_open public.route_revisions;
  v_base public.route_revisions;
  v_no integer;
  v_rev uuid;
  v_src text;
  v_dst text;
  v_admin boolean := private.is_full_admin();
begin
  select * into v_bus from public.buses where id = p_bus_id for update;
  if v_bus.id is null then raise exception 'Bus not found'; end if;
  if not (v_admin or private.can_manage_routes(v_bus.operator_id)) then raise exception 'Not authorized'; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;
  if v_bus.lifecycle_status not in ('draft', 'changes_requested', 'approved', 'active') then
    raise exception 'Route changes are locked while the bus is %', v_bus.lifecycle_status;
  end if;

  select * into v_open from public.route_revisions where bus_id = p_bus_id and status in ('draft', 'pending_approval');
  if v_open.id is not null then
    if v_open.status = 'pending_approval' then raise exception 'A route change is already awaiting approval'; end if;
    if v_open.admin_authored is distinct from v_admin then
      raise exception '%', case when v_open.admin_authored
        then 'An administrator is preparing a route change for this bus'
        else 'The operator has an unsubmitted draft route change for this bus; withdraw it first' end;
    end if;
    if p_base_revision_id is null then return v_open.id; end if;
    raise exception 'Finish or withdraw the open draft revision first';
  end if;

  if p_base_revision_id is not null then
    select * into v_base from public.route_revisions where id = p_base_revision_id and bus_id = p_bus_id;
    if v_base.id is null then raise exception 'Base revision not found'; end if;
  end if;

  select coalesce(max(revision_no), 0) + 1 into v_no from public.route_revisions where bus_id = p_bus_id;
  insert into public.route_revisions (bus_id, operator_id, revision_no, status, trip_type, base_revision_id, created_by,
                                      origin, admin_authored)
  values (p_bus_id, v_bus.operator_id, v_no, 'draft', coalesce(v_base.trip_type, 'one_way'),
          coalesce(p_base_revision_id, v_bus.active_route_revision_id), (select auth.uid()),
          case when v_admin then 'admin' else 'operator' end, v_admin)
  returning id into v_rev;

  if v_base.id is not null then
    perform private.clone_revision_journeys(v_base.id, v_rev);
  elsif private.clone_live_route_into(v_rev, p_bus_id) then
    update public.route_revisions set trip_type = 'round_trip' where id = v_rev;
  end if;

  select l.name into v_src from public.route_revision_journeys j2 join public.locations l on l.id = j2.source_city_id
    where j2.revision_id = v_rev and j2.direction = 'outbound';
  select l.name into v_dst from public.route_revision_journeys j2 join public.locations l on l.id = j2.destination_city_id
    where j2.revision_id = v_rev and j2.direction = 'outbound';
  if v_src is not null then
    update public.route_revisions set name = v_src || ' to ' || v_dst where id = v_rev;
  end if;

  insert into public.route_revision_events (revision_id, event, actor_id) values (v_rev, 'created', (select auth.uid()));
  return v_rev;
end;
$$;

-- Withdraw: the side that owns the draft, or any platform admin (an admin may clear any open revision).
create or replace function public.withdraw_route_revision(p_revision_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_rev public.route_revisions;
begin
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if not (private.is_full_admin() or private.can_manage_routes(v_rev.operator_id)) then raise exception 'Not authorized'; end if;
  if v_rev.admin_authored and not private.is_full_admin() then raise exception 'Not authorized'; end if;
  if v_rev.status not in ('draft', 'pending_approval') then raise exception 'This revision is already %', v_rev.status; end if;
  update public.route_revisions set status = 'withdrawn' where id = p_revision_id;
  insert into public.route_revision_events (revision_id, event, actor_id) values (p_revision_id, 'withdrawn', (select auth.uid()));
  perform private.write_audit('route.withdrawn', 'route_revision', p_revision_id, null,
    jsonb_build_object('bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id));
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Copy a route to another bus
--
-- Copies the source bus's live route (its active revision, or a chosen approved revision) into a NEW
-- DRAFT revision of the destination bus: journey type, origin / destination, stops and their order,
-- boarding / dropping permissions, arrival / departure offsets, duration, operating days, outbound /
-- return configuration and the reverse-generated flag. All rows are new; the two buses share nothing.
-- NOT copied: trips, bookings, passengers, seats, payments, fares, approval history.
--
-- If the destination already has a route (or an open draft) nothing happens until the caller confirms
-- with p_replace = true; then the copy becomes a new revision on top of the destination's active one.
-- The destination's live route is never overwritten: it stays live until the new revision is approved
-- (operators) or published (admins).
-- ---------------------------------------------------------------------
create or replace function public.copy_route_to_bus(
  p_source_bus_id uuid,
  p_dest_bus_id uuid,
  p_replace boolean default false,
  p_source_revision_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_src public.buses;
  v_dst public.buses;
  v_srev public.route_revisions;
  v_open public.route_revisions;
  v_admin boolean := private.is_full_admin();
  v_has_route boolean;
  v_dst_name text;
  v_rev uuid;
  v_no integer;
  v_trip text := 'one_way';
  v_name text;
  v_src_name text;
  v_dst_city text;
begin
  if p_source_bus_id is null or p_dest_bus_id is null then raise exception 'Choose a source and a destination bus'; end if;
  if p_source_bus_id = p_dest_bus_id then raise exception 'Choose a different bus to copy the route to'; end if;

  -- lock both buses in a fixed order so two concurrent copies cannot deadlock
  perform 1 from public.buses where id in (p_source_bus_id, p_dest_bus_id) order by id for update;
  select * into v_src from public.buses where id = p_source_bus_id;
  select * into v_dst from public.buses where id = p_dest_bus_id;
  if v_src.id is null then raise exception 'Source bus not found'; end if;
  if v_dst.id is null then raise exception 'Destination bus not found'; end if;

  if not (v_admin or private.can_manage_routes(v_src.operator_id)) then raise exception 'Not authorized to copy this route'; end if;
  if not (v_admin or private.can_manage_routes(v_dst.operator_id)) then raise exception 'Not authorized to change the destination bus'; end if;
  if not private.operator_is_approved(v_dst.operator_id) then raise exception 'The destination operator account is not approved'; end if;
  if v_dst.lifecycle_status not in ('draft', 'changes_requested', 'approved', 'active') then
    raise exception 'Route changes are locked while the destination bus is %', v_dst.lifecycle_status;
  end if;

  -- the route being copied
  if p_source_revision_id is not null then
    select * into v_srev from public.route_revisions
    where id = p_source_revision_id and bus_id = p_source_bus_id and status in ('approved', 'superseded');
    if v_srev.id is null then raise exception 'That route version cannot be copied'; end if;
  elsif v_src.active_route_revision_id is not null then
    select * into v_srev from public.route_revisions where id = v_src.active_route_revision_id;
  elsif not exists (select 1 from public.bus_routes where bus_id = p_source_bus_id and direction = 'outbound' and active) then
    raise exception 'The source bus has no route to copy';
  end if;

  -- destination state
  v_has_route := v_dst.active_route_revision_id is not null
    or exists (select 1 from public.bus_routes where bus_id = p_dest_bus_id and direction = 'outbound' and active);
  select * into v_open from public.route_revisions where bus_id = p_dest_bus_id and status in ('draft', 'pending_approval');
  if v_open.id is not null and v_open.status = 'pending_approval' then
    raise exception 'A route change is already awaiting approval on the destination bus';
  end if;
  if v_open.id is not null and v_open.admin_authored and not v_admin then
    raise exception 'An administrator is preparing a route change for the destination bus';
  end if;

  if (v_has_route or v_open.id is not null) and not p_replace then
    select name into v_dst_name from public.route_revisions where id = v_dst.active_route_revision_id;
    return jsonb_build_object('ok', false, 'needs_confirmation', true,
      'destination_has_route', v_has_route, 'destination_has_draft', v_open.id is not null,
      'destination_route_name', v_dst_name);
  end if;

  -- an unsubmitted draft on the destination is replaced by the copy
  if v_open.id is not null then
    update public.route_revisions set status = 'withdrawn' where id = v_open.id;
    insert into public.route_revision_events (revision_id, event, actor_id, reason, meta)
    values (v_open.id, 'withdrawn', (select auth.uid()), 'Replaced by a copied route',
            jsonb_build_object('replaced_by_copy_from_bus_id', p_source_bus_id));
  end if;

  select coalesce(max(revision_no), 0) + 1 into v_no from public.route_revisions where bus_id = p_dest_bus_id;
  insert into public.route_revisions (bus_id, operator_id, revision_no, status, trip_type, base_revision_id, created_by,
                                      origin, admin_authored, source_bus_id, source_revision_id)
  values (p_dest_bus_id, v_dst.operator_id, v_no, 'draft', 'one_way', v_dst.active_route_revision_id, (select auth.uid()),
          'route_copy', v_admin, p_source_bus_id, v_srev.id)
  returning id into v_rev;

  if v_srev.id is not null then
    perform private.clone_revision_journeys(v_srev.id, v_rev);
    v_trip := v_srev.trip_type;
    v_name := v_srev.name;
  elsif private.clone_live_route_into(v_rev, p_source_bus_id) then
    v_trip := 'round_trip';
  end if;

  if v_name is null then
    select l.name, l2.name into v_src_name, v_dst_city
    from public.route_revision_journeys j
    join public.locations l on l.id = j.source_city_id
    join public.locations l2 on l2.id = j.destination_city_id
    where j.revision_id = v_rev and j.direction = 'outbound';
    if v_src_name is not null then v_name := v_src_name || ' to ' || v_dst_city; end if;
  end if;
  update public.route_revisions set trip_type = v_trip, name = v_name where id = v_rev;

  insert into public.route_revision_events (revision_id, event, actor_id, meta)
  values (v_rev, 'copied', (select auth.uid()),
          jsonb_build_object('source_bus_id', p_source_bus_id, 'source_revision_id', v_srev.id,
                             'destination_bus_id', p_dest_bus_id, 'replaced_existing_route', v_has_route));
  perform private.write_audit('route.copied', 'route_revision', v_rev, null,
    jsonb_build_object('source_bus_id', p_source_bus_id, 'source_revision_id', v_srev.id,
                       'destination_bus_id', p_dest_bus_id, 'operator_id', v_dst.operator_id,
                       'replaced_existing_route', v_has_route));

  return jsonb_build_object('ok', true, 'revision_id', v_rev, 'validation', private.validate_revision(v_rev));
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Admin direct publish. One transaction: validate, activate (materialise), mark the revision
--    approved / published by the admin, supersede the previous one, notify the operator, audit.
--    Only drafts an administrator authored can be published this way; operator drafts keep going
--    through submit -> admin_review_route_revision.
-- ---------------------------------------------------------------------
create or replace function public.admin_publish_route_revision(p_revision_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rev public.route_revisions;
  v_bus public.buses;
  v_check jsonb;
  v_reason text := nullif(btrim(p_reason), '');
  v_previous uuid;
begin
  if not private.is_full_admin() then raise exception 'Not authorized'; end if;
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  if v_rev.status <> 'draft' then raise exception 'This revision is %, only a draft can be published', v_rev.status; end if;
  if not v_rev.admin_authored then
    raise exception 'This draft was started by the operator; it must be submitted and approved instead';
  end if;
  if v_reason is null then raise exception 'A reason for the change is required'; end if;
  select * into v_bus from public.buses where id = v_rev.bus_id for update;
  v_previous := v_bus.active_route_revision_id;

  v_check := private.validate_revision(p_revision_id);
  if not (v_check ->> 'valid')::boolean then
    return jsonb_build_object('ok', false, 'errors', v_check -> 'errors');
  end if;

  perform private.materialize_revision(p_revision_id);
  update public.route_revisions
  set status = 'approved', submitted_by = (select auth.uid()), submitted_at = now(), change_reason = v_reason,
      reviewed_by = (select auth.uid()), reviewed_at = now(),
      published_by = (select auth.uid()), published_at = now()
  where id = p_revision_id;
  insert into public.route_revision_events (revision_id, event, actor_id, reason, meta)
  values (p_revision_id, 'published', (select auth.uid()), v_reason,
          jsonb_build_object('previous_revision_id', v_previous, 'origin', v_rev.origin));

  insert into public.notifications (profile_id, title, body, data, type)
  select distinct ur.user_id, 'Route updated by admin',
         coalesce(v_rev.name, 'The route') || ' on bus ' || v_bus.registration_number || ' was updated: ' || v_reason,
         jsonb_build_object('revision_id', p_revision_id, 'bus_id', v_rev.bus_id), 'route_revision_published'
  from public.user_roles ur where ur.operator_id = v_rev.operator_id and ur.role = 'operator_admin';

  perform private.write_audit('route.published', 'route_revision', p_revision_id,
    jsonb_build_object('previous_revision_id', v_previous),
    jsonb_build_object('revision_id', p_revision_id, 'bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id,
                       'origin', v_rev.origin, 'reason', v_reason, 'published', true));
  return jsonb_build_object('ok', true, 'status', 'approved', 'applied', true, 'previous_revision_id', v_previous);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Route history. One bus (admin or its operator) or, for admins, every bus (p_bus_id null).
--    Admin identities are shown to admins only; operators see "Platform admin".
-- ---------------------------------------------------------------------
create or replace function public.get_route_history(p_bus_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_viewer_admin boolean := private.is_platform_admin();
  v_bus public.buses;
begin
  if p_bus_id is null then
    if not v_viewer_admin then raise exception 'Not authorized'; end if;
  else
    select * into v_bus from public.buses where id = p_bus_id;
    if v_bus.id is null then raise exception 'Bus not found'; end if;
    if not (v_viewer_admin or private.is_operator_staff(v_bus.operator_id)) then raise exception 'Not authorized'; end if;
  end if;

  return coalesce((
    select jsonb_agg(h order by (h ->> 'created_at') desc) from (
      select jsonb_build_object(
        'id', r.id, 'bus_id', r.bus_id, 'registration_number', b.registration_number, 'operator_name', o.name,
        'revision_no', r.revision_no, 'status', r.status, 'origin', r.origin, 'trip_type', r.trip_type, 'name', r.name,
        'change_reason', r.change_reason, 'rejection_reason', r.rejection_reason,
        'created_at', r.created_at, 'submitted_at', r.submitted_at, 'reviewed_at', r.reviewed_at,
        'published_at', r.published_at, 'activated_at', r.activated_at,
        'is_active', b.active_route_revision_id = r.id,
        'is_published', r.published_by is not null,
        'previous_revision_id', r.replaced_revision_id, 'previous_revision_no', prev.revision_no,
        'base_revision_no', base.revision_no,
        'source_bus_id', r.source_bus_id, 'source_registration_number', sb.registration_number,
        'created_by_id', case when v_viewer_admin then r.created_by end,
        'created_by_name', case when r.admin_authored and not v_viewer_admin then 'Platform admin'
                                else coalesce(pc.full_name, pc.email) end,
        'reviewed_by_id', case when v_viewer_admin then r.reviewed_by end,
        'reviewed_by_name', case when r.reviewed_by is not null and not v_viewer_admin then 'Platform admin'
                                 else coalesce(pr.full_name, pr.email) end,
        'published_by_id', case when v_viewer_admin then r.published_by end,
        'events', coalesce((
          select jsonb_agg(jsonb_build_object('event', e.event, 'reason', e.reason, 'at', e.created_at, 'meta', e.meta)
                           order by e.created_at, e.id)
          from public.route_revision_events e where e.revision_id = r.id), '[]'::jsonb)
      ) as h
      from public.route_revisions r
      join public.buses b on b.id = r.bus_id
      join public.operators o on o.id = r.operator_id
      left join public.route_revisions prev on prev.id = r.replaced_revision_id
      left join public.route_revisions base on base.id = r.base_revision_id
      left join public.buses sb on sb.id = r.source_bus_id
      left join public.profiles pc on pc.id = r.created_by
      left join public.profiles pr on pr.id = r.reviewed_by
      where (p_bus_id is null or r.bus_id = p_bus_id)
      order by r.created_at desc
      limit 300
    ) q), '[]'::jsonb);
end;
$$;


-- ---------------------------------------------------------------------
-- 9. Fix: private.diff_journeys appended an untyped literal to a text[] ("malformed array literal"),
--    so any comparison with a changed departure time / duration / days failed.
-- ---------------------------------------------------------------------
create or replace function private.diff_journeys(c jsonb, p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_added jsonb; v_removed jsonb; v_reseq jsonb; v_perm jsonb; v_times jsonb; v_fields text[] := '{}';
begin
  if c is null and p is null then return jsonb_build_object('added_journey', false, 'removed_journey', false); end if;
  if c is null then return jsonb_build_object('added_journey', true, 'removed_journey', false); end if;
  if p is null then return jsonb_build_object('added_journey', false, 'removed_journey', true); end if;

  with cs as (select * from jsonb_to_recordset(c -> 'stops') as x(city_id uuid, name text, sequence_no int,
                is_boarding boolean, is_dropping boolean, arrival_offset_min int, departure_offset_min int)),
       ps as (select * from jsonb_to_recordset(p -> 'stops') as x(city_id uuid, name text, sequence_no int,
                is_boarding boolean, is_dropping boolean, arrival_offset_min int, departure_offset_min int)),
       cc as (select *, row_number() over (order by sequence_no) as pos from cs where city_id in (select city_id from ps)),
       pc as (select *, row_number() over (order by sequence_no) as pos from ps where city_id in (select city_id from cs))
  select
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', ps.city_id, 'name', ps.name, 'position', ps.sequence_no) order by ps.sequence_no), '[]')
       from ps where ps.city_id not in (select city_id from cs)),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', cs.city_id, 'name', cs.name, 'position', cs.sequence_no) order by cs.sequence_no), '[]')
       from cs where cs.city_id not in (select city_id from ps)),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', pc.city_id, 'name', pc.name, 'from', cc.sequence_no, 'to', pc.sequence_no) order by pc.sequence_no), '[]')
       from cc join pc using (city_id) where cc.pos <> pc.pos),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', pc.city_id, 'name', pc.name,
              'boarding', jsonb_build_object('from', cc.is_boarding, 'to', pc.is_boarding),
              'dropping', jsonb_build_object('from', cc.is_dropping, 'to', pc.is_dropping)) order by pc.sequence_no), '[]')
       from cc join pc using (city_id)
       where cc.is_boarding is distinct from pc.is_boarding or cc.is_dropping is distinct from pc.is_dropping),
    (select coalesce(jsonb_agg(jsonb_build_object('city_id', pc.city_id, 'name', pc.name,
              'arrival', jsonb_build_object('from', cc.arrival_offset_min, 'to', pc.arrival_offset_min),
              'departure', jsonb_build_object('from', cc.departure_offset_min, 'to', pc.departure_offset_min)) order by pc.sequence_no), '[]')
       from cc join pc using (city_id)
       where cc.arrival_offset_min is distinct from pc.arrival_offset_min
          or cc.departure_offset_min is distinct from pc.departure_offset_min)
  into v_added, v_removed, v_reseq, v_perm, v_times;
  -- (added/removed are listed first in the select; the order matches the INTO list)

  if (c ->> 'departure_time') is distinct from (p ->> 'departure_time') then v_fields := v_fields || 'departure_time'::text; end if;
  if (c ->> 'duration_min') is distinct from (p ->> 'duration_min') then v_fields := v_fields || 'duration'::text; end if;
  if (c -> 'operating_days') is distinct from (p -> 'operating_days') then v_fields := v_fields || 'operating_days'::text; end if;
  if (c ->> 'departure_day_offset') is distinct from (p ->> 'departure_day_offset') then v_fields := v_fields || 'departure_day_offset'::text; end if;

  return jsonb_build_object(
    'added_journey', false, 'removed_journey', false,
    'direction_changed', (c ->> 'source_city_id') is distinct from (p ->> 'source_city_id')
                         or (c ->> 'destination_city_id') is distinct from (p ->> 'destination_city_id'),
    'added_stops', v_added, 'removed_stops', v_removed, 'resequenced', v_reseq,
    'permission_changes', v_perm, 'time_changes', v_times, 'schedule_changes', to_jsonb(v_fields));
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------
revoke execute on function
  public.copy_route_to_bus(uuid, uuid, boolean, uuid), public.admin_publish_route_revision(uuid, text),
  public.get_route_history(uuid)
  from public, anon;
grant execute on function
  public.copy_route_to_bus(uuid, uuid, boolean, uuid), public.admin_publish_route_revision(uuid, text),
  public.get_route_history(uuid)
  to authenticated;
