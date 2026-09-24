-- Extensions
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists pg_cron with schema extensions;

-- Private schema: internal helper functions, never exposed via PostgREST.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- Generic updated_at trigger
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function private.set_updated_at() from public, anon, authenticated;

-- Role-check helper functions (private.is_platform_admin, private.is_operator_staff,
-- private.is_operator_admin) are created in 20260923000210_identity.sql, once
-- public.user_roles exists for them to query.
