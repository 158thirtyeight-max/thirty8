# 03 — Customer UI & Workflow Inventory

## Rule

The reference client exposes hundreds of UI resources. Build the inventory by grouping them into product journeys rather than mechanically copying filenames.

## Journey A — App startup / onboarding

1. Splash / app initialization
2. Configuration / update checks
3. Location or permission prompts where applicable
4. Login / skip-login decision
5. Phone entry
6. OTP entry
7. OTP retry / alternative verification
8. Account suspension/error state
9. Referral entry where applicable

## Journey B — Search

1. Home
2. Source city/location picker
3. Destination city/location picker
4. Travel date selector / calendar
5. Search submission
6. Search result loading
7. Search result list
8. Alternate dates/routes
9. Filters
10. Sort
11. Search empty/error/oops states

## Journey C — Select service

1. Bus/service card
2. Price/fare visibility
3. ratings/reviews
4. amenities
5. operator/service metadata
6. cancellation policy
7. boarding and dropping points
8. bus photos/gallery where available
9. seat layout/details
10. feature/promotion cards

## Journey D — Seat selection and lock

1. Seat map load
2. Seat legend
3. Available / selected / booked / blocked / gender-specific states
4. Multi-seat selection
5. Fare update
6. Temporary seat hold/lock
7. Countdown timer
8. Continue/pay action
9. Lock timeout
10. Seat release

## Journey E — Customer information

1. Primary passenger details
2. Multiple passengers
3. Saved/co-passengers
4. Contact details
5. Gender-specific rules where applicable
6. Add-ons / insurance where applicable
7. Fare breakup
8. Coupon/offer application where applicable
9. GST/tax details where applicable

## Journey F — Payment

1. Order creation
2. Payment method selection
3. Payment SDK/web challenge where applicable
4. Processing state
5. Success
6. Failure
7. Retry
8. Pending status
9. Seat release on failure/abandonment
10. Booking confirmation

## Journey G — Post-booking

1. Ticket summary
2. QR code / ticket code
3. Passenger details
4. Seat details
5. Boarding/drop details
6. Trip status
7. PDF/share/download where applicable
8. Live trip experience
9. support/report issue

## Journey H — My Trips

1. Upcoming trips
2. Active/in-progress trips
3. Completed trips
4. Cancelled trips
5. Booking detail
6. refund status
7. rebook/reschedule
8. cancellation workflow

## Journey I — Account / utility

1. Profile
2. Saved passengers
3. saved payment methods
4. Wallet
5. Notifications
6. Referral/rewards
7. language
8. privacy/terms
9. account deletion
10. support / report issue

## Thirty8 implementation rule

Replicate the **functional journey and interaction hierarchy**, not proprietary visual assets. Every screen must have:

- loading state
- success state
- empty state where applicable
- validation state
- network failure state
- retry path
- back navigation
- analytics event definition
- authorization requirement
- persistence behavior
