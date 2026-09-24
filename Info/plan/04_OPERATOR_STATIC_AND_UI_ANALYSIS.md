# 04 — Operator APK Static & UI Analysis

## Verified operator reference

Package: `redbus.rbplus.android`

Version: `2.0.6` / code `39`

## Major operator activities / workflows observed

- Splash
- Login
- Sign up
- Home
- City picker
- Search
- Calendar
- Update profile
- Forgot password
- Boarding & dropping
- Language
- QR scanner
- Ticket
- Generate manifest
- Print
- Driver manifest
- Seat activity
- Passenger activity
- Onboarding

## Layout/resource evidence

The operator APK exposes approximately 166 XML layout resources, including named resources for:

- home
- search
- buses
- boarding points
- seat layout
- reservation
- quick booking
- bookings
- ticket
- manifest
- driver manifest
- passengers
- QR/manual scan
- print ticket
- wallet
- statement

Seat resources include explicit state assets such as available, booked, reserved, selected and ladies-seat variants.

## Business-domain evidence

Observed client-side fields/classes include concepts such as:

- `operatorId`
- `serviceId`
- `serviceName`
- `routeId`
- `inventoryId`
- `inventoryItems`
- `seatType`
- `seatLayoutDisabled`
- `boardingPointId`
- `boardingPoint`
- `boardingPointAddress`
- `boardingTime`
- `droppingPoint`
- `bookingTime`
- `bookingType`
- `bookingUser`
- `bookedBy`
- `bookedName`
- `passenger`
- `busType`
- `busClassification`
- `departureTime`
- `arrivalTime`
- `fares`
- `fareDetails`
- `baseFare`
- `totalFare`
- `serviceCharge`
- `serviceTax`
- `cancellationCharge`
- `cancellationPolicy`
- `paymentMode`
- `paymentStatus`
- `paymentType`
- `refundAmount`
- `manifest`
- `driver`
- `coPilotNames`
- `liveTrackingAvailable`
- `latitude`
- `longitude`
- `wallet`
- `statement`

## Operator backend/API clues

Observed hosts/URLs include:

- `https://plusmobapi.redbus.com`
- `https://tabplus.redbus.com/terms`
- `https://redbus-plus.firebaseio.com`
- `redbus-plus.appspot.com`

These establish client-side dependencies but **do not expose the complete redBus server schema or server code**.

## Operator functional journeys for Thirty8

### Operator setup

- operator login
- operator profile
- staff creation/management
- bus creation
- seat layout assignment
- route setup
- boarding/dropping points
- service/trip scheduling

### Reservation / sales

- search services
- choose trip
- select seats
- quick booking
- passenger details
- fare computation
- payment collection
- booking confirmation
- ticket issuance

### Trip operations

- today's trips
- boarding chart
- passenger manifest
- seat-wise passenger view
- scan/verify QR
- mark boarded
- no-show/boarding exceptions
- driver/co-driver assignment
- print/download manifest

### Finance

- wallet/balance if used
- statements
- settlements
- refunds/cancellations
- trip-level sales

### Support

- booking lookup
- ticket lookup
- cancellation handling
- customer contact/context
- audit trail
