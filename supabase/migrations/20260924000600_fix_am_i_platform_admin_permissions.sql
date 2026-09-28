-- =========================================================================
-- Fix: same class of bug as get_cargo_quote — am_i_platform_admin() was not
-- SECURITY DEFINER, so calling it as an ordinary authenticated user (e.g.
-- from the `refund` Edge Function's admin check) would fail with
-- "permission denied for schema private" before ever reaching the actual
-- admin check. A SECURITY DEFINER function's body executes its internal
-- statements as the owner at every call; a plain (invoker-rights) function
-- re-checks the CALLING role's own schema/object grants on every execution
-- — which is why this class of bug doesn't show up in RLS policies (those
-- have their function references resolved once at CREATE POLICY time,
-- effectively under the policy owner) but does show up in ordinary
-- SECURITY INVOKER functions and RPC calls.
-- =========================================================================

create or replace function public.am_i_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_platform_admin();
$$;
