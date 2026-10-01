# thirty8 — Bus Operations Ecosystem Audit

Read-only audit. No code, schema, RLS, storage or data was changed.

**Label legend (maps to CONFIRMED / POTENTIAL / UNVERIFIED):** CONFIRMED-LIVE and CONFIRMED-CODE = CONFIRMED defect or behaviour, with evidence. Where a confirmed schema/code gap was not exercised (no live data to trigger it, e.g. cross-tenant trip insert, insurance INSERT as verified), it is a POTENTIAL exploit of a CONFIRMED gap. UNVERIFIED = not checked.

**Evidence basis and honesty rules**
- Findings come from reading the repository (three read-only exploration passes: migrations/edge functions, admin web + operator app, customer app) plus the live-database checks recorded in `THIRTY8_DATABASE_INTEGRITY_REPORT.md`.
- Tags: **CONFIRMED-LIVE** = checked against the live Supabase project in this session. **CONFIRMED-CODE** = traced in repo code/migrations only. **UNVERIFIED** = reported by an exploration pass but not re-checked by a second read, or needs a runtime test.
- Nothing was executed end-to-end (no booking, payment, approval flow was run). "Works" below means "the code path is wired", not "tested".
- Repo-defined object counts were produced before the repo's last two migrations were counted (see Section 3); they are lower bounds and are superseded by the live counts.

---

## 1. Executive summary

- All three apps talk to **one Supabase project** (`xdrthrdwdfzhzhqkhnnf`, confirmed via `supabase/config.toml` and the connected MCP). The admin web uses server components/actions with the anon key plus the signed-in admin's cookies (no service-role key). Both Flutter apps use the anon key plus the user JWT. Shared state is the Postgres schema, 59 public RPCs and 6 edge functions.
- The **staged, RPC-driven path is well built**: operator onboarding, bus creation, layout, route, fares, schedule, submit/activate, admin review. Approval fields are protected by triggers (`protect_operator_workflow`, `guard_bus_update`, document/mandate protection triggers). The customer search/hold/booking RPCs all gate on `private.is_bus_bookable` (bus `status='active'` + `lifecycle_status='active'` + operator `approved`).
- The **weak points are the legacy direct-write paths and the payment/booking edge cases**, not the main flow:
  1. Legacy `FOR ALL` operator RLS policies on `bus_routes`, `boarding_points`, `dropping_points`, `bus_services`, `bus_trips`, `fare_rules`, `fare_charges` let operator staff change fares, routes, services and trips directly, bypassing the RPC guards and re-review (CONFIRMED-LIVE: policies exist, no approval trigger on these tables).
  2. `confirm_booking_after_payment` has no booking-status or amount check; `create_booking` can be called repeatedly on one hold (CONFIRMED-CODE; no unique constraint prevents it — CONFIRMED-LIVE).
  3. Hold TTL is client-supplied and uncapped; booking windows/cutoffs are stored but never enforced (CONFIRMED-CODE).
  4. Public `using(true)` SELECT on trips/services/fares/seats leaks unreleased inventory (CONFIRMED-LIVE).
- **Admin as central authority:** yes for operator and bus approval, document verification, route catalog and refunds. Not for post-approval fares/schedules/layouts/trips: admin has view-only screens there, and operators can still write those tables directly.
- Live data is tiny (2 operators, 2 buses, 7 trips, 0 bookings, 0 payments), so no live payment or booking behaviour has been exercised in production.

---

## 2. Architecture

```
 Admin Web (Next.js 16, server actions, anon key + admin cookie)
 Operator App (Flutter, supabase_flutter, Riverpod, go_router)        -> Supabase project xdrthrdwdfzhzhqkhnnf
 Customer App (Flutter, supabase_flutter, Razorpay SDK)                   |- Auth (email/password, Google OAuth)
                                                                           |- Postgres (public + private schemas, RLS)
 Direct table reads/writes (RLS)  -----------------------------------------|- 59 public RPCs (security definer)
 RPC calls  ---------------------------------------------------------------|- Storage (9 buckets) + Cloudflare R2 for bus photos
 Edge functions: create-order, verify-payment, razorpay-webhook, refund,    |- Edge functions (6)
                 send-notification, r2-presign                              |- pg_cron (3 jobs), pg_net
 Razorpay (orders, checkout, webhook, refunds) ; FCM (send-notification) ; Cloudflare R2 (r2-presign)
```

