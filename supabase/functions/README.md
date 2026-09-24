# Edge Functions

Not yet implemented — built in Phases 3–6 of the build plan:

- Phase 3: bus search/seat-map/hold/booking/manifest/QR endpoints
- Phase 4: cargo shipment CRUD, status/GPS updates, pickup/delivery proof
- Phase 5: Razorpay `create-order`, `verify-payment`, `handle-webhook`, refund
- Phase 6: FCM notification dispatch

Most of the actual business logic already lives in Postgres functions
(`supabase/migrations/20260923001300_booking_and_cargo_functions.sql`) —
these Edge Functions are thin HTTP wrappers plus the Razorpay/FCM
integration code that has no reason to live in the database.
