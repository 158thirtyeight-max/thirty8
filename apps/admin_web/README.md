# Thirty8 Admin Panel

Next.js web app for platform-level control: operator approval, insurance
verification, user management, bus/cargo oversight, refund queue, revenue
reports, audit logs. Not yet scaffolded — built in Phase 12 of the build plan.

Depends on: `supabase/migrations` (schema, especially the `platform_admin`
role and `private.is_platform_admin()` RLS checks).