- Shared packages: `packages/design_system` (Dart, used by all Flutter apps) and `packages/shared_types` (generated `database.types.ts`, 2678 lines, consumed by admin only; **no Dart app uses it** — Flutter code uses raw `Map<String, dynamic>`).
- Config: Supabase URL + anon JWT are hardcoded in `apps/operator_app/lib/core/env.dart` and `apps/customer_app/lib/core/env.dart` (public key, RLS is the control). Admin uses `NEXT_PUBLIC_SUPABASE_URL`/`_ANON_KEY`/`NEXT_PUBLIC_R2_PUBLIC_URL`. `.env.local` of admin holds a Vercel CLI OIDC token; it is gitignored. No secret values are reproduced here.
- Same project/database/auth: CONFIRMED (one project ref, one `auth.users`, one `profiles`). Roles in `user_roles` (`platform_admin`, `platform_support`, `operator_admin`, `operator_staff`, `driver`, `conductor`, customer = no role row).

---

## 3. Database inventory

Live counts (CONFIRMED-LIVE, queried read-only 2026-10-01) vs repo:

| Item | Live | Repo (as counted) | Note |
|---|---|---|---|
| Supabase projects configured | 1 (ref in config.toml = MCP project) | 1 | |
| Custom schemas | `private` (+ `public`) | `private` | |
| Tables (public+private) | 57 (56 public + `private.app_secrets`) | 56 | Repo count excluded `pickup_drop_points` (migration 52). |
| Views | 4: `bus_document_expiry`, `main_locations`, `route_stops`, `service_stops` | 1 | 3 views from migration 52. |
| Functions | 59 public + 42 private | 57 + 41 | |
| Triggers (non-internal; public/private/storage/auth) | 45 | 35 | Scope of the two counts differs; not directly comparable. |
| Enums | 23 | 23 | |
| Foreign keys (public) | 106 | ~103 | |
| RLS policies | 145 public + 20 storage | 142 + 20 | |
| Indexes (public) | 209 | 118 created | Includes PK/unique indexes; not comparable. |
| Storage buckets | 9 | 9 | |
| Cron jobs | 3 | 3 | |
| Edge functions | 6 (ACTIVE) | 6 | `razorpay-webhook` and `send-notification` have `verify_jwt=false` live. |
| Migrations | 51 applied entries | **53 files** | Earlier pass reported 51 files; actual is 53. |

Migration reconciliation (by name, not timestamp) is in the integrity report. Summary: live versions use different timestamps than the repo filenames, names 1–51 match, and repo migrations `20261001000500_main_locations_and_points` and `20261001000600_location_routes_and_search` are **absent from the live history although their objects exist live** (applied outside tracked migrations).

### Bus-related tables

