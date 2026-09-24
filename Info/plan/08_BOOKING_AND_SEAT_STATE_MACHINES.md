# 08 — Booking, Seat & Payment State Machines

## Seat state machine

```text
AVAILABLE
   │
   ├── hold ───────► HELD
   │                   │
   │                   ├── payment/booking success ─► BOOKED
   │                   ├── release ----------------► AVAILABLE
   │                   └── expiry -----------------► AVAILABLE
   │
   ├── operator block ─► BLOCKED
   └── maintenance ----► BLOCKED

BOOKED
  ├── cancelled policy allows ─► CANCELLED
  └── successful boarding -----► BOARDED
```

## Booking state machine

```text
DRAFT
  ↓
HOLD_CREATED
  ↓
ORDER_CREATED
  ↓
PAYMENT_PENDING
  ├── PAYMENT_FAILED ─────► FAILED
  ├── PAYMENT_EXPIRED ────► EXPIRED
  └── PAYMENT_CAPTURED ───► CONFIRMING
                               ↓
                          CONFIRMED
                          /        \
                 CANCEL_REQUESTED  TRAVELLED
                         ↓
                     CANCELLED
                         ↓
                  REFUND_PENDING
                         ↓
                    REFUNDED
```

## Payment rules

- Never confirm a booking solely because the client says payment succeeded.
- Verify payment server-to-server through the payment provider webhook/API.
- Use an idempotency key for payment callbacks.
- If payment succeeds after a client timeout, the backend still resolves the booking deterministically.
- If a confirmed booking cannot be created after capture, create a reconciliation task rather than silently losing money.

## Seat concurrency algorithm

1. Begin DB transaction.
2. Select requested `trip_seats` rows `FOR UPDATE`.
3. Verify all are `AVAILABLE` or recoverably expired `HELD`.
4. Create/update `seat_holds`.
5. Mark seats `HELD` and attach hold id.
6. Commit.
7. Return hold token + expiry.

During order confirmation:

1. Begin transaction.
2. Lock the hold + seat rows.
3. Validate hold ownership and expiry.
4. Create booking/order records.
5. Convert `HELD → BOOKED`.
6. Clear hold linkage.
7. Commit.

## Never do this

Do not trust:

- seat state stored only in Flutter
- a cached seat map
- client-side countdown alone
- client-supplied total price
- client-generated booking status
- operator UI as the final authority

The backend is the authority.
