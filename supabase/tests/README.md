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
| `operator_services.sql` | `operator_services`: derived states, selecting never grants approval, owner-only, disable keeps data and blocks new buses/trips |
| `operator_trip_list.sql` | `list_operator_trips`: buckets, seat counts from `trip_seats` (held/sold/blocked), expired holds free, isolation |
| `operator_seat_inventory.sql` | real-time seat inventory: `rev`, counter trigger, double booking, hold expiry/renewal, stale payment-failure guard, block/release, seat map, Broadcast payloads/policies |
| `operator_passenger_boarding.sql` | passenger identity (encrypted, masked), manifest search/filters, verify→board state machine, exceptions, correction, audited reveal, QR rejections persisted |
| `operator_finance.sql` | one financial calculation (gross vs collected vs refunds initiated/completed), commission, settlements (partial/failed/paid rules, clawback, no double settlement), earnings reads, access control |
| `operator_booking_analytics.sql` | per-trip booking stats and cumulative booking trend |
| `operator_gps.sql` | GPS devices/assignments, ingest (service role only), source priority, stale/offline never live, passenger-assisted aggregation + consent, retention, device health |

## Run

Against a real database (after `supabase db push` to a branch/local DB — never production):

```bash
for f in supabase/tests/onboarding_*.sql; do psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"; done
```

Without Supabase, using the bundled in-memory Postgres harness: see `harness/run.mjs`.
It also runs `operator_*.sql`; those tests start with `-- @include fixtures/trip_fixture.sql` (a bus, route, fares and one trip for two operators and two customers). The harness stubs `realtime.send` into `realtime.sent_log`, so Broadcast payloads can be asserted; real Realtime delivery and true two-session concurrency must be checked on a Supabase branch.