| Table | Purpose | PK | Key FKs | Used by | Status |
|---|---|---|---|---|---|
| operators | operator company; `status` + `application_status` | id | approved_by/reviewed_by → profiles | A,O,C(RPC) | in use; overlapping status fields |
| user_roles | role + operator scope | id | user_id→profiles, operator_id→operators | A,O | in use |
| operator_profiles / operator_kyc / operator_bank_details / operator_payment_mandates | onboarding data | operator_id | →operators (cascade) | A,O | in use, live rows 0 |
| operator_documents, document_requirements | uploads + configurable requirements | id | operator_id→operators | A,O | in use |
| operator_insurance | legacy insurance | id | operator_id→operators; bus_id/cargo_vehicle_id plain uuid (no FK) | A,O | legacy, overlaps bus_documents |
| buses | vehicle | id | operator_id→operators (cascade) | A,O,C(RPC) | in use; `status` + `lifecycle_status` overlap; 5 photo columns |
| bus_documents | vehicle docs | id | bus_id→buses | A,O | in use |
| bus_layouts / seats | layout + seat definitions | id | bus_id→buses; bus_layout_id→bus_layouts | A(view),O,C(RPC) | in use |
| bus_routes | per-bus/legacy route | id | operator_id, bus_id, source/dest cities | A,O | in use; overlaps route_templates |
| boarding_points / dropping_points | route stops | id | route_id→bus_routes (cascade), master_point_id→pickup_drop_points | A,O,C | in use |
| route_templates / route_template_stops | admin route catalog | id | cities | A,O | live rows 0 (unused so far) |
| main_locations (view) / pickup_drop_points | location master + points | id | main_location_id | A,C | new, live |
| bus_services | one service per bus (not enforced) | id | operator_id, route_id, bus_id | A,O | in use |
| bus_trips | dated trips | id | service_id (cascade), operator_id, route_id, bus_id | A(none),O,C | in use |
| fare_rules / fare_charges | fares / charges | id | service_id | A(view),O,C(RPC) | fare_charges rows 0 |
| trip_seats | per-trip seat inventory | id | trip_id, seat_id, hold_id | C(RPC) | in use, 252 rows |
| seat_holds | holds | id | trip_id, user_id, points | C(RPC) | in use |
| bookings / booking_items / passengers / booking_status_history | booking | id | booking_items → bookings/trip_seats/trips | A(list),C | in use, 0 rows |
| orders / payments / refunds / processed_webhook_events | payment | id | payments→orders, refunds→payments; orders.orderable_id no FK | A,C(edge) | in use, 0 rows |
| ratings_reviews | reviews | id | profile, operator, trip | C | in use |
| notifications, device_tokens, notification_templates/preferences | comms | id | | all | partly used |
| audit_logs | audit | id | | A | in use |
| boarding_events, bus_trip_events | scanning/trip events | id | | O | `bus_trip_events` unused (0 rows) |
| wallet, wallet_transactions | wallet | id | wallet.owner_id no FK | none | UNUSED (no app reference, no writer found) |

(A = admin, O = operator app, C = customer app.)

---

## 4. Admin control audit

Auth: `requirePlatformAdmin()` (RPC `am_i_platform_admin`) runs in the admin layout and every server action; pages themselves rely on layout gate + RLS (CONFIRMED-CODE).

| Function | Status |
|---|---|
| View all operators, KYC, bank, documents, insurance, buses, activity | Implemented (read) |
| Approve / reject / request changes / suspend / reinstate operator | Implemented via RPC `admin_review_operator` |
| Verify/reject operator document, payment mandate | Implemented via RPCs |
| Verify/reject insurance | Implemented as **direct table update, no audit entry** |
| Per-field KYC/bank verification | Not implemented (display only) |
| Bus approve/reject/suspend/reinstate, bus document verify | Implemented via RPCs |
| View layouts, routes, fares, schedule, readiness/completeness | Implemented (view only) |
| Edit/validate seat layout, fares, schedule | Not implemented (view only) |
| Routes catalog CRUD + assign route to bus | Implemented (`admin_save_route_template`, `admin_assign_route_to_bus`) |
| Locations / pickup points | Implemented (`locations` pages, new) — not deeply traced; UNVERIFIED |
| Trips page / trip generation view | **Not implemented** |
| Bookings | Read-only list; no detail/cancel |
| Refunds | Implemented (edge `refund`, admin re-check) |
| Users | Read-only; no role grant/ban |
| Audit logs | Viewer only, no filter/pagination |
| Platform settings | Only document requirements; no fees/commission/cancellation policy |

---

## 5. Operator app audit

All staged flows call RPCs (`register_operator`, `submit_operator_application`, `create_bus`, `save_bus_layout`, `save_bus_route`, `save_bus_fares`, `save_bus_schedule`, `generate_bus_trips`, `submit_bus`, `activate_bus`, `deactivate_bus`) — CONFIRMED-CODE, and every RPC name used exists live (CONFIRMED-LIVE).

