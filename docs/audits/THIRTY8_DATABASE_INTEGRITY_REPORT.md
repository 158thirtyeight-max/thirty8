# thirty8 — Database Integrity Report and Proposed Repair Plan

Read-only assessment. Nothing was applied: no migrations, DDL, DML, RLS/storage changes, deployments or application code edits. Companion to `THIRTY8_BUS_OPERATIONS_AUDIT.md`.

**Method and evidence labels**
- Live project: `xdrthrdwdfzhzhqkhnnf` (ACTIVE_HEALTHY, ap-southeast-1). Confirmed as the project in `supabase/config.toml` and as the only project visible to the connected MCP before any query ran.
- Live inspection used SELECT-only queries against `pg_catalog`, `information_schema`, `storage.buckets`, `pg_policies`, `pg_proc`, `pg_trigger`, `pg_indexes`, the MCP table/migration/function/advisor listings, plus orphan checks on bus-chain tables. No secret values or personal data were read. One test ran `SET LOCAL ROLE anon; SELECT count(*)` inside a rolled-back transaction (it failed, which was the finding).
- Before running each orphan check, column names and types were verified from `information_schema.columns` for `buses`, `bus_services`, `bus_trips`, `bookings`, `booking_items`, `orders`, `payments`, `refunds`, `seat_holds`, `trip_seats`, `pickup_drop_points`.
- Legend: LIVE/CODE findings are CONFIRMED gaps; where the exploit was not exercised (no live data to trigger it, e.g. cross-tenant trip insert, verified-status insurance INSERT, duplicate booking from one hold) the impact is POTENTIAL. UNVERIFIED = not checked.
- Labels: **LIVE** (queried), **CODE** (repo/app source), **UNVERIFIED** (not checked or needs a runtime test). Classification: PRESENT AND MATCHING / MISSING FROM DATABASE / PRESENT BUT DIFFERENT / PRESENT BUT DISCONNECTED / DUPLICATE-OVERLAPPING / UNUSED / UNABLE TO VERIFY.
- Limits: live data is small (operators 2, buses 2, trips 7, trip_seats 252, bookings/orders/payments 0). Orphan checks returning 0 therefore say little about future behaviour. Repo object-by-object SQL comparison was not done for all 53 migrations; see Section A.2.

---

## A. Actual database inventory

### A.1 Live counts (LIVE)

| Item | Count |
|---|---|
| Tables | 57 (56 `public` + `private.app_secrets`) |
| Views | 4 (`bus_document_expiry`, `main_locations`, `route_stops`, `service_stops`) |
| Functions | 59 public, 42 private |
| Non-internal triggers (public/private/storage/auth) | 45 |
| Enums | 23 |
| Foreign keys (public) | 106 |
| RLS policies | 145 public, 20 storage |
| Indexes (public) | 209 |
| Buckets | 9 (public: `bus-photos`, `operator-logos`, `user-avatars`) |
| Cron jobs | 3 |
| Edge functions | 6 ACTIVE; `razorpay-webhook` and `send-notification` have `verify_jwt=false` |
| Extensions | pg_cron, pg_net, pg_stat_statements, pg_trgm, pgcrypto, plpgsql, supabase_vault, uuid-ossp |
| RLS disabled | `private.app_secrets` only (schema not API-exposed; anon has no USAGE) |

### A.2 Migration reconciliation (by identity, not timestamp)

