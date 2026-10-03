-- While a bus is still being set up (draft / changes requested) its route is applied directly, as
-- save_bus_route always allowed for operator staff. Once the bus is approved a route change needs an
-- operator administrator to submit it and a platform admin to approve it.
create or replace function public.submit_route_revision(p_revision_id uuid, p_reason text default null)
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
begin
  select * into v_rev from public.route_revisions where id = p_revision_id for update;
  if v_rev.id is null then raise exception 'Route revision not found'; end if;
  select * into v_bus from public.buses where id = v_rev.bus_id for update;

  if v_bus.lifecycle_status in ('draft', 'changes_requested') then
    if not private.can_manage_routes(v_rev.operator_id) then raise exception 'Not authorized'; end if;
  elsif not private.is_operator_admin(v_rev.operator_id) then
    raise exception 'Only an operator administrator can submit a route change';
  end if;
  if v_rev.status <> 'draft' then raise exception 'This revision is already %', v_rev.status; end if;
  if not private.operator_is_approved(v_bus.operator_id) then raise exception 'The operator account is not approved'; end if;

  v_check := private.validate_revision(p_revision_id);
  if not (v_check ->> 'valid')::boolean then
    return jsonb_build_object('ok', false, 'errors', v_check -> 'errors');
  end if;

  if v_bus.lifecycle_status in ('draft', 'changes_requested') then
    perform private.materialize_revision(p_revision_id);
    update public.route_revisions
    set status = 'approved', submitted_by = (select auth.uid()), submitted_at = now(),
        change_reason = coalesce(v_reason, 'Initial route setup')
    where id = p_revision_id;
    insert into public.route_revision_events (revision_id, event, actor_id, reason)
    values (p_revision_id, 'applied_setup', (select auth.uid()), v_reason);
    perform private.write_audit('route.applied_setup', 'route_revision', p_revision_id, null,
      jsonb_build_object('bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id));
    return jsonb_build_object('ok', true, 'status', 'approved', 'applied', true);
  end if;

  if v_reason is null then raise exception 'A reason for the change is required'; end if;
  update public.route_revisions
  set status = 'pending_approval', submitted_by = (select auth.uid()), submitted_at = now(), change_reason = v_reason
  where id = p_revision_id;
  insert into public.route_revision_events (revision_id, event, actor_id, reason)
  values (p_revision_id, 'submitted', (select auth.uid()), v_reason);

  insert into public.notifications (profile_id, title, body, data, type)
  select distinct ur.user_id, 'Route change awaiting approval',
         coalesce(v_rev.name, 'A route') || ' on bus ' || v_bus.registration_number || ' needs review.',
         jsonb_build_object('revision_id', p_revision_id, 'bus_id', v_rev.bus_id), 'route_revision_submitted'
  from public.user_roles ur where ur.role in ('platform_admin', 'platform_support');

  perform private.write_audit('route.submitted', 'route_revision', p_revision_id, null,
    jsonb_build_object('bus_id', v_rev.bus_id, 'operator_id', v_rev.operator_id, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'status', 'pending_approval', 'applied', false);
end;
$$;

revoke execute on function public.submit_route_revision(uuid, text) from public, anon;
grant execute on function public.submit_route_revision(uuid, text) to authenticated;