- Registration, KYC, bank, mandate, documents, logo, insurance upload: implemented with direct table writes protected by triggers.
- Photos: `r2-presign` edge function + direct update of `buses.exterior_photo_keys/interior_photo_keys` (keys not validated server-side).
- Dashboard: reads `bus_trips`, `buses`, `cargo_shipments`. **No bookings list or revenue/payout view.**
- **Legacy "bus_ops" screens** (`route_form_screen`, `route_points_screen`, `service_form_screen`, `trip_form_screen`, `trip_detail_screen`) write directly to `bus_routes`, `boarding_points`, `dropping_points`, `bus_services`, `bus_trips`, bypassing the staged RPCs.
- Role differences (admin vs staff vs driver) are not enforced in the UI; RPCs accept any `is_operator_staff` (includes driver/conductor).

---

## 6. Customer app audit

Journey (CONFIRMED-CODE): `search_cities` → `search_trips` → `get_trip_seat_map` → `create_seat_hold` → `create_booking` → edge `create-order` → Razorpay → edge `verify-payment` → `confirm_booking_after_payment` → `generate_ticket_qr`.

- Fares are computed server-side (`resolve_seat_fare`/`calc_seat_fare`); the client only sums server values. Payment amount is read from `orders` by the edge function, not from the client.
- `search_trips`, `get_trip_seat_map`, `create_seat_hold`, `create_booking` all gate on `is_bus_bookable`.
- Gaps: no trip-status/departure check in seat map/hold/booking; seat grid ignores deck/layout and hardcodes an aisle after seat 2; no realtime or polling; web payment unimplemented; payment retry path crashes (`key_id` missing from early-return); connected itineraries cannot be booked; cancellation always refunds 100% and does not refresh `available_seats`; ratings do not check the rater travelled.
- Live signature drift: the app calls `search_trips` with 3 params; live function has 5 (two default to NULL), so the call still works (CONFIRMED-LIVE signature; call compatibility is by default values, UNVERIFIED at runtime). The app does not pass pickup/drop point ids even though `get_journey_points`/`pickup_drop_points` exist.

---

## 7. Three-application connectivity matrix

| Feature | Admin | Operator | Customer | Shared backend | Connectivity |
|---|---|---|---|---|---|
| Operator approval | RPC `admin_review_operator` | submits via RPC, sees status | n/a | `operators`, trigger-protected | Connected, enforced by DB |
| Bus registration | review only | `create_bus` | n/a | `buses`, `guard_bus_*` | Connected |
| Bus documents | verify via RPC | upload (storage + table) | n/a | `bus_documents`, storage | Connected; path ownership only checked for bus docs |
| Seat layout | view | `save_bus_layout` RPC | seat map RPC (ignores layout geometry) | `bus_layouts`,`seats`,`trip_seats` | Connected; customer rendering simplified |
| Route | catalog CRUD + assign | `save_bus_route` + legacy direct writes | via search RPC | `bus_routes`, points, `route_templates` | Connected; legacy bypass; catalog not enforced |
| Fare | view | `save_bus_fares` + legacy direct writes | server fare engine | `fare_rules`,`fare_charges` | Connected; post-approval direct edits possible |
| Schedule | view | `save_bus_schedule` + direct writes | search | `bus_services` | Connected; cutoffs not enforced |
| Trip generation | none | `generate_bus_trips` (+ direct inserts) | search/seat map | `bus_trips`,`trip_seats` | Connected; no admin visibility |
| Seat availability | none | none | RPC + hold | `trip_seats`,`seat_holds` | Server-synced at load; no realtime |
| Booking | list only | none (manifest/QR only) | RPCs | `bookings`,`booking_items` | Operator cannot list bookings |
| Payment | revenue/refunds | none | Razorpay + edges | `orders`,`payments` | Connected; confirm lacks guards |
| Cancellation | none | none | `cancel_booking` | `bookings`,`refunds` | Customer-only; full refund |

