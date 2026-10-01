# Operator onboarding & bus activation — SQL tests

Each phase has a script that runs in a single transaction and rolls back. A failing assertion raises `FAIL <n>: ...`.

| File | Covers |
|---|---|
| `onboarding_phase2.sql` | operator profile/KYC/documents, self-approval blocked, completeness, tenant isolation |
| `onboarding_phase3.sql` | bank constraints, payment mandate, completeness incl. bank/mandate, configurable requirements |
| `onboarding_phase4.sql` | submit / start review / request changes / resubmit / approve / suspend, audit trail |
| `onboarding_phase5.sql` | approved-operator-only `create_bus`, insert lockdown, legacy flagging |
| `onboarding_phase6.sql` | bus documents, expiry, verification |
| `onboarding_phase7.sql` | seat layout validation (duplicates, berths, capacity, aisles, locking) |
| `onboarding_phase8.sql` | routes, stops, timing validation, per-bus routes |
| `onboarding_phase9.sql` | **one fare engine**: search = seat map = hold quote = booking; `fare_changed`; bus gating |
| `onboarding_phase10.sql` | schedule, trip generation |
| `onboarding_phase11.sql` | bus submit/approve/activate/suspend workflow, legacy migration path |
| `onboarding_hardening_phase1.sql` | hold TTL clamp, one booking per hold, one confirmed item per seat |
| `onboarding_hardening_phase2.sql` | payment confirmation: amount/booking/seat checks, late payment -> pending refund, one captured payment per order |
| `onboarding_hardening_phase3.sql` | booking window / cutoff / departed-trip enforcement, cancel_booking seat handling, roll_trip_status |
| `onboarding_hardening_phase4.sql` | operators cannot write routes/points/services/trips/fares directly; set_trip_status; ownership guards |
| `onboarding_hardening_phase5.sql` | public read lockdown: anon/customer/operator/admin reads, get_trip_points, own-booking visibility |
| `onboarding_e2e.sql` | legacy regression (existing demo bus) + full new-operator journey through a customer booking |

## Run

Against a real database (after `supabase db push` to a branch/local DB — never production):

```bash
for f in supabase/tests/onboarding_*.sql; do psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"; done
```

Without Supabase, using the bundled in-memory Postgres harness: see `harness/run.mjs`.
