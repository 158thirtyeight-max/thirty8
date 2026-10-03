# thirty8 payments, operator earnings and weekly settlement

Status: implemented and applied to the **dev** Supabase project (`xdrthrdwdfzhzhqkhnnf`). Not yet exercised against live
Razorpay or a real SBI file. See "Outstanding dependencies", "Known limitations" and the readiness checklist at the end.

## 1. How money flows

```
Customer pays (Razorpay Checkout)
  -> verify-payment asks RAZORPAY what was paid (amount, currency, order, status)      [fast path]
  -> razorpay-webhook (signed, raw body, idempotent) applies the same confirmation     [source of truth]
  -> orders/payments rows, booking confirmed, QR ticket, ledger: Dr razorpay_clearing / Cr booking_liability
Passenger boards (operator scans QR)
  -> boarding recorded once per ticket -> operator_earnings row becomes ELIGIBLE (commission rate frozen on the row)
  -> ledger: Dr booking_liability / Cr operator_payable + platform_commission
Weekly (Mon 12:00 IST by default; configurable) the scheduler builds DRAFT batches per operator
  -> a full admin approves (verified payout profile, bank details frozen), exports the SBI file, uploads it to SBI CINB
  -> a SECOND full admin imports the bank result: preview -> confirm; matched rows with a UTR mark the batch PAID
  -> ledger: Dr operator_payable / Cr settlement_bank (+ Cr operator_receivable for recoveries netted)
Refunds: cancellation only REQUESTS one -> admin reviews the policy calculation -> approves -> executes
  -> Razorpay refund -> completed ONLY when Razorpay reports it processed (webhook or verified read)
```

Boarding decides **eligibility**; the weekly settlement decides **payout**. They are separate states
(`operator_earnings.status`: pending_boarding -> eligible -> in_batch -> settled; side states on_hold, void, clawed_back).

## 2. What was built (gates)

| Gate | Result | Migration(s) | Tests |
|---|---|---|---|
| A payment integrity | provider-verified amounts, idempotent confirmation, duplicate-capture handling, retry-safe failures, refund lifecycle, webhook registry, exception queue | `20261003000200`, `000300` | `payments_gateA.sql`, `edge/razorpay.test.mjs` |
| B ledger | append-only double-entry, unique source-event keys, reversal journals | `000400` | `payments_gateB.sql` |
| C earnings | per-ticket earnings, frozen commission (floor, bps), boarding eligibility, clawback + recoveries | `000500` | `payments_gateC.sql` |
| C2 refund policy | admin-managed policies (no seeded rates), booking snapshot, server-side calculation, override, allocation | `000600` | `payments_gateC2.sql` |
| D settlement engine | weekly drafts, approval, frozen beneficiary, holds, netting, scheduler | `000700` | `payments_gateD.sql` |
| E SBI export/import | immutable payment file, preview/confirm bank result, UTR uniqueness, maker-checker, reconciliation | `000800` | `payments_gateE.sql` |
| F admin + Flutter | Finance & Settlements pages, refund management, customer pay-resume / refund status, operator payouts view | `000900`, `001000` | `payments_gateF.sql`, Dart + admin lib tests |
| G notifications + providers | financial notifications, Razorpay settlement booking, provider reconciliation, disabled Route/RazorpayX modules | `001100` | `payments_gateG.sql`, `edge/provider.test.mjs` |

Each migration has a rollback in `supabase/rollbacks/`.

## 3. Edge Functions (`supabase/functions`)

| Function | verify_jwt | Purpose |
|---|---|---|
| `create-order` | yes | Razorpay order for an owned order |
| `verify-payment` | yes | checks signature, fetches the payment from Razorpay, confirms idempotently; captures an authorized payment only when amount/currency match |
| `razorpay-webhook` | **no** (HMAC of raw body) | `payment.captured`, `payment.failed`, `refund.processed`, `refund.failed`; each event claimed once |
| `refund` | yes (full admin inside) | executes an **approved** refund; asks Razorpay first whether it exists; completes only on provider `processed` |
| `reconcile-payments` | **no** (internal secret or full admin) | nightly comparison with Razorpay payments/refunds; reports exceptions only |
| `send-notification` | **no** (internal secret) | push delivery; `push_only` when the database already wrote the in-app row |
| `operator-onboard`, `process-settlement`, `reverse-operator-transfer`, `reconcile-transfers` | yes (full admin) | provider payout modules, **disabled**: answer `blocked_provider_not_configured`; never call a provider or invent a transfer id |

