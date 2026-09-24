# 06 — Thirty8 Database Schema Specification

## Recommended database

PostgreSQL.

Reasons:

- transactional seat booking
- row-level locking
- constraints and unique indexes
- JSONB for controlled configuration fields
- strong reporting support
- straightforward integration with REST APIs

Redis may be used for cache/queues, but it must not become the canonical booking ledger.

## Core tables

### users

- `id` UUID PK
- `phone` varchar unique nullable
- `email` varchar unique nullable
- `name`
- `status`
- `created_at`
- `updated_at`

### roles

- `id`
- `code`

Suggested codes:

- `customer`
- `operator_admin`
- `operator_staff`
- `driver`
- `conductor`
- `platform_admin`
- `platform_support`

### operators

- `id`
- `legal_name`
- `display_name`
- `registration_no` nullable
- `contact_phone`
- `contact_email`
- `status`
- `settlement_config` JSONB
- timestamps

### buses

- `id`
- `operator_id`
- `registration_number`
- `display_name`
- `bus_type`
- `classification`
- `active`
- timestamps

Unique: `(operator_id, registration_number)`.

### bus_layouts

- `id`
- `bus_id`
- `layout_name`
- `deck_count`
- `version`
- `layout_json` JSONB
- timestamps

### seats

- `id`
- `bus_layout_id`
- `seat_code`
- `row_no`
- `column_no`
- `deck`
- `seat_type`
- `gender_rule`
- `is_active`

Unique: `(bus_layout_id, seat_code, version relationship if used)`.

### routes

- `id`
- `operator_id`
- `source_city_id`
- `destination_city_id`
- `distance_km`
- `active`

### route_stops

- `id`
- `route_id`
- `sequence_no`
- `location_id`
- `scheduled_offset_minutes`
- `stop_type`

### boarding_points / dropping_points

Can either be separate tables or one `service_points` table with a role. For clarity in the first version, use separate logical types but share a common base location structure.

### services

- `id`
- `operator_id`
- `route_id`
- `bus_id`
- `service_code`
- `service_name`
- `default_departure_local_time`
- `default_arrival_offset_minutes`
- `status`

### trips

- `id`
- `service_id`
- `operator_id`
- `route_id`
- `bus_id`
- `travel_date`
- `departure_at`
- `arrival_at`
- `status`
- `booking_open_at`
- `booking_close_at`

Index `(route_id, travel_date, status)`.

### trip_seats

- `id`
- `trip_id`
- `seat_id`
- `status`
- `hold_id` nullable
- `booking_item_id` nullable
- `passenger_id` nullable
- timestamps

Allowed state:

`available | held | booked | blocked | cancelled | boarded`

Critical unique index:

`UNIQUE(trip_id, seat_id)`.

### seat_holds

- `id`
- `trip_id`
- `user_id`
- `hold_token`
- `expires_at`
- `status`
- timestamps

Unique: `hold_token`.

### passengers

- `id`
- `customer_user_id` nullable
- `name`
- `age`
- `gender`
- `phone`
- `id_type` nullable
- `id_number` nullable

### bookings

- `id`
- `booking_reference` unique
- `customer_user_id`
- `operator_id`
- `trip_id`
- `boarding_point_id`
- `dropping_point_id`
- `status`
- `currency`
- `subtotal`
- `tax_total`
- `service_fee_total`
- `discount_total`
- `grand_total`
- `booked_at`
- `source`

### booking_items

- `id`
- `booking_id`
- `trip_seat_id`
- `passenger_id`
- `base_fare`
- `tax_amount`
- `service_charge`
- `discount_amount`
- `total_amount`

Unique `(booking_id, trip_seat_id)`.

### orders

- `id`
- `booking_id`
- `order_reference`
- `status`
- `amount`
- `currency`
- timestamps

### payments

- `id`
- `order_id`
- `provider`
- `provider_transaction_id`
- `method`
- `status`
- `amount`
- `paid_at`

### refunds

- `id`
- `payment_id`
- `booking_id`
- `amount`
- `status`
- `provider_reference`
- `processed_at`

### trip_manifests

- `id`
- `trip_id`
- `generated_at`
- `generated_by`
- `status`

### manifest_passengers

- `id`
- `manifest_id`
- `booking_item_id`
- `boarding_status`
- `boarded_at`
- `verified_by`

### qr_verifications

- `id`
- `ticket_id`
- `verified_by`
- `device_id` nullable
- `result`
- `verified_at`
- `reason`

### audit_logs

- `id`
- `actor_user_id`
- `operator_id` nullable
- `entity_type`
- `entity_id`
- `action`
- `before_json`
- `after_json`
- `request_id`
- `created_at`

## Database guarantees

The implementation is incomplete unless it enforces:

1. one seat row per trip/seat
2. no double-booking under concurrency
3. expired holds cannot remain sellable indefinitely
4. booking status transitions are auditable
5. payment callbacks are idempotent
6. refunds cannot exceed captured payment
7. operator users cannot access another operator's trips/bookings
8. customers cannot mutate operator inventory directly
9. admin actions are audited
