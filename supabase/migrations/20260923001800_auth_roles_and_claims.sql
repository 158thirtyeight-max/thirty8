-- =========================================================================
-- Phase 2 (Auth): default role assignment on signup, JWT custom claims hook.
--
-- Signup convention: the customer app signs users up by phone (OTP), the
-- operator/admin apps by email+password. That distinction is the only
-- signal we have at signup time, so it's what decides the default role.
-- =========================================================================

-- Extend the profile-creation trigger: phone signups (customer app) get the
-- 'customer' role automatically. Email/password signups (operator/admin
-- apps) get NO default role — operators become operator_admin explicitly
-- via register_operator(), and platform_admin is never self-serve.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, phone, email)
  values (new.id, new.phone, new.email)
  on conflict (id) do nothing;

  if new.phone is not null then
    if not exists (
      select 1 from public.user_roles
      where user_id = new.id and role = 'customer' and operator_id is null
    ) then
      insert into public.user_roles (user_id, role) values (new.id, 'customer');
    end if;
  end if;

  return new;
end;
$$;

-- =========================================================================
-- Custom Access Token (JWT) hook: stamps every user's roles onto their JWT
-- as `app_roles` (an array of {role, operator_id}) plus a convenience
-- `is_platform_admin` boolean, so the Flutter/Next.js clients and Edge
-- Functions can read role/operator scoping straight from the session
-- without an extra round trip. RLS itself does NOT depend on this — the
-- private.is_platform_admin() / is_operator_staff() helpers (migration
-- 20260923000210) query public.user_roles directly, so access control is
-- correct even if this hook is never enabled.
--
-- IMPORTANT — manual step required: this function only takes effect once
-- enabled in the Supabase Dashboard under Authentication -> Hooks ->
-- "Customize Access Token (JWT) Claims hook", selecting schema "public"
-- and function "custom_access_token_hook". There is no API/CLI path to
-- enable this for a hosted project, so it cannot be done from here.
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  claims jsonb;
  v_user_id uuid := (event ->> 'user_id')::uuid;
  v_roles jsonb;
  v_is_admin boolean;
begin
  select coalesce(jsonb_agg(jsonb_build_object('role', role, 'operator_id', operator_id)), '[]'::jsonb)
  into v_roles
  from public.user_roles
  where user_id = v_user_id;

  select exists (
    select 1 from public.user_roles
    where user_id = v_user_id and role in ('platform_admin', 'platform_support')
  ) into v_is_admin;

  claims := coalesce(event -> 'claims', '{}'::jsonb);
  claims := jsonb_set(claims, '{app_roles}', v_roles);
  claims := jsonb_set(claims, '{is_platform_admin}', to_jsonb(v_is_admin));

  event := jsonb_set(event, '{claims}', claims);
  return event;
end;
$$;

-- The Auth service calls this as `supabase_auth_admin`, not `authenticated`.
grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;

grant select on public.user_roles to supabase_auth_admin;
create policy user_roles_auth_admin_read on public.user_roles
  for select to supabase_auth_admin
  using (true);