Most financial logic is SQL RPCs (`admin_*`, `get_*`), the existing codebase pattern; edge functions exist only where a provider call or secret is needed.
Spec names map as: create-payment-order = `create-order`; process-refund = `refund`; verify-boarding = `verify_ticket_qr` /
`confirm_boarding`; calculate-operator-earning = trigger on boarding; build-weekly-settlement = `admin_build_weekly_settlement` + cron;
approve-settlement = `admin_approve_settlement`; get-operator-earnings = `get_operator_earnings_breakdown`.

## 4. Security model

* Razorpay key secret, webhook secret and service role never reach any app. Secrets live in `private.app_secrets` (read by `get_app_secret`, service role only).
* Every money-moving RPC checks `private.is_full_admin()` **inside the database**. Platform *support* can read, not act. Operators and customers have no path to refunds, policies, commission, approvals, exports or payouts (tested at RPC level).
* Ledger rows cannot be updated/deleted/truncated; only `private.post_journal` writes; each business event posts once (`source_event_key`).
* Settlement files and bank beneficiaries (full account numbers) are not readable by any client role; admins see masked values.
* Maker-checker (`settlement_maker_checker`, default on): the admin who approved a batch cannot confirm its payment.
* Notification text never contains amounts or bank details.

## 5. Configuration

### Secrets (`private.app_secrets`) — template, no values

| key | needed for |
|---|---|
| `razorpay_key_id`, `razorpay_key_secret` | orders, payment fetch/capture, refunds, reconciliation |
| `razorpay_webhook_secret` | webhook signature verification |
| `internal_dispatch_secret`, `functions_base_url` | DB -> edge function calls (notifications, nightly reconciliation); already present |
| `fcm_service_account_json` | push (optional; in-app notifications work without it) |
| `qr_hmac_key`, `id_doc_key` | existing ticket QR / passenger document encryption |
| `razorpayx_account_number` | **future**, RazorpayX payouts only |

Insert/rotate with `insert into private.app_secrets (key, value) values (...) on conflict (key) do update set value = excluded.value;` from the SQL editor (never from a client).

### Settings (`platform_settings`, change with `admin_set_platform_setting`; full admin; validated)

`settlement_timezone` (Asia/Kolkata), `settlement_week_start_dow` (1), `settlement_run_dow` (1), `settlement_run_hour` (12),
`settlement_recovery_cap_bps` (10000), `settlement_provider` (`manual_sbi`; others refused), `settlement_maker_checker` (true),
`razorpay_route_enabled` (false; cannot be enabled), `settlement_export_template` (SBI file layout, **unconfirmed**).

### Not configured by default (admin must create)
Commission rates (`/finance/commission`), refund policies (`/finance/refund-policies`), operator payout verification (`/finance/payout-profiles`).
There are deliberately **no built-in percentages**.

## 6. Razorpay dashboard checklist

1. Test mode first. Generate API keys; store as secrets above.
2. Webhook: `https://xdrthrdwdfzhzhqkhnnf.supabase.co/functions/v1/razorpay-webhook`, secret = `razorpay_webhook_secret`, events `payment.captured`, `payment.failed`, `refund.processed`, `refund.failed`.
3. Payment capture: keep auto-capture on (verify-payment also captures an authorized payment whose amount/currency match the order).
4. Settlement: note the settlement schedule/bank account; record each Razorpay settlement in Finance > Ledger (`admin_record_provider_settlement`).
5. Refund speed/notes: refunds carry our refund id in `notes.refund_id`; do not issue refunds from the dashboard (an unknown refund becomes an exception).
6. Route / RazorpayX are NOT used. If wanted later: apply for approval, then build the integration (modules are stubs).
7. Before live: repeat everything with live keys on a *separate, intentional* step; do not reuse test webhooks.

## 7. Deployment sequence

1. Back up the database. Apply migrations in order (`20261003000200` ... `001100`) after the SQL suite is green (`cd supabase/tests/harness && node run.mjs ../..`).
2. Deploy edge functions: `verify-payment`, `razorpay-webhook`, `refund`, `send-notification`, `reconcile-payments`, the four provider stubs (flags in `supabase/config.toml`).
3. Set secrets; configure the Razorpay webhook; send a test event.
4. Deploy the admin web (`apps/admin_web`: `npm run build`); sign in as a **full admin** (`platform_admin`).
5. In the admin: create commission, refund policies; verify operator payout profiles; confirm `settlement_*` settings.
6. Release the Flutter apps (customer: payment resume + refund status; operator: Payouts & notifications).
7. Dry run in test mode: pay -> board -> build batch -> approve -> export -> upload a hand-made result CSV -> confirm -> refund path. Reconcile.
8. Only then consider live keys.

