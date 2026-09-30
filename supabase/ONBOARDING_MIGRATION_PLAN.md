# Operator Onboarding & Bus Activation — Migration Plan

Phase 1 deliverable: schema analysis and the ordered, additive migration plan. Migrations are written as files only (`supabase db push` is run by the maintainer). Nothing here is applied to the live project by the assistant.

## 1. Existing structures reused (not duplicated)

| Concern | Existing | Decision |
|---|---|---|
| Operator | `operators` (`status` enum pending/approved/rejected/suspended) | Keep. Add `application_status` + review columns. `status` stays the customer-facing gate, kept in sync by RPCs. |
| Roles | `user_roles`, `private.is_platform_admin/is_operator_staff/is_operator_admin` | Reuse unchanged. |
| Registration | `public.register_operator(...)` | Keep as step 1 entry point. |
| Bus | `buses` | Extend columns. `status` (active/maintenance/inactive) untouched. |
| Seat layout | `bus_layouts` + `seats` (already per bus) | Extend `seats` with `kind`, `berth`. |
| Route/stops | `bus_routes`, `boarding_points`, `dropping_points` | Extend points with time offsets. |
| Service | `bus_services` (bus + route + departure) | Extend with schedule columns; per-bus anchor. |
| Fares | `fare_rules`, `trip_seats.fare_cents` | Extend `fare_rules`; add fare engine. |
| Insurance | `operator_insurance` | Untouched; backfilled into `bus_documents`. |
| Audit | `audit_logs` (unused) | Start writing via `private.write_audit()`. |
| Storage | first-folder-segment ownership pattern | Reuse pattern for new private buckets. |

## 2. Known problems this fixes
- `operators_update_own` lets an operator_admin change `status/approved_by/approved_at` (self-approval). Fix: guard trigger.
- `buses_operator_manage` (`for all`) lets any operator staff insert buses directly. Fix: no insert policy; `create_bus` RPC (approved operators only) + before-insert trigger.
- Fare math is split: `search_trips` uses `bus_trips.min/max_fare_cents`; seat map/hold/booking use trip-wide `trip_seats.fare_cents`; `create_booking` ignores boarding/dropping points. Fix: single `private.calc_seat_fare` engine.
- Public `using (true)` on services/trips/routes: customer visibility must be gated in search/hold/booking functions.

## 3. Migrations as built (`supabase/migrations/`, prefix `20260926`)

| File | Phase | Contents |
|---|---|---|
| `..000100_onboarding_foundation.sql` | 2 | `application_status`, operator review columns + backfill, `private.write_audit`, operator guard trigger, profile/KYC/documents/`document_requirements`, `operator-documents` bucket, `operator_completeness()` |
| `..000200_operator_bank_mandate.sql` | 3 | bank details (format CHECKs), payment mandate, requirement `step`, completeness incl. bank + mandate |
| `..000300_operator_approval_workflow.sql` | 4 | `submit_operator_application`, `admin_review_operator`, `admin_review_operator_document`, `admin_review_mandate`, audit |
| `..000400_bus_lifecycle_and_create.sql` | 5 | `bus_lifecycle`, bus columns, **legacy flag/backfill**, `bus_verification_state`, **approved-only `create_bus`**, insert/update guards |
| `..000500_bus_documents.sql` | 6 | `bus_documents`, expiry view, `bus-documents` bucket, bus requirements, `admin_review_bus_document` |
| `..000600_seat_layout.sql` | 7 | seat kind/berth, `validate_bus_layout`, `save_bus_layout`, layout write lockdown |
| `..000700_route_stops.sql` | 8 | per-bus routes, stop timing, `validate_bus_route`, `save_bus_route` |
| `..000800_fare_engine.sql` | 9 | fare rules/charges, **`resolve_seat_fare` engine**, `search_trips` / `get_trip_seat_map` / `create_seat_hold` / `create_booking` rewired, bookability gate, `save_bus_fares` |
| `..000900_schedule.sql` | 10 | booking window/cut-offs, `save_bus_schedule`, `generate_bus_trips` |
| `..001000_bus_approval_activation.sql` | 11 | `bus_completeness`, `submit_bus`, `admin_review_bus`, `activate_bus`, `deactivate_bus`, legacy migration status |
| `..001100_admin_support.sql` | 12 | audit index for the bus activity timeline |

Tests: `supabase/tests/` (see its README), runnable without Supabase via `supabase/tests/harness`.

## 4. Backfills / backward compatibility
- Operators: `approved`→`application_status='approved'`, `pending`→`submitted`, `rejected`→`rejected`, `suspended`→`approved` (status stays suspended). Both live operators are approved; they are not forced to re-enter data.
- Buses: all existing rows `is_legacy=true`, `lifecycle_status='active'` (still bookable), never stamped as approved/verified; surfaced as **Legacy/Unmigrated**; admin migration queue clears the flag on review.
- Existing seats default `kind='bookable'`. Existing `fare_rules` rows have null point columns = base fare (unchanged pricing). Null boarding/dropping args on hold/seat-map keep current behavior.
- Live DB has one applied migration not in the repo (`fix_set_updated_at_search_path`); new files use later timestamps and do not conflict.

## 5. Security model
- All state transitions via SECURITY DEFINER RPCs (`search_path=''`), role-checked, each writing `audit_logs`.
- Guard triggers block non-admin edits to status/lifecycle/review columns.
- Operator-owned tables: staff select/update only while draft/changes_requested; admin full access.
- Documents in private buckets, signed URLs only; operators restricted to their own operator_id/bus folders.
- `platform_support` passes `is_platform_admin()` today; behavior preserved.
