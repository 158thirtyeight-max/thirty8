# Thirty8 Admin Panel

Next.js (App Router) web app for platform-level control. No service-role key
anywhere — every page reads/writes as the logged-in platform_admin's own
session; the `*_admin_all` RLS policies (gated on `private.is_platform_admin()`)
are what actually enforce access.

Built so far (Phase 12):
- Auth (email/password) gated by `am_i_platform_admin()`, session via `@supabase/ssr` + middleware
- Dashboard: KPI counts (pending operators, bookings, shipments, refunds, gross revenue)
- Operators: list, detail, approve/reject/suspend/reinstate, insurance policy verification
- Users: all profiles with their roles
- Bookings / Shipments: platform-wide oversight lists
- Refunds: pending queue, "Process refund" invokes the `refund` Edge Function with the admin's own JWT
- Revenue: gross/refunded/net totals + daily breakdown
- Audit logs: read-only list (table exists; nothing writes to it yet — see below)

Not yet built: writing to `audit_logs` from the mutating paths above (approve/reject/refund
aren't audited yet), user suspension/ban, coupon management, notification template editor.

## Local development

```bash
npm install
npm run dev
```

Requires `.env.local` with `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`
(see `.env.example`) — the anon key is public by design, RLS is the real gate.

Depends on: `supabase/migrations` (schema, especially the `platform_admin`
role and `private.is_platform_admin()` RLS checks), `supabase/functions/refund`.