---

## 8. Permission and security audit

CONFIRMED-LIVE unless stated.

- **Self-approval:** blocked. Triggers `protect_operator_workflow`, `guard_bus_insert/update`, `protect_operator_document_review`, `protect_mandate_review`, `protect_bus_document_review` exist live. `operator_insurance` is guarded only on UPDATE (`protect_insurance_verification`); the live policy `operator_insurance_operator_manage` is `FOR ALL` for staff, so an INSERT with `status='verified'` is not blocked by the trigger as described (CONFIRMED-CODE on trigger scope; not exercised).
- **Legacy direct-write policies** (`*_operator_manage`, `FOR ALL`, `is_operator_staff(operator_id)` only) on `bus_routes`, `bus_services`, `bus_trips`, plus join-based ones on points, `fare_rules`, `fare_charges`: no approval/lifecycle check, no ownership check of `bus_id`/`service_id` against `operator_id` on `bus_trips`. A cross-tenant trip insert is therefore permitted by policy (the trigger `generate_trip_seats` would then build seats) — not exercised.
- **Anon policies calling private helpers:** `operators_select_public`, `bus_layouts_select_public`, `cargo_vehicles_select_public` reference `private.is_operator_staff`; anon has no EXECUTE or schema USAGE. Tested live: anon `SELECT` on `operators` and `bus_layouts` fails with `42501 permission denied for function is_operator_staff`. Customer RPCs are security definer so they are unaffected.
- **Public reads:** `bus_trips`, `bus_services`, `bus_routes`, points, `fare_rules`, `fare_charges`, `trip_seats` are `using(true)` for anon (includes live location columns and unreleased/unapproved bus data).
- **Role scoping:** `activate_bus`, `deactivate_bus`, `submit_bus`, `save_bus_*`, `generate_bus_trips` accept any staff role including driver/conductor (CONFIRMED-CODE). Bank/KYC readable by all staff roles (CONFIRMED-CODE).
- **Security advisors (live):** 6 anon-executable SECURITY DEFINER functions, 53 authenticated-executable (expected for RPC API, but includes `rls_auto_enable()` — present live, **not found in the repo**), leaked-password protection disabled, `processed_webhook_events` has RLS and no policy (intended service-role only). `private.app_secrets` has RLS off but `private` is not API-exposed and anon lacks USAGE (CONFIRMED-LIVE); still worth enabling RLS.
- **Storage:** public buckets `bus-photos`, `operator-logos`, `user-avatars` have no size/MIME limits; `insurance-documents`, `cargo-proofs`, `receipts`, `ticket-pdfs` have no limits; R2 presign signs with no size cap (CONFIRMED-CODE).
- **Payments (CONFIRMED-CODE):** webhook records events even when the handler fails (no retry); `refund` edge function is not serialised (double-refund risk); `send-notification` compares a shared secret with `!==`.

---

## 9. Lifecycle audit

| Stage | Implemented by | Gap |
|---|---|---|
| Operator registration/approval | `register_operator`, `admin_review_operator` | no separation of duties; `platform_support` can approve |
| Add bus / documents / capacity / layout / route / fare / schedule | staged RPCs | legacy direct writes bypass |
| Submit / admin review / approval / activation | `submit_bus`, `admin_review_bus`, `activate_bus` | operator self-activates after approval; any staff role |
| Customer search/seat/booking/payment/ticket | RPCs + edge functions | see Section 6, 10 |

Event handling: operator suspended — `is_bus_bookable` excludes it from search/hold/booking, but existing bookings/trips are untouched and no cancellation workflow exists. Bus suspended — same. Document expired — view reports it but `is_bus_bookable` does not check expiry. Route/fare changed after approval — direct edits possible via legacy policies; no re-review. Schedule cancelled — there is no trip-cancel RPC; setting `bus_trips.status='cancelled'` does not refund or notify. Layout modified after trips exist — `save_bus_layout` is status-locked; effect on already generated `trip_seats` UNVERIFIED.

