-- =========================================================================
-- am_i_platform_admin() was never explicitly revoked from public/anon
-- (Postgres grants EXECUTE to PUBLIC by default on new functions, and the
-- original migration only added a grant to authenticated without an
-- accompanying revoke, unlike every other function in this codebase).
-- Functionally harmless — it just returns false for an anonymous caller —
-- but tightened for consistency with the rest of the schema.
-- =========================================================================

revoke execute on function public.am_i_platform_admin() from public, anon;