## 8. Weekly runbook (manual SBI)

1. Mon 12:00 IST drafts appear (Finance > Weekly settlements). Review; hold or cancel anything odd.
2. Admin A approves each batch (profile verified, no refund pending). 3. Admin A exports the SBI file (download is audited).
4. Upload to SBI CINB yourself. 5. When SBI returns the result, Admin B uploads it (Bank results), checks the preview, confirms.
6. Exceptions (wrong amount/account/UTR) go to Reconciliation; nothing is forced to match. Failed rows: release the batch and rebuild.
7. Record Razorpay settlements in Ledger when they arrive.

## 9. Tests (as of the last run)

* SQL (PGlite, `supabase/tests/harness`): 36 files, 35 pass. The one failure, `operator_booking_analytics.sql` check 3f, depends on the time of day (it expects a booking "3 days before" a trip fixed to `current_date + 2 06:00`) and fails by clock, not by these changes.
* Edge pure logic: `node --test supabase/tests/edge/*.test.mjs` — 24 pass.
* Admin helpers: `npm run test:lib` in `apps/admin_web` — 9 pass; `tsc`, ESLint (1 pre-existing error in `locations/column-toggle.tsx`) and `next build` pass.
* Flutter: customer 28 pass; operator 268 pass.
* **Not covered**: real concurrency (two sessions), Deno runtime of the edge functions (no Deno installed), live Razorpay, a real SBI file, the admin/Flutter screens in a running UI.

## 10. Outstanding dependencies

* **SBI bulk-upload file layout** and beneficiary-registration rules: the export template is generic and flagged `confirmed: false`.
* Razorpay account: API keys, webhook secret, confirmed auto-capture; **Route / RazorpayX approval** only if automated payouts are wanted.
* Refund policy and commission values, and the operator recovery cap, agreed with operators (and reflected in terms).
* Operator bank-detail verification procedure (no penny-drop available without a provider).
* FCM setup and device-token registration in both apps (in-app notifications work now; push does not).

## 11. Known limitations

* Concurrency safeguards (advisory lock + `FOR UPDATE SKIP LOCKED`, unique period index) are reviewed but only single-session tested; test two simultaneous builds on a real branch.
* Commission is fully reversed on cancellation; the platform keeps only the cancellation deduction (as `cancellation_income`). Keeping commission on cancellations needs a policy change.
* Partial refunds are supported at payment level; a refund covers a whole booking (all its tickets), and operator-facing per-ticket figures are pro-rata.
* Cargo refunds use the same lifecycle but have no booking snapshot: an admin must choose a policy or override.
* `settlement_bank` shows payouts out; inflow appears only when Razorpay settlements are recorded manually.
* Provider reconciliation compares recent payments/refunds (3-day window), not Razorpay's settlement report line by line.
* No offline boarding queue (not present in the current app); boarding needs connectivity.
* Web checkout is not available (mobile only), unchanged.
* The old manual `admin_update_settlement` is disabled on purpose; a batch is paid only through a bank result (or explicit zero-net netting).

## 12. Production-readiness checklist

- [ ] Backup taken; migrations applied in order; rollbacks reviewed
- [ ] Secrets set; webhook configured and a signed test event processed once and ignored on repeat
- [ ] Test-mode end to end: payment, failed payment then retry, duplicate webhook, refund (requested -> approved -> executed -> processed), cancellation after boarding
- [ ] Commission and refund policies created and reviewed; operator payout profiles verified
- [ ] Two full admins exist (maker-checker) and know the runbook
- [ ] SBI file layout confirmed with SBI; one real small batch paid and reconciled
- [ ] Nightly jobs visible in `cron.job`: `build-weekly-settlements`, `daily-reconciliation`, `detect-captured-unconfirmed`, `provider-reconciliation`, plus the existing seat/booking jobs
- [ ] Reconciliation shows no open critical exceptions for 7 days
- [ ] Concurrency test of the weekly build on a Supabase branch
- [ ] Supabase advisors (security/performance) reviewed after the last migration
- [ ] Flutter builds installed on devices: pay-resume, QR tickets, refund status, operator Payouts and notifications
- [ ] Support runbook for "paid but no ticket" (look at Reconciliation, `captured_not_applied`, refund requests)