- Repo: **53** files in `supabase/migrations`. Live history: **51** entries.
- Live versions use different timestamps than the repo filenames (e.g. repo `20260926000100_onboarding_foundation` ↔ live `20260930165721 onboarding_foundation`; repo `20260923000100_extensions_and_helpers` ↔ live `20260923145521 extensions_and_helpers`). Matching by migration **name**, repo files 1–51 correspond one-to-one with the 51 live entries (PRESENT AND MATCHING by name).
- **MISSING FROM LIVE HISTORY:** `20261001000500_main_locations_and_points` and `20261001000600_location_routes_and_search`. Their objects **do exist live**: tables/views `pickup_drop_points`, `main_locations`, `route_stops`, `service_stops`; `search_trips` with the 5-parameter signature (matches repo migration 52/53's `drop function public.search_trips(uuid,uuid,date)` + new definition); `get_journey_points`. Classification: PRESENT BUT DIFFERENT (history) — applied outside tracked migrations, so `supabase db push`/`migration list` will report drift.
- **LIVE-ONLY (not found in repo by grep):** `public.rls_auto_enable()` (SECURITY DEFINER, executable by anon and authenticated).
- Content equality: SQL bodies were not diffed for all objects. Spot checks matched: FK set for the bus-to-payment chain, column lists of key tables, indexes on booking/payment tables, `search_trips`/`get_journey_points` signatures, enum values. Everything else is **UNABLE TO VERIFY** for content equality. Recommended follow-up (Phase 0 below): `supabase db diff` against a shadow database, read-only.

### A.3 Live column/PK/FK facts used in this report (LIVE)

All bus-chain tables have uuid PKs named `id`, except operator onboarding tables whose PK is `operator_id` (1:1 with `operators`). Foreign keys that exist, with delete behaviour (c = cascade, a = no action, n = set null):

- `buses.operator_id → operators` (c); `bus_layouts.bus_id → buses` (c); `seats.bus_layout_id → bus_layouts` (c); `bus_documents.bus_id → buses` (c).
- `bus_routes.operator_id → operators` (c), `bus_routes.bus_id → buses` (c); `boarding_points/dropping_points.route_id → bus_routes` (c), `master_point_id → pickup_drop_points` (a).
- `bus_services.operator_id → operators` (c), `route_id → bus_routes` (c), `bus_id → buses` (a).
- `bus_trips.service_id → bus_services` (c), `operator_id → operators` (c), `route_id → bus_routes` (a), `bus_id → buses` (a).
- `fare_rules.service_id → bus_services` (c), `from_boarding_point_id/to_dropping_point_id → points` (c); `fare_charges.service_id → bus_services` (c).
- `trip_seats.trip_id → bus_trips` (c), `seat_id → seats` (a), `hold_id → seat_holds` (n).
- `seat_holds.trip_id → bus_trips` (c), `user_id → profiles` (a), points (a).
- `booking_items.booking_id → bookings` (c), `trip_id → bus_trips` (a), `trip_seat_id → trip_seats` (a), `passenger_id → passengers` (a), points (a); `passengers.booking_id → bookings` (c); `bookings.customer_id → profiles` (a).
- `orders.customer_id → profiles` (a); `payments.order_id → orders` (c); `refunds.payment_id → payments` (a).
- Not FKs (confirmed absent): `orders.orderable_id`, `wallet.owner_id`, `operator_insurance.bus_id`, `operator_insurance.cargo_vehicle_id`, any `bookings → bus_trips/operator`, any `payments → bookings`.

---

## B. Missing tables

**No missing tables found.** Every table and view referenced by the three apps through `.from()` exists live (checked for every name found in `admin_web/src`, `operator_app/lib`, `customer_app/lib`), and every RPC name used by the apps exists live with a matching name. Every repo-defined table has a live counterpart, plus live has the three views and `pickup_drop_points` from the untracked migrations.

Considered and rejected candidate tables (equivalent already exists — requirement 3):

| Candidate | Existing equivalent | Decision |
|---|---|---|
| `trip_cancellations` / trip cancel log | `bus_trips.status`, `bus_trip_events` (0 rows, unused), `audit_logs` | Do not add a table; add RPC + use existing `bus_trip_events`/`audit_logs`. |
| `driver`/`conductor` assignment table | `user_roles` (roles `driver`,`conductor` scoped to operator) | No bus/trip assignment relationship exists at all. This is a **missing relationship**, not a missing table; decide between a nullable `bus_trips.driver_id` + `conductor_id` → `profiles` or an assignment table only after product decision. UNVERIFIED need. |
| `payment_attempts` | `orders`, `payments`, `processed_webhook_events` | Not needed; fix constraints instead. |
| `cancellation_policies` | none | Genuinely absent; required only if cancellation policy is a product requirement (customer dialog already promises one). Defer; confirm requirement first. |
| `booking_holds` consumption | `seat_holds.status` has a `confirmed` value (used in confirm path) | Use existing column. |

---

## C. Broken and missing relationships

Separated by kind (requirement 4).

### C.1 Missing foreign keys

| # | Source → target | Cardinality | Evidence | Impact | Proposed correction |
|---|---|---|---|---|---|
| FK1 | `orders.orderable_id` → `bookings.id` / `cargo_shipments.id` (polymorphic by `orderable_type` enum `booking`/`cargo_shipment`) | many-to-one | LIVE: no FK; orphan check on bookings returned 0 (0 orders) | Orders can point at nothing; payment confirmation updates 0 rows silently | Cannot be a single FK. Prefer two nullable columns `booking_id`, `cargo_shipment_id` with FKs and a CHECK matching `orderable_type`; backfill from `orderable_id`; keep `orderable_id` until app code migrated. Or a deferred-constraint trigger. |
| FK2 | `wallet.owner_id` | n/a | LIVE: no FK, no writers, 0 rows | Unused table | Resolve by decision on wallet (see D). |
| FK3 | `operator_insurance.bus_id` → `buses.id`; `.cargo_vehicle_id` → `cargo_vehicles.id` | many-to-one | LIVE: plain uuid; 0 rows | Dangling refs | Add FKs after confirming the table is kept (overlaps `bus_documents`). |
| FK4 | `payments` ↔ booking | via `orders` | LIVE: only `payments.order_id` | Acceptable: booking reachable through order | No change; FK1 closes the gap. |

### C.2 Missing uniqueness / cardinality constraints

| # | Constraint | Evidence | Impact | Correction |
|---|---|---|---|---|
| U1 | One active booking item per `trip_seat_id` | LIVE: only unique `(booking_id, trip_seat_id)` | The same seat can be in many bookings; combined with `create_booking` not consuming the hold, duplicates are possible | Partial unique index on `booking_items(trip_seat_id) WHERE status in ('confirmed', pending states)`; check existing data first (currently 0 rows). Needs enum value review of `booking_item` status. |
| U2 | One service per bus | LIVE: no unique on `bus_services.bus_id`; live check `buses_multi_service` = 0; code uses `bus_primary_service` (oldest) | Ambiguity if a second service is created | Unique index on `bus_services(bus_id)` only if one-service-per-bus is the intended model (CODE says so). Confirm before enforcing. |
| U3 | One payment per order | LIVE: `payments.order_id` not unique (unique on `razorpay_payment_id`) | Multiple captured payments per order possible | Partial unique on `payments(order_id) WHERE status='captured'`. |
| U4 | `refunds` per payment | LIVE: no unique; refund edge function not serialised | Double refund | Add status `processing` + unique partial index; fix in function. |

### C.3 Incorrect business relationships (cross-operator / ownership)

| # | Relationship | Evidence | Impact | Correction |
|---|---|---|---|---|
| R1 | `bus_trips.bus_id`/`service_id` belongs to same operator as `bus_trips.operator_id` | LIVE: no constraint/trigger on `bus_trips` except `generate_trip_seats`; policy `bus_trips_operator_manage` checks only `operator_id`; orphan checks returned 0 (clean today) | Operator A can insert a trip referencing operator B's bus/service | Composite uniqueness `buses(id, operator_id)` + composite FK `bus_trips(bus_id, operator_id)`; same for `bus_services`; or a BEFORE INSERT/UPDATE guard trigger. Run orphan check first (already 0). |
| R2 | Direct operator writes to routes/services/trips/fares bypass approval | LIVE: `bus_routes_operator_manage`, `bus_services_operator_manage`, `bus_trips_operator_manage` (`FOR ALL`, `is_operator_staff(operator_id)`), join-based policies on points, `fare_rules`, `fare_charges`; no lifecycle triggers on them | Approved bus' fares/routes editable without review | Replace `FOR ALL` with SELECT-only for operators (writes via existing RPCs), after moving the legacy `bus_ops` screens to RPCs. Existing bookings unaffected. |
| R3 | Driver/conductor have operator-wide staff rights | CODE (`is_operator_staff` includes both) | Over-privilege | Introduce a manager-role helper; apply in RPCs `activate_bus`, `save_bus_fares`, etc. |
| R4 | Unapproved operator cannot create buses | LIVE: `guard_bus_insert` trigger present; `bus_active_operator_not_approved` = 0 | Enforced for buses | PRESENT AND MATCHING |
| R5 | Operator approval/bus approval separation | LIVE: separate `operators` workflow trigger and `guard_bus_update`; admin RPCs distinct | Enforced | PRESENT AND MATCHING |
| R6 | Legacy buses are active without review | LIVE: 1 bus `is_legacy`, lifecycle `active` (`AN01-DEMO-0001`) | Skips review | Decision: route through `legacy_migration_status` review or deactivate demo bus. No data change in this task. |
| R7 | Operator insurance verification | LIVE: trigger `BEFORE UPDATE` only; policy `FOR ALL` for staff | INSERT with verified status not guarded by the trigger | Extend trigger to `INSERT`; or retire table in favour of `bus_documents`. |

### C.4 Relationship chain verification (operator → ticket)

| Edge | Table exists | FK exists / correct target | Orphan-creatable? | Cross-operator risk | App uses it |
|---|---|---|---|---|---|
| operators → operator_profiles/kyc/bank/mandates/documents | yes | yes (cascade, PK=operator_id) | No parent-less rows possible | RLS by operator; bank/KYC readable by all staff roles (CODE) | A, O |
| operators → buses | yes | yes (cascade) | No | `guard_bus_insert` enforces approval | A, O |
| buses → bus_documents | yes | yes | No | path trigger only for bus docs | A, O |
| buses → bus_layouts → seats | yes | yes, one active layout (partial unique) | No | via RPC `save_bus_layout` (policies dropped) | A, O, C(RPC) |
| buses → bus_routes → boarding/dropping_points | yes | yes | No | legacy direct writes (R2) | A, O, C |
| bus_routes/bus_id → bus_services | yes | yes; `bus_id` no unique (U2) | A service may omit `bus_id` (nullable) — live `service_null_bus` = 0 | R1, R2 | A, O |
| bus_services → bus_trips | yes | yes (cascade) | trips may carry mismatching `bus_id`/`route_id`/`operator_id` (R1); live mismatches 0 | R1 | A(none), O, C |
| bus_services → fare_rules/fare_charges | yes | yes | No | R2 | A(view), O, C(RPC) |
| bus_trips → trip_seats | yes | yes; trigger generates seats | live trips without seats = 0 | seat generation follows `bus_trips.bus_id` | C(RPC) |
| trip_seats ↔ seat_holds | yes | `hold_id` set null on delete | holds can expire while seats stay `held` until cron | n/a | C(RPC) |
| bookings → booking_items → trip_seats | yes | yes, no cascade to seats; `bookings` has **no direct trip/operator FK** (reached via items) | items for same seat possible (U1) | n/a | C |
| bookings → passengers | yes | yes | n/a | n/a | C |
| orders → payments → refunds | yes | order→booking not an FK (FK1); payment→order yes; refund→payment yes | confirm can apply to expired booking (CODE+LIVE function) | n/a | C, A, edge |
| driver/conductor → bus/trip | **no relationship** | none | n/a | n/a | none |
| live location | columns on `bus_trips` (`current_latitude/longitude`) | n/a | n/a | any staff of operator can update; public read | O, C(RPC) |
| notifications/audit | tables exist | `audit_logs` written by RPCs; insurance verify bypasses | n/a | n/a | A |

Deleting/deactivating parents: `buses → bus_services/bus_trips` is **no action**, so deleting a bus with services/trips is blocked (safe). `operators → buses` is cascade, which cascades to bus documents, layouts and routes; `bus_trips.operator_id` cascade removes trips that already have `booking_items` (blocked by `booking_items.trip_id` no-action FK), so deletion fails rather than orphaning — acceptable but surfaces as an error. Operator deletion cascading `bus_services → bus_trips` and `bus_routes` should be restricted for any operator with bookings (UNVERIFIED; not exercised).

---

## D. Orphan, duplicate and overlap risks

Live orphan/consistency checks (all LIVE, SELECT-only, columns verified beforehand):

| Check | Result |
|---|---|
| trips whose bus operator ≠ trip operator | 0 |
| trips whose service operator ≠ trip operator | 0 |
| trips whose service bus ≠ trip bus | 0 |
| trips whose service route ≠ trip route | 0 |
| trips with null bus | 0 |
| services whose bus operator ≠ service operator | 0 |
| services with null bus | 0 |
| bus_routes whose bus operator ≠ route operator | 0 |
| active buses of non-approved operators | 0 |
| routes lacking boarding or dropping points | 0 |
| trips without trip_seats | 0 |
| services without fare rules | 0 |
| trip_seats with fare 0 | 0 |
| buses with more than one service | 0 |
| buses where `total_seats` ≠ active layout seat count | 0 |
| legacy buses | 1 |

The schema allows all of the above to become non-zero; they are clean only because live data is minimal.

Overlap / duplicate / unused:

| Item | Classification | Detail |
|---|---|---|
| `operators.status` vs `application_status` | DUPLICATE/OVERLAPPING | Two status models, trigger-synchronised in RPCs (CODE) |
| `buses.status` vs `lifecycle_status` | DUPLICATE/OVERLAPPING | `status` (active/maintenance/inactive) operator-editable; visibility needs both |
| `buses` 5 photo columns (`photo_urls`, `exterior/interior_photo_path`, `exterior/interior_photo_keys`) | DUPLICATE | Mixed Supabase storage vs R2 |
| `operator_insurance` vs `bus_documents` (insurance doc type) | DUPLICATE | Admin reviews insurance via direct update |
| `bus_routes` (per bus) vs `route_templates` | OVERLAPPING | Catalog has 0 rows live; free-form routes still allowed |
| `boarding_points/dropping_points` vs `pickup_drop_points` | OVERLAPPING | `master_point_id` links them; apps use both (6 `.from` uses of `pickup_drop_points`) |
| `bus_trips.min_fare_cents/max_fare_cents` vs fare engine | PRESENT BUT DISCONNECTED | Populated for all 7 live trips; customer fares come from `resolve_seat_fare`, not these columns |
| `wallet`, `wallet_transactions` | UNUSED | No app reference, no writer function found, 0 rows |
| `saved_passengers`, `notification_preferences`, `bus_trip_events` | UNUSED | 0 rows; not referenced by the three apps' `.from()` calls (RPC/trigger use not excluded) |
| `route_templates`, `route_template_stops`, `fare_charges` | PRESENT BUT DISCONNECTED | Used by admin/operator code, 0 rows live |
| `public.rls_auto_enable()` | LIVE-ONLY / UNABLE TO VERIFY origin | Not in repo |

Nothing is to be deleted or merged as part of this report.

---

## E. Application connectivity matrix

| Feature | App | Expected object | Actual object (LIVE exists) | Relationship | Status |
|---|---|---|---|---|---|
| Operator registration | Operator | `register_operator` | exists | creates operator + `operator_admin` role | Connected |
| Operator review | Admin | `admin_review_operator` | exists | updates `operators`, `audit_logs` | Connected |
| Insurance review | Admin | RPC | direct `operator_insurance.update` | bypasses audit; trigger-protected | Raw write |
| Bus create/submit/activate | Operator | `create_bus`, `submit_bus`, `activate_bus` | exist | guard triggers | Connected |
| Bus review | Admin | `admin_review_bus` | exists | `buses` | Connected |
| Layout save | Operator | `save_bus_layout` | exists | `bus_layouts`,`seats` | Connected |
| Layout view | Admin/Customer | `bus_layouts`,`seats`; `get_trip_seat_map` | exist | customer uses `row_no/col_no` only | Connected, simplified |
| Route/fares/schedule save | Operator | `save_bus_route/fares/schedule` | exist | | Connected |
| Route/service/trip direct writes | Operator (legacy bus_ops) | tables | exist | bypass RPC | Raw write (R2) |
| Trip generation | Operator | `generate_bus_trips` | exists | trigger builds `trip_seats` | Connected |
| Trip visibility | Admin | trips page | none | — | Missing app usage |
| Search | Customer | `search_trips(3 args)` | exists with 5 args (2 defaulted) | pickup/drop params unused by app | Compatible, new params unused |
| Journey points | Customer | `get_journey_points`, `main_locations`, `pickup_drop_points` | exist | `main_locations_provider.dart` | Connected |
| Seat hold / booking | Customer | `create_seat_hold`, `create_booking` | exist | see C.2 | Connected, weak constraints |
| Payment | Customer/edge | `create-order`, `verify-payment`, webhook | ACTIVE | `confirm_booking_after_payment` | Connected, weak guards |
| Refund | Admin | edge `refund` | ACTIVE | | Connected |
| Operator bookings | Operator | none | none | — | Missing |
| Operator ↔ shared_types | all Flutter | none | `shared_types` TS only | raw maps | Inconsistent |

Admin features that cannot manage Operator-created records: trips, layouts, fares, schedules (view only), driver/conductor, bookings detail. Customer features that cannot retrieve valid operator data without the RPC: direct `operators`/`bus_layouts` reads fail for anon (LIVE test `42501`).

---

## F. Prioritized findings

### CRITICAL
| ID | Finding | Evidence | Objects | Impact | Repair |
|---|---|---|---|---|---|
| DB-C1 | Payment confirmation without booking-state or amount guard | LIVE function source: no `payment_pending` check, no `amount` comparison; seats forced `booked` | `confirm_booking_after_payment`, `orders`, `bookings`, `trip_seats` | Oversell/wrong amount recorded | Rewrite function: lock booking, require `payment_pending`, compare amount, else mark payment for refund |
| DB-C2 | Hold reuse / duplicate booking per seat | LIVE function source: no hold update/no existing-booking check; unique only `(booking_id, trip_seat_id)` | `create_booking`, `seat_holds`, `booking_items` | Duplicate bookings/orders | Mark hold consumed in same transaction; add U1 |
| DB-C3 | Legacy operator write policies bypass approval, no cross-tenant check on trips | LIVE `pg_policies` | `bus_routes`,`bus_services`,`bus_trips`,points,`fare_*` | Fare/route tampering after approval | R1 + R2 |
| DB-C4 | Webhook swallows failure and marks event processed | CODE `razorpay-webhook/index.ts` | `processed_webhook_events`, edge function | Captured payment unconfirmed | Insert event after success, or store result/retry |

### HIGH
| ID | Finding | Evidence | Repair |
|---|---|---|---|
| DB-H1 | Hold TTL uncapped, no cutoff/trip-status/departure checks in `create_seat_hold` | LIVE function pattern check | Clamp TTL server-side; enforce `booking_close_at`, cutoffs, `status='scheduled'`, departure in future in hold, seat map, `create_booking` |
| DB-H2 | Anon policies call private helper functions | LIVE test `42501` on `operators`, `bus_layouts`; `cargo_vehicles` policy same pattern (LIVE policy listing) | Recreate the three policies with anon-safe predicates (as done for `buses_select_public`) |
| DB-H3 | Public `using(true)` reads on trips, services, routes, points, fares, `trip_seats` | LIVE policies | Restrict to bookable bus or expose via RPC/views; note customer app reads `bus_trips`, points directly (bus_details_screen) so migrate those reads first |
| DB-H4 | Insurance INSERT not guarded; verify bypasses audit | LIVE trigger def; admin direct update | R7; use RPC with `write_audit` |
| DB-H5 | Driver/conductor privileges | CODE | R3 |
| DB-H6 | Migration history drift and live-only `rls_auto_enable()` | LIVE vs repo | Register or squash; review function |
| DB-H7 | No trip-cancel flow; cancellation full refund, no `available_seats` refresh | CODE | New RPC using existing tables |
| DB-H8 | Refund not serialised, no unique refund-per-payment | CODE + LIVE indexes | U4 |

### MEDIUM
| ID | Finding | Repair |
|---|---|---|
| DB-M1 | `orders.orderable_id` polymorphic without FK | FK1 |
| DB-M2 | `bus_services.bus_id` not unique; nullable | U2 after decision |
| DB-M3 | No driver/conductor↔bus/trip relationship | Product decision, then nullable FKs |
| DB-M4 | Document expiry does not affect bookability; path ownership checks missing for operator docs | Add expiry condition to `is_bus_bookable`; path-prefix trigger |
| DB-M5 | Anon-executable security-definer functions (`rls_auto_enable`, cargo quote functions) | Revoke where unintended |
| DB-M6 | Leaked-password protection off; storage buckets without size/MIME limits; `private.app_secrets` RLS off | Config + enable RLS |
| DB-M7 | `bus_trips` live location publicly readable, `update_bus_location` unchecked | Restrict columns/view |

### LOW
Overlapping status/photo columns, unused `wallet*`/`saved_passengers`/`bus_trip_events`, `min/max_fare_cents` disconnected from the fare engine, Flutter raw maps, stale `functions/README`.

---

## G. Proposed repair sequence (not implemented)

General rules: additive migrations only; each migration includes pre-check SQL, a rollback script, and a test; no drops of tables/columns/data; existing bookings preserved; no second data model. Backfill only where noted. All SQL must be reviewed against the live definitions first; apply to a Supabase branch/shadow database before production.

| Phase | Change | Depends on | Risk | Backfill | Rollback | Tests |
|---|---|---|---|---|---|---|
| 0 | Reconcile migration history: capture live definitions of the two untracked migrations and live-only `rls_auto_enable`; mark them applied via `migration repair` (history table only); decide on `rls_auto_enable` | none | Low | none | revert history rows | `supabase db diff` empty |
| 1 | `create_booking`: consume hold, reject existing booking for hold, clamp TTL in `create_seat_hold`; add partial unique index `booking_items(trip_seat_id)` for active statuses (U1) | 0 | Medium (function behaviour) | none; pre-check duplicates (0 now) | `create or replace` previous bodies; drop index | double-call with same hold; concurrent holds; TTL negative/huge |
| 2 | `confirm_booking_after_payment`: lock order+booking, require `payment_pending`, compare `p_amount_cents` to `orders.amount_cents`, handle late payment (mark refund pending); webhook: write processed event only after success; payments unique on captured per order (U3) | 1 | High (payment path) | none | previous bodies; drop index | payment after expiry; wrong amount; replay; webhook failure retry |
| 3 | Enforce booking windows: in hold/seat map/booking check `status='scheduled'`, `departure_at > now()`, `booking_close_at`, cutoffs; refresh `available_seats` on cancel | 1 | Medium | none | previous bodies | past-departure, cutoff boundary |
| 4 | Move legacy `bus_ops` Flutter screens to existing RPCs, then replace operator `FOR ALL` policies on routes/services/trips/points/fares with SELECT; add ownership guard trigger or composite FK for trips (R1) | app change first | High (operator workflow) | verify no live orphans (0 now) | restore previous policies | operator edit after approval is denied; RPC path works; cross-tenant insert fails |
| 5 | Fix anon policies on `operators`, `bus_layouts`, `cargo_vehicles`; replace public `using(true)` on trips/services/fares/points/`trip_seats` with bookable-only predicates or RPC reads; customer app direct reads (bus_details_screen) migrated first | 4 | Medium | none | previous policies | anon select returns only approved/bookable rows; customer flow unaffected |
| 6 | Insurance: extend trigger to INSERT, route admin verify via audited RPC | none | Low | none | revert trigger | operator cannot insert verified |
| 7 | Role refinement: manager-only helper for activate/fares/trip generation/bank data | 4 | Medium | map existing `operator_staff` | previous function bodies | driver cannot activate |
| 8 | FKs: `orders` booking/cargo columns (FK1) with CHECK, `operator_insurance` FKs (FK3), `bus_services.bus_id` unique (U2) after decision | 2 | Medium | backfill from `orderable_id`; pre-check orphans | drop constraints/columns | insert integrity tests |
| 9 | Trip cancellation RPC (reuse `bus_trips.status`, `bus_trip_events`, `audit_logs`, `refunds`), cancellation policy only if required | 2,3 | Medium | none | drop function | cancel trip with confirmed bookings refunds and frees seats |
| 10 | Storage/config: bucket limits, enable RLS on `private.app_secrets`, leaked-password protection, constant-time secret compare | none | Low | none | revert settings | upload limit tests |

Application files affected (no edits made): `apps/operator_app/lib/features/bus_ops/*`, `apps/operator_app/lib/features/fleet/*`, `apps/customer_app/lib/features/search/bus_details_screen.dart`, `.../booking/payment_screen.dart`, `apps/admin_web/src/app/(admin)/operators/actions.ts` (insurance), `supabase/functions/razorpay-webhook`, `refund`, `create-order`.

Tests required: extend `supabase/tests` with cases for payment confirmation, hold reuse, TTL abuse, direct-write RLS bypass, anon policies and cross-tenant trips (none exist today).

---

## H. Lists requested

**Missing tables:** none. **Missing relationships:** `orders`→booking/cargo, `operator_insurance`→bus/cargo vehicle, driver/conductor→bus/trip, trip-ownership consistency, one-active-item-per-seat.
**Disconnected:** `route_templates*`, `fare_charges` (no rows), `bus_trips.min/max_fare_cents`, `search_trips` point parameters (not used by customer app).
**Duplicated/overlapping:** status pairs, photo columns, insurance vs bus documents, per-bus routes vs templates, points vs pickup points.
**Unused:** `wallet`, `wallet_transactions`, `saved_passengers`, `notification_preferences`, `bus_trip_events`.
**Not verifiable here:** SQL body equality for most of the 53 migrations; runtime behaviour of payment/webhook flows; `custom_access_token_hook` registration; origin of `rls_auto_enable`.

## I. Admin / Operator / Customer connectivity gaps

- Admin: no trips, layout, fare or schedule management; insurance review bypasses RPC/audit; no booking detail.
- Operator: legacy `bus_ops` writes bypass the staged RPCs; no bookings view; no role differentiation.
- Customer: `search_trips` point parameters unused; direct reads of `bus_trips`/points rely on public policies; web payment not implemented; connected itineraries cannot be booked.

---

## J. Addendum — Phase 0 and Phase 1 execution (2026-10-01)

### Phase 0 — migration history reconciliation (no history writes were needed)

Between the audit and this phase the live database changed: `main_locations_and_points`, `location_routes_and_search` and a new `clean_slate_route_data` migration were applied live (history versions `20261001141839`, `…141930`, `…143421`). This supersedes finding **DB-H6 (history drift)** and several live counts in sections A–D:
live `bus_routes`, `bus_services`, `bus_trips`, `boarding_points`, `route_templates` are now **0 rows** (the clean-slate migration deleted demo route data); `bookings` is still 0.

Reconciliation by name: the 54 repo migration files correspond to 55 live history entries. The one extra live entry, `fix_set_updated_at_search_path`, is already folded into repo `20260923000100_extensions_and_helpers.sql` (identical `private.set_updated_at()` body, verified). Content checks for the two previously untracked migrations: all 7 functions compared by whitespace-stripped body hash; 5 identical, `save_bus_route` and `search_trips` identical after stripping SQL comments (live bodies carry no comments). `pickup_drop_points` columns, policies and the `cities` columns match the repo DDL.

Still open (not changed): (1) history **versions** differ from repo filenames for every migration (live uses apply-time timestamps), so the Supabase CLI would treat all migrations as unapplied; fixing this means either renaming repo files to the live versions or rewriting history versions, which is a decision for you. (2) `public.rls_auto_enable()` exists live and not in the repo; origin unknown, left untouched. (3) `supabase db diff` was not run (no CLI/Docker on this machine).

### Phase 1 — hold and booking integrity (applied)

- Repo: `supabase/migrations/20261002000100_booking_hold_integrity.sql`; rollback `supabase/rollbacks/20261002000100_booking_hold_integrity.down.sql` (restores the pre-change bodies; their hashes were verified identical to the live originals); tests `supabase/tests/onboarding_hardening_phase1.sql`.
- Applied live as history entry `20261001143834 booking_hold_integrity`. Live function body hashes equal the repo file; grants unchanged (anon cannot execute, authenticated can). Live `booking_items` had 0 rows, so the pre-check and index build were trivial.
- Changes: `create_seat_hold` clamps the hold lifetime to 30–600 s (null → 300 s); `create_booking` raises `hold_already_used` when the hold already backs a pending/confirmed/completed item; unique partial index `booking_items_one_confirmed_per_seat_idx` on `booking_items(trip_seat_id)` for confirmed/completed items.
- Deviation from the plan: the index covers confirmed/completed only, not pending. A pending item outlives its 5-minute hold (cron expires it after 30 minutes) and the seat can be legitimately resold, so a pending-inclusive index would block valid bookings.
- Interaction with Phase 2: until `confirm_booking_after_payment` is hardened, a late payment for an expired booking whose seat was since confirmed to someone else now fails on this index (error, payment captured but booking unconfirmed) instead of silently double-booking.
- Testing: run on the local PGlite harness only (not production). New test file passes; a control run without the migration fails at `FAIL 1a: TTL not capped`; full suite results are identical to the pre-change baseline — `onboarding_e2e.sql` (B5) and `onboarding_phase11.sql` (1e) fail before and after for an unrelated reason (the bus-photo requirement), so the e2e booking journey is not covered by a passing test. The PGlite harness stubs Supabase, so concurrent-call behaviour of the new guard (row lock serialisation) was reasoned from the `FOR UPDATE` on the hold row, not exercised.
- Client impact: the customer app maps known error strings; `hold_already_used` is new and will show as a generic error. A normal flow never triggers it.

---

## K. Addendum — Phase 2 execution: payment confirmation integrity (2026-10-01)

### A defect in my Phase 1 change, found by the Phase 2 tests and fixed
The one-booking-per-hold guard added in Phase 1 matched booking items by trip seat only. A stale **pending** item from an expired hold (items stay pending for 30 minutes, holds last 5) therefore blocked a *different* customer from booking that seat after the hold expired. Live had no bookings, so nothing was affected, but it would have broken resale. Fixed by `20261002000150_fix_hold_guard.sql` (items are matched to the hold by customer and creation time; applied live as `fix_hold_guard`). Regression test added to `onboarding_hardening_phase1.sql` (2f) and exercised by phase 2 scenario 3/5; a control run without the fix fails.

### Applied to the live database
- `20261002000200_payment_confirmation_integrity.sql` (live history `payment_confirmation_integrity`): `confirm_booking_after_payment` now, under row locks, confirms only when the paid amount equals the order amount, the booking is still `payment_pending` (cargo: shipment `draft`), and every seat is free or still held by the same customer on the same trip. Otherwise it records the payment, marks the order paid, leaves the booking/seats untouched, queues a **pending refund** (existing admin refund workflow) and returns `status: refund_pending`. A unique-violation during fulfilment also takes the refund path. New unique index `payments_one_captured_per_order_idx`.
- Live function body hashes equal the repo migration files; `confirm_booking_after_payment` remains executable by `service_role` only.
- Edge functions deployed (live versions: `razorpay-webhook` v3 with `verify_jwt=false`, `verify-payment` v3 with `verify_jwt=true`; flags preserved):
  - `razorpay-webhook`: an event is recorded as processed only after its handler succeeds; handler failures return 500 so Razorpay redelivers; a concurrent duplicate record (23505) is tolerated; events for unknown orders are logged and acknowledged.
  - `verify-payment`: returns HTTP 409 `payment_not_applied` instead of `ok:true` when the payment could not be applied, including when the webhook processed the payment first.
- Post-deploy checks: unsigned POST to the webhook returns `400 Invalid signature` (module and secret load), GET returns 405; `verify-payment` answers OPTIONS from function code and rejects a request without a JWT with 401.

### Testing
- `supabase/tests/onboarding_hardening_phase2.sql` (local PGlite harness, not production): happy path, replay idempotency, one captured payment per order, wrong amount, late payment after the seat was resold (not revived, refund queued, no oversell), late payment with a still-free seat (honoured), seat taken by another booking (refund queued). Control run without the migration fails (`FAIL 1h`).
- Webhook logic was exercised with a stubbed Deno/Supabase harness: success, RPC error (500, event not recorded), already-processed, concurrent duplicate, record failure, unknown order, `refund_pending` result, bad JSON, `payment.failed`, `refund.processed` error — all pass.
- Full suite: identical to the pre-change baseline apart from the new files; `onboarding_e2e.sql` (B5) and `onboarding_phase11.sql` (1e) still fail on the unrelated bus-photo requirement.
- Not tested: real Razorpay events, a real Supabase JWT call to `verify-payment`, `refund` edge function end to end. Edge functions were not run under Deno (no Deno on this machine); syntax was checked with Node's TypeScript stripping.

### Rollback
`supabase/rollbacks/20261002000200_payment_confirmation_integrity.down.sql` (restores the previous function body, hash verified identical to the live original, and drops the index) and `…000150_fix_hold_guard.down.sql`. Edge functions: redeploy the previous source from git (`git show HEAD:supabase/functions/<name>/index.ts`). Pending refunds already queued are left for the admin.

### Remaining gaps (not changed)
1. `handle_payment_failure` releases seats and fails the booking on the **first** failed attempt, although Razorpay lets the customer retry the same order. A later successful retry is now refunded rather than honoured. Needs a product decision (ignore failed attempts until the order expires?).
2. `verify-payment` passes the order amount, not Razorpay's actual amount, to the database; the amount check is meaningful on the webhook path only. Fetching the payment from Razorpay would close this; not done (untestable offline).
3. A refund is only *queued*; an admin must process it from the refunds page. There is no notification to the customer, and the customer app shows its generic "payment succeeded but could not be confirmed" message for a 409.
4. `refund` edge function is still not serialised (double-refund risk, DB-H8).
5. The `trip_seat_must_be_bookable` trigger and trip status/departure checks in the confirmation path were not reviewed.

---

## L. Addendum — Phase 3 execution: booking windows, cutoffs and trip status (2026-10-01)

### Applied to the live database
`20261002000300_booking_window_enforcement.sql` (live history `booking_window_enforcement`). Live function body hashes equal the repo file for all seven objects; grants unchanged (new helper is not executable by anon/authenticated). A rolled-back anonymous `search_trips` call on the live database runs and returns empty (live has no trips).

- New `private.trip_is_open_for_booking(trip)`: status `scheduled`, `departure_at > now()`, `booking_open_at <= now()`, and `coalesce(booking_close_at, departure_at) > now()`. (`booking_open_at` is NOT NULL default `now()`; `booking_close_at` is nullable. `generate_bus_trips` sets close = departure minus the service's `booking_cutoff_min`.)
- `search_trips` (direct trips and both legs of connected itineraries), `get_trip_seat_map` and `create_seat_hold` require it. A closed trip no longer appears in search, returns no seat map, and a hold fails with `trip_closed`.
- `create_booking` requires only `status = 'scheduled'` and `departure_at > now()`. Deliberate: the sales window is enforced when the hold is created, so a customer who already holds seats can finish paying within the hold lifetime even if the window closes meanwhile; a departed or cancelled trip is always refused (`trip_closed`).
- `cancel_booking`: refreshes the trip's `available_seats`; a customer cannot cancel a trip that has already departed (`trip_departed`; platform admins still can); and it frees only seats that still belong to the booking, so cancelling a stale pending booking can no longer free a seat that has since been resold. (Found while testing: the old code freed every seat of the booking regardless of who held it now.)
- `private.roll_trip_status`: dropped the one-day lower bound, so trips missed by the hourly job for longer than a day now roll to `departed`/`arrived`.
- Not changed: `boarding_cutoff_min` (it concerns boarding at the stop, not sales); refund amount is still always 100% with no cancellation policy (DB-H7 remains partly open).

### Testing
`supabase/tests/onboarding_hardening_phase3.sql` on the local PGlite harness (not production): open trip is searchable/holdable; closed by window, not-yet-open, departed, and cancelled each disappear from search, seat map and holds; hold taken before the window closes can still be booked, but not after departure; cancel refreshes `available_seats`; customer cannot cancel a departed trip, admin can; stale pending booking cannot free a resold seat; `roll_trip_status` rolls a trip that departed three days ago. A control run without the migration fails (`FAIL 2a: closed trip still in search`). Full suite unchanged apart from the new file; the two bus-photo failures (`onboarding_e2e.sql` B5, `onboarding_phase11.sql` 1e) predate this work.

### Rollback
`supabase/rollbacks/20261002000300_booking_window_enforcement.down.sql` restores the six previous function bodies (five hash-verified identical to the live originals; `search_trips` identical apart from SQL comments) and drops the helper.

### Notes and remaining gaps
1. The customer app has no handling for the new `trip_closed` / `trip_departed` errors (generic message), and shows "Could not load the seat map" when the map is null for a closed trip. App code was not changed.
2. Booking windows only matter for trips that exist; live currently has no trips (clean-slate migration), so this is untested against real generated trips. `generate_bus_trips` was not changed.
3. Refund policy, operator-side trip cancellation (and the matching refunds), and `handle_payment_failure` retry behaviour remain open.
4. `private.roll_trip_status` is executable by anon/authenticated (pre-existing grant; `private` is not an exposed schema and anon has no USAGE on it).

---

## M. Addendum — Phase 4 execution: operator write lockdown (2026-10-01)

### Operator app (code, repo only — needs a new app build)
The legacy "Routes" and "Trips" tabs wrote the lockdown tables directly. Changed in `apps/operator_app/lib/features/bus_ops/`:
- `routes_list_screen.dart`, `route_points_screen.dart`: now read-only (no "Add route", no "Add point"); routes and points are set in the bus setup (Fleet → bus → Route), which already uses `save_bus_route`.
- `services_list_screen.dart`: no "Add service" (services come from the bus schedule step, `save_bus_schedule`); "Schedule a trip" replaced by **Generate trips** (date range, max 90 days) calling `generate_bus_trips`.
- `trip_detail_screen.dart`: status changes now call the new `set_trip_status` RPC, with readable messages for `trip_has_bookings` / `invalid_transition`.
- Deleted `route_form_screen.dart`, `service_form_screen.dart`, `trip_form_screen.dart`.
- `flutter analyze` (whole operator app): no issues. Not run on a device or emulator; screens were not exercised.
- The fleet wizard, dashboard and admin web only read these tables or use RPCs/admin policies, so they are unaffected (checked by grep).

### Applied to the live database
`20261002000400_operator_write_lockdown.sql` (live history `operator_write_lockdown`); live function body hashes equal the repo file.
- New `public.set_trip_status(trip, status)` (authenticated only): operator staff of an **approved** operator, or a platform admin; allowed transitions scheduled→boarding→departed→arrived and cancel from scheduled/boarding; cancelling a trip that has pending/confirmed bookings is refused (`trip_has_bookings`, since it needs the refund workflow); writes an audit row.
- Ownership guard triggers on `bus_routes`, `bus_services`, `bus_trips`: the bus, service and route referenced by a row must belong to the row's operator, and a trip's route/bus must match its service. They apply to every writer, including admin and SECURITY DEFINER RPCs. Resolves finding **R1 / DB-C3 (cross-tenant trips)**.
- The seven `*_operator_manage` FOR ALL policies (routes, services, trips, boarding/dropping points, fare rules, fare charges) are dropped and replaced by operator SELECT-only policies. Operators now change these tables only through the RPCs (`save_bus_route`, `save_bus_fares`, `save_bus_schedule`, `generate_bus_trips`, `set_trip_status`); platform admin keeps `*_admin_all`. Resolves **R2** for these tables. Not covered: `cargo_vehicles_operator_manage`, `cargo_shipments_operator_manage`, `buses_operator_update` (guarded by `guard_bus_update`), `operator_insurance` (DB-H4).

### Testing
- `supabase/tests/onboarding_hardening_phase4.sql` (local PGlite harness, not production): operator reads still work; direct UPDATE/DELETE of fares, charges, services, routes, trips and points change 0 rows; direct INSERT of trips, routes and points is refused; another operator, a customer and a suspended operator cannot call `set_trip_status`; transition rules; audit rows; cancel refused with a pending booking and allowed for an admin without bookings; ownership guards reject cross-operator trips, services and routes (also for a superuser); `generate_bus_trips` still works under the guards. Control run without the migration fails (`FAIL 1d: operator changed fares directly (4 rows)`, i.e. the original exploit).
- Full suite unchanged apart from the new file (the two bus-photo failures predate this work). The rollback was applied on top of the migrations in the harness: all seven `*_operator_manage` policies return, `set_trip_status` and the triggers disappear.
- `admin_assign_route_to_bus` has no test; it delegates to `save_bus_route`, which is covered.

### Rollback
`supabase/rollbacks/20261002000400_operator_write_lockdown.down.sql` (re-opens the direct write paths; do not use unless needed).

### Rollout note
Operator app builds released before this change still show the old Routes/Trips write screens; from now on those writes fail with a permission error. Live currently has no routes, services or trips, so nothing is lost, but update the operator app before operators are onboarded. `bus_services`, `bus_trips`, points and fare tables are still publicly readable (`using (true)`); tightening that is Phase 5.

---

## N. Addendum — Phase 5 execution: public read lockdown (2026-10-01)

Note on ordering: the unified-locations migration (`cities` renamed to `locations`, `pickup_drop_points` removed, `search_trips` parameters renamed) was applied live by the project owner just before this phase (live history `unified_locations`). Phase 5 was written to be independent of it (it uses `to_jsonb(row)` for stops, not column names) and was tested with it in place.

### Applied to the live database
`20261002000600_public_read_lockdown.sql` (live history `public_read_lockdown`; live function body hashes equal the repo file).
- **Dropped the open reads** on `bus_routes`, `bus_services`, `bus_trips` (incl. live-location columns), `boarding_points`, `dropping_points`, `fare_rules`, `fare_charges`, `trip_seats`, `seats`, `bus_layouts`, `buses` (chassis/engine numbers, and suspended/inactive buses), `operators` (legal name, contact details) and `cargo_vehicles`. Resolves **DB-H3 / H6** and **DB-H7**: the policies on `operators`, `bus_layouts`, `cargo_vehicles` called private helper functions that anon cannot execute, so anonymous reads failed with `permission denied for function is_operator_staff`; there is no longer any anon policy that calls a private function. Verified on live: anon `SELECT count(*)` on operators, bus_layouts, cargo_vehicles, buses, bus_trips and fare_rules now runs and returns 0.
- **New `public.get_trip_points(trip)`** (anon + authenticated, SECURITY DEFINER): boarding/dropping points of an open, bookable trip (null otherwise). It replaces the customer app's last direct reads of `bus_trips`, `boarding_points` and `dropping_points`.
- **What stays readable:** a customer reads the trip and stops of their **own bookings** (needed by "My trips"; implemented with definer helpers `private.customer_has_booking_on_trip` / `customer_booked_point` so it does not recurse into booking RLS); operator staff read their own operator row, seats and trip seats (routes, services, trips, points, fares, layouts and buses already had operator SELECT policies); platform admin keeps `*_admin_all`. `cargo_vehicles` active rows are readable by signed-in users only.
- Everything customer-facing (`search_trips`, `get_trip_seat_map`, holds, booking, payment) goes through SECURITY DEFINER RPCs and was unaffected.

### Client changes (repo only, need new builds)
- Customer app `bus_details_screen.dart`: stops now come from `get_trip_points` (analyze: only the four pre-existing `groupValue`/`onChanged` deprecation infos remain). Old customer builds that read `bus_trips` / stops directly will get empty results for the stop pickers.
- Operator app and admin web needed no change (operators read through their SELECT policies; admin through `*_admin_all`; verified by grep of every `.from()` call).

### Testing
- `supabase/tests/onboarding_hardening_phase5.sql` (local PGlite harness, not production): anon and a customer without bookings read 0 rows of 13 guarded tables (no errors); search, seat map, `get_trip_points`, hold and booking still work for customers, and search / `get_trip_points` for anon; a customer sees only their own booking's trip and stops (also after the trip left) and not another customer's; operator A reads its own data, operator B sees none of A's and only its own operator row; admin sees everything; `get_trip_points` returns null for a cancelled trip and a suspended bus. The control run without the migration reproduces the live defect (`permission denied for function is_operator_staff`).
- The earlier hardening test files and `onboarding_locations.sql` read `trip_seats` / `route_stops` as a customer; since that is no longer possible they now read seat ids / stop counts through `pg_temp` SECURITY DEFINER helpers (test-only; the production paths use RPCs). Full suite otherwise unchanged (the two bus-photo failures predate this work). Rollback was applied on top of the migrations in the harness: all 13 open policies return and the new functions are removed.

### Rollback
`supabase/rollbacks/20261002000600_public_read_lockdown.down.sql` (re-opens anonymous reads and the anon permission errors).

### Remaining
`ratings_reviews` (public, includes reviewer profile ids), `cities`/`locations` and the cargo reference tables stay public by design; `route_stops` / `service_stops` views are security-invoker, so they now show rows only to operators/admin (no client uses them). Customer-app handling of `search_trips`' renamed pickup/drop parameters is the owner's in-flight location work and was not touched. Still open from the plan: Phase 6 (insurance insert guard / audited admin verify), Phase 7 (driver/conductor privileges), and the later FK / cancellation items.