---

## 10. Findings

### Critical
- **C1 (CONFIRMED-LIVE, function source read)** `confirm_booking_after_payment` checks only order status; no booking status, no amount match. Late payment after the 30-min expiry can force released seats to `booked` (oversell). Webhook swallows handler errors and still marks the event processed (`razorpay-webhook/index.ts`).
- **C2 (CONFIRMED-LIVE, function source read + indexes)** `create_booking` does not mark the hold consumed or check for an existing booking; unique index is only `(booking_id, trip_seat_id)`. Repeated calls with one hold token create multiple bookings/orders for the same `trip_seat_id`.
- **C3 (CONFIRMED-LIVE policies)** Legacy operator `FOR ALL` policies bypass approval and lifecycle locks for routes, services, trips, fares; cross-tenant `bus_trips` rows are not prevented.
- **C4 (CONFIRMED-CODE)** Migration `20260926000400` sets all pre-existing buses `is_legacy=true`, `lifecycle_status='active'` without review. Live: 1 such bus (`AN01-DEMO-0001`). Demo seed data is shipped as migrations (`20260924000100`, `…000400`).

### High
- **H1 (CONFIRMED-LIVE, function source pattern check)** `create_seat_hold` takes `p_ttl_seconds` from the client with no cap, no per-user limit.
- **H2 (CONFIRMED-LIVE for create_seat_hold; CONFIRMED-CODE for others)** `booking_open_at`, `booking_close_at`, `booking_cutoff_min`, `boarding_cutoff_min` never enforced; no trip-status/departure check in seat map, hold or booking; `roll_trip_status` is hourly.
- **H3 (CONFIRMED-LIVE trigger definition)** `protect_insurance_verification` is BEFORE UPDATE only; staff INSERT with a verified status is not blocked by it (insert not exercised; check constraints not inspected).
- **H4 (CONFIRMED-CODE)** Driver/conductor can activate buses, save fares, generate trips, read bank details.
- **H5 (CONFIRMED-CODE)** Cancellation: always 100% refund, allowed after departure, no policy; `available_seats` not recomputed; no trip-cancel flow.
- **H6 (CONFIRMED-LIVE)** Public `using(true)` reads expose unapproved/unreleased inventory and live location.
- **H7 (CONFIRMED-LIVE)** Anon policies on `operators`, `bus_layouts`, `cargo_vehicles` raise permission errors for anon.
- **H8 (CONFIRMED-CODE)** Document expiry does not unlist a bus; refund edge function is not serialised; `verify-payment` does not query Razorpay for status.
- **H9 (CONFIRMED-LIVE)** Two repo migrations are missing from live migration history while their objects exist live; `public.rls_auto_enable()` exists live but not in the repo.

### Medium
- **M1** Seat grid ignores layout/deck; no realtime; holds not released on back-out. (CONFIRMED-CODE)
- **M2** Web payment unimplemented; payment retry crash (`key_id` null). (CONFIRMED-CODE)
- **M3** Connected itineraries unbookable; fare can silently resolve to 0 (`coalesce(...,0)`); passenger-to-seat mapping is arbitrary (`row_number() over (order by ts.id)`); `gender_restriction` unenforced. (CONFIRMED-CODE)
- **M4** Admin lacks trips page, layout/fare/schedule edit, KYC/bank field verification, role management, audit-log filtering. (CONFIRMED-CODE)
- **M5** Operator has no bookings list or payout view. (CONFIRMED-CODE)
- **M6** No uniqueness on `bus_services.bus_id`; `bus_trips.operator_id` redundant and unvalidated; `orders.orderable_id`, `wallet.owner_id`, `operator_insurance.bus_id/cargo_vehicle_id` have no FK. (CONFIRMED-LIVE)
- **M7** `ratings_reviews` can be written for any trip. (CONFIRMED-CODE)
- **M8** Live-location columns writable by any staff (`update_bus_location` does not check `live_tracking_enabled`, driver assignment or coordinates). (CONFIRMED-CODE)

