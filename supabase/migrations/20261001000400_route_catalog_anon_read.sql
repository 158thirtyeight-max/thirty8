-- anon cannot execute private.is_platform_admin(), so the shared select policies
-- failed for logged-out reads. Split by role: anon sees active routes only,
-- authenticated users additionally get the admin override.

drop policy route_templates_select on public.route_templates;
create policy route_templates_select_anon on public.route_templates
  for select to anon using (is_active);
create policy route_templates_select_auth on public.route_templates
  for select to authenticated using (is_active or private.is_platform_admin());

drop policy route_template_stops_select on public.route_template_stops;
create policy route_template_stops_select_anon on public.route_template_stops
  for select to anon
  using (exists (select 1 from public.route_templates t where t.id = template_id and t.is_active));
create policy route_template_stops_select_auth on public.route_template_stops
  for select to authenticated
  using (exists (select 1 from public.route_templates t
                 where t.id = template_id and (t.is_active or private.is_platform_admin())));
