# 05 — Shared Thirty8 Domain Model

## Central principle

Customer and operator apps must read/write through **one authoritative Thirty8 backend**.

Do not create a separate “customer database” and “operator database” for bookings.

## Shared entities

### Identity

- `users`
- `roles`
- `user_roles`
- `operators`
- `operator_users`

### Fleet

- `buses`
- `bus_layouts`
- `seats`

### Geography

- `countries` (optional if India-only)
- `states`
- `cities`
- `locations`
- `routes`
- `route_stops`
- `boarding_points`
- `dropping_points`

### Schedule

- `services` — reusable operator offering
- `trips` — concrete date/time instance of a service
- `trip_stops`
- `trip_staff`

### Inventory

- `trip_seats`
- `seat_fares`
- `seat_holds`
- `inventory_events`

### Customer / passenger

- `customer_profiles`
- `passengers`
- `saved_passengers`

### Booking

- `bookings`
- `booking_items`
- `booking_status_history`
- `tickets`
- `ticket_events`

### Payment

- `orders`
- `payments`
- `payment_attempts`
- `refunds`
- `refund_events`

### Operations

- `trip_manifests`
- `manifest_passengers`
- `boarding_events`
- `qr_verifications`

### Commercial

- `fare_rules`
- `cancellation_policies`
- `coupons`
- `promotions`
- `service_fees`
- `tax_rules`

### Communication / support

- `notifications`
- `notification_preferences`
- `support_cases`
- `audit_logs`

## Entity relationships

```text
Operator
  ├── Buses
  ├── Services
  │     └── Route
  └── Trips
        ├── Trip Stops
        ├── Trip Seats
        ├── Trip Staff
        └── Manifest

Customer
  └── Booking
       ├── Booking Items
       │      ├── Passenger
       │      └── Trip Seat
       ├── Order
       ├── Payment
       └── Ticket

Trip Seat
   ↕
Seat Hold / Seat Booking
```

## Important modeling rule

A **service** is not the same as a **trip**.

Example:

- Service: “Port Blair → Rangat AC Seater”
- Trip: “20 Sep 2026, 07:30, Bus KA-01-AB-1234”

This separation is necessary for recurring schedules and concrete inventory.