### Low
- Overlapping status columns (`operators.status`/`application_status`, `buses.status`/`lifecycle_status`); five photo columns; unused `wallet*`, `bus_trip_events`; `bus_trips.min/max_fare_cents` never written by generation (live rows currently non-null for all 7 trips); stale `functions/README.md`; Flutter raw maps vs `shared_types`; hardcoded `₹` and Supabase config; `custom_access_token_hook` defined, registration in `config.toml` not found (UNVERIFIED live).

### Suspected / needs runtime test
- Whether anon-facing customer flows depend on direct reads of `operators`/`bus_layouts` (none found in the app code reviewed).
- Whether `roll_trip_status` moves same-day departed trips out of `scheduled`.
- Effect of layout edits on generated `trip_seats`.

---

## 11. Missing functionality

Admin: trips view, layout/fare/schedule edit, field-level KYC/bank verification, role management, booking detail/cancel, platform settings (fees, cancellation policy), audit-log filters. Operator: bookings list, payouts/revenue, per-role UI, push for review outcomes. Customer: web payment, connected itinerary booking, deck-aware seat map, cancellation policy, e-ticket PDF. Backend: trip-cancel RPC, hold/booking idempotency, cutoff enforcement, document-expiry gating.

## 12. Existing working functionality (code-traced, not executed)

Operator onboarding and approval RPC workflow; staged bus setup; admin review of operators/buses/documents; route catalog CRUD and assignment; customer search → seat map → hold → booking → Razorpay order/verify wiring; server-side fare engine; QR ticket generation/verification; cargo flows (not audited in depth).

## 13. Technical debt

Dual status models, dual route models (per-bus `bus_routes` vs `route_templates`), insurance duplicated across `operator_insurance` and `bus_documents`, migration history drift, hardcoded config, no Dart models, tests cover onboarding/fare engine only (11 SQL files + harness; none for payment confirmation, hold reuse, direct-write RLS bypass or anon policies).

## 14. Roadmap (summary; detailed sequence in the integrity report)

1. Payment/booking integrity (C1, C2, H1, H2, H8). 2. Close legacy write paths and public reads (C3, H6, H7, H4, H3). 3. Reconcile migration history and live-only objects (H9). 4. Admin controls for trips/fares/layouts (M4). 5. Customer/operator gaps (M1–M5). 6. Cleanup of duplicates (Low).

---

## 15. Answers

- **Is the Admin Panel the actual central control authority?** Partly. It is authoritative for operator/bus approval and document verification (DB-enforced). It is not authoritative for post-approval routes, fares, schedules and trips because operators can write those directly (C3) and admin has no editing UI for them.
- **Can the admin manage every important bus operation?** No: no trips, no layout/fare/schedule management, limited settings and user management.
- **Can operators independently manage their own fleet?** Yes via the staged RPC flow (code-traced).
- **Are all three apps using the correct shared data?** Yes at the table/RPC level: every table and RPC referenced by the apps exists live. Exceptions: customer app has not adopted the new point-aware `search_trips` parameters; Flutter models are untyped.
- **Does the customer app display live, accurate bus information?** Mostly, via RPCs; seat map is point-in-time (no realtime) and ignores layout geometry; same-day departed trips may still be listed (UNVERIFIED).
- **Is seat availability synchronized?** Server-side locking with `FOR UPDATE` protects double-holds; the client view can be stale; booking-from-expired-payment can oversell (C1).
- **Is fare calculation consistent?** Yes server-side, with a `fare_changed` check when points are supplied; can fall back to 0 and skips drift check when no points.
- **Are approval and activation enforced by the backend?** For the RPC path yes (`is_bus_bookable`, guard triggers). Bypassable through legacy direct-write policies and legacy buses.
- **Before the module is functionally complete:** fix C1–C4 and H1–H9, add admin management of trips/fares/layouts, add operator bookings view, add tests for payment confirmation, hold reuse, RLS bypass and anon policies.
