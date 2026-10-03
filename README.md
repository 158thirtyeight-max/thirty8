# Thirty8

Bus ticketing + cargo shipping platform for the Andaman & Nicobar Islands.

## Apps

- `apps/customer_app` — **Thirty8** customer app (Flutter). Search and book bus tickets, ship and track cargo.
- `apps/operator_app` — **Thirty8 Plus** operator app (Flutter). For bus operators and cargo transporters: fleet, schedules, manifests, boarding, shipments.
- `apps/admin_web` — Admin Panel (Next.js). Platform-level oversight: operator approval, users, refunds, finance, audit logs.

## Backend

All backend logic lives in Supabase (project `xdrthrdwdfzhzhqkhnnf`):

- `supabase/migrations` — versioned Postgres schema (tables, RLS policies, functions, triggers, cron jobs).
- `supabase/functions` — Edge Functions (Deno/TypeScript) for payment orchestration, search, and other server-side operations.
- `supabase/seed` — seed data (cities, boarding points, reference data).

See `Info/plan/` for the full product/design planning documents this build follows.

## Local development

```bash
supabase login
supabase link --project-ref xdrthrdwdfzhzhqkhnnf
supabase db push          # apply migrations
supabase functions deploy # deploy edge functions
```

## Recurring schedules & booking window

Operators set a recurring schedule once (`bus_services`: times + `operating_days`). The backend
(`private.run_rolling_schedule_generation`, pg_cron hourly + 00:05 IST) creates the missing
departures (`bus_trips` + `trip_seats`) inside each route's admin-controlled booking window
(`scheduling_settings`, `route_booking_windows`; Admin → Booking windows). Customers only see
departures the backend says are inside the window (`search_trips`, seat-hold guard).
Tests: `supabase/tests/recurring_schedule_engine_test.sql` (needs the demo seed).
