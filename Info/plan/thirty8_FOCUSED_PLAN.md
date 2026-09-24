# Thirty8 — Focused Development Plan: Bus Booking + Cargo Shipping

**Date:** 2026-09-21
**Scope:** Two features only — (1) Bus ticket booking, (2) Cargo/parcel shipping
**Backend:** Supabase
**Platforms:** Customer mobile app (Flutter), Operator app (Flutter), Admin web panel
**App Name:** Thirty8 (all references to "Thirty8" replaced)

---

## TABLE OF CONTENTS

- [A. Feature Scope](#a-feature-scope)
- [B. APK Evidence — Bus Booking](#b-apk-evidence--bus-booking)
- [C. Cargo Shipping — No APK Evidence](#c-cargo-shipping--no-apk-evidence)
- [D. Supabase Database Schema](#d-supabase-database-schema)
- [E. API & Edge Functions](#e-api--edge-functions)
- [F. Customer App Screens & Workflows](#f-customer-app-screens--workflows)
- [G. Operator App Screens & Workflows](#g-operator-app-screens--workflows)
- [H. Admin Panel Screens & Workflows](#h-admin-panel-screens--workflows)
- [I. Implementation Phases](#i-implementation-phases)
- [J. Pre-Build Checklist](#j-pre-build-checklist)

---

# A. Feature Scope

## A.1 Bus Booking (from APK)
Users can:
- Search buses by source city, destination city, date
- View search results with operator info, bus type, timings, fares, seats available
- Select seats on an interactive seat map
- Hold seats temporarily (countdown timer)
- Enter passenger details (name, age, gender, phone)
- Apply coupon/discount codes
- Select boarding and dropping points
- Pay via multiple methods (UPI, card, netbanking, wallet)
- Receive confirmed ticket with QR code
- Download/share PDF ticket
- View upcoming, completed, cancelled trips
- Cancel booking with refund
- Track live bus location (optional)
- Rate and review after trip

Operators can:
- Manage fleet (buses, seat layouts)
- Create routes with boarding/dropping points
- Schedule services/trips
- View bookings and passenger manifests
- Generate and print boarding manifests
- Scan QR codes to verify passengers
- Mark passengers as boarded
- View wallet/balance and statements

## A.2 Cargo Shipping (NEW — no APK reference)
Users can:
- Select origin city and destination city
- Choose cargo type (document, parcel, fragile, heavy goods, etc.)
- Enter package details (weight, dimensions, description)
- Choose shipping speed (standard, express, same-day if available)
- Get price estimate based on weight/distance/speed
- Schedule pickup from their location OR drop-off at partner hub
- Pay for shipping
- Track shipment in real-time
- Receive delivery confirmation
- View shipment history
- Cancel/refund if not yet picked up

Operators/transporters can:
- View incoming cargo requests
- Accept/reject shipments
- Manage fleet (vehicles with cargo capacity info)
- Create routes for cargo transport
- Update shipment status (picked up, in transit, out for delivery, delivered)
- View earnings and statements
- Scan QR/barcode to verify pickup and delivery

---

# B. APK Evidence — Bus Booking

The redBus APK (v82.5.5) provides direct evidence for all bus booking features. Key findings:

| Feature | APK Source | Confidence |
|---------|-----------|------------|
| Phone/OTP auth | `ContextualLoginActivityV2Kt`, `SMSBroadcastReceiver` | OBSERVED |
| City search | `LocationPickerActivity` | OBSERVED |
| Trip search results | `SrpActivity` (636 layouts) | OBSERVED |
| Seat layout/selection | `SeatLayoutDetailsScreenKt`, `SeatLayoutHeaderComponentKt` | OBSERVED |
| Seat hold with countdown | `CountDownTimerKt`, `SeatLockSelectionViewKt` | OBSERVED |
| Passenger info | `CustInfoActivity` | OBSERVED |
| Payment (multiple methods) | `PaymentRedirectionActivity`, JusPay SDK | OBSERVED |
| Ticket/QR | QR ticket activity, `PDFDownloadHelper` | OBSERVED |
| My Trips | Trip tabs, `TripDatabase`, `TripDao` | OBSERVED |
| Cancellation/refund | `CancellationActivity`, `BankNeftActivity` | OBSERVED |
| Live tracking | `BusBuddyActivity`, `GpsLocationSharingService` | OBSERVED |
| Operator fleet mgmt | Operator APK (`redbus.rbplus.android`) | OBSERVED |
| Manifest/boarding | `GenerateManifest`, `DriverManifest` | OBSERVED |
| QR verification | `QRScanner` (operator APK) | OBSERVED |
| Ratings | `RatingAndReviewActivity` | OBSERVED |

---

# C. Cargo Shipping — No APK Evidence

**Confirmed: ZERO cargo/shipping evidence in either APK.**

Search performed across:
- All 636 customer layout XMLs
- All 130+ operator layout XMLs
- All class/package names
- All string resources
- All domain model and schema files

The cargo feature must be **designed from scratch** based on standard logistics/parcel shipping patterns. The plan below includes a complete cargo module design.

---

# D. Supabase Database Schema

## D.1 Shared Tables (Bus + Cargo)

### Identity & Auth
```sql
-- Extends Supabase auth.users
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  phone VARCHAR(20) UNIQUE,
  email VARCHAR(200) UNIQUE,
  name VARCHAR(200),
  avatar_url TEXT,
  preferred_language VARCHAR(10) DEFAULT 'en',
  preferred_currency VARCHAR(3) DEFAULT 'USD',
  country_id UUID REFERENCES countries(id),
  status VARCHAR(20) DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  role VARCHAR(30) NOT NULL,
  operator_id UUID REFERENCES operators(id),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, role, operator_id)
);
-- Roles: customer, operator_admin, operator_staff, driver, platform_admin, platform_support
```

### Operators
```sql
CREATE TABLE operators (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_name VARCHAR(200) NOT NULL,
  display_name VARCHAR(200),
  operator_type VARCHAR(20) NOT NULL,  -- 'bus', 'cargo', 'both'
  registration_no VARCHAR(100),
  contact_phone VARCHAR(20),
  contact_email VARCHAR(200),
  country_id UUID REFERENCES countries(id),
  logo_url TEXT,
  description TEXT,
  status VARCHAR(20) DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

### Geography
```sql
CREATE TABLE countries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(3) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL,
  phone_code VARCHAR(10),
  currency_code VARCHAR(3),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cities (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  country_id UUID REFERENCES countries(id),
  name VARCHAR(200) NOT NULL,
  state VARCHAR(200),
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_cities_name ON cities USING gin(name gin_trgm_ops);
```

## D.2 Bus-Specific Tables

```sql
CREATE TABLE buses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  registration_number VARCHAR(50) NOT NULL,
  display_name VARCHAR(200),
  bus_type VARCHAR(50),          -- 'ac', 'non_ac', 'sleeper', 'seater', 'mini'
  classification VARCHAR(50),    -- 'luxury', 'standard', 'economy'
  photo_urls TEXT[],
  amenities JSONB DEFAULT '[]',
  total_seats INTEGER,
  deck_count SMALLINT DEFAULT 1,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(operator_id, registration_number)
);

CREATE TABLE bus_layouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bus_id UUID REFERENCES buses(id) ON DELETE CASCADE,
  layout_name VARCHAR(100),
  version INTEGER DEFAULT 1,
  layout_json JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE seats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bus_layout_id UUID REFERENCES bus_layouts(id) ON DELETE CASCADE,
  seat_code VARCHAR(20) NOT NULL,
  row_no SMALLINT,
  column_no SMALLINT,
  deck SMALLINT DEFAULT 1,
  seat_type VARCHAR(30),
  gender_rule VARCHAR(20) DEFAULT 'any',
  is_active BOOLEAN DEFAULT true,
  UNIQUE(bus_layout_id, seat_code)
);

CREATE TABLE bus_routes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  source_city_id UUID REFERENCES cities(id),
  destination_city_id UUID REFERENCES cities(id),
  distance_km NUMERIC(8,2),
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(operator_id, source_city_id, destination_city_id)
);

CREATE TABLE boarding_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id UUID REFERENCES bus_routes(id) ON DELETE CASCADE,
  name VARCHAR(200) NOT NULL,
  address TEXT,
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  sequence_no SMALLINT,
  is_active BOOLEAN DEFAULT true
);

CREATE TABLE dropping_points (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id UUID REFERENCES bus_routes(id) ON DELETE CASCADE,
  name VARCHAR(200) NOT NULL,
  address TEXT,
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  sequence_no SMALLINT,
  is_active BOOLEAN DEFAULT true
);

CREATE TABLE bus_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  route_id UUID REFERENCES bus_routes(id),
  bus_id UUID REFERENCES buses(id),
  service_code VARCHAR(50),
  service_name VARCHAR(200),
  default_departure_time TIME,
  default_arrival_offset_minutes INTEGER,
  status VARCHAR(20) DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE bus_trips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID REFERENCES bus_services(id),
  operator_id UUID REFERENCES operators(id),
  route_id UUID REFERENCES bus_routes(id),
  bus_id UUID REFERENCES buses(id),
  travel_date DATE NOT NULL,
  departure_at TIMESTAMPTZ NOT NULL,
  arrival_at TIMESTAMPTZ,
  currency_code VARCHAR(3) DEFAULT 'USD',
  min_fare_cents INTEGER,
  max_fare_cents INTEGER,
  available_seats INTEGER,
  live_tracking_enabled BOOLEAN DEFAULT false,
  status VARCHAR(20) DEFAULT 'scheduled',
  booking_open_at TIMESTAMPTZ,
  booking_close_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_bus_trips_route_date ON bus_trips(route_id, travel_date, status);
CREATE INDEX idx_bus_trips_operator ON bus_trips(operator_id, travel_date);

CREATE TABLE trip_seats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID REFERENCES bus_trips(id) ON DELETE CASCADE,
  seat_id UUID REFERENCES seats(id),
  status VARCHAR(20) DEFAULT 'available',
  hold_id UUID,
  booking_item_id UUID,
  passenger_id UUID,
  fare_cents INTEGER,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(trip_id, seat_id)
);
CREATE INDEX idx_trip_seats_status ON trip_seats(trip_id, status);

CREATE TABLE seat_holds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID REFERENCES bus_trips(id),
  user_id UUID REFERENCES profiles(id),
  hold_token VARCHAR(100) UNIQUE NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  status VARCHAR(20) DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_seat_holds_expiry ON seat_holds(expires_at) WHERE status = 'active';

CREATE TABLE fare_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id UUID REFERENCES bus_trips(id) ON DELETE CASCADE,
  seat_type VARCHAR(30),
  base_fare_cents INTEGER NOT NULL,
  tax_rate NUMERIC(5,4) DEFAULT 0,
  service_fee_cents INTEGER DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

## D.3 Cargo-Specific Tables (NEW)

```sql
CREATE TABLE cargo_vehicle_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) NOT NULL,           -- 'bike', 'auto', 'van', 'truck_7t', 'truck_16t', 'container'
  description TEXT,
  max_weight_kg NUMERIC(10,2),
  max_volume_cbm NUMERIC(10,3),         -- cubic meters
  base_fare_cents INTEGER,
  per_km_rate_cents INTEGER,
  per_kg_rate_cents INTEGER,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cargo_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(100) NOT NULL,           -- 'document', 'parcel', 'fragile', 'heavy_goods', 'perishable', 'liquid'
  description TEXT,
  requires_special_handling BOOLEAN DEFAULT false,
  insurance_recommended BOOLEAN DEFAULT false,
  max_weight_kg NUMERIC(10,2),
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cargo_vehicles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  vehicle_type_id UUID REFERENCES cargo_vehicle_types(id),
  registration_number VARCHAR(50) NOT NULL,
  display_name VARCHAR(200),
  capacity_weight_kg NUMERIC(10,2),
  capacity_volume_cbm NUMERIC(10,3),
  photo_urls TEXT[],
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(operator_id, registration_number)
);

-- Operator insurance compliance (NOT customer-facing)
CREATE TABLE operator_insurance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  vehicle_id UUID,
  vehicle_type VARCHAR(20),          -- 'bus' or 'cargo'
  insurance_provider VARCHAR(200) NOT NULL,
  policy_number VARCHAR(100) NOT NULL,
  coverage_type VARCHAR(30),         -- 'comprehensive', 'third_party'
  valid_from DATE NOT NULL,
  valid_until DATE NOT NULL,
  document_url TEXT,
  status VARCHAR(20) DEFAULT 'pending',  -- pending, verified, expired, rejected
  verified_by UUID REFERENCES profiles(id),
  verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cargo_routes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  source_city_id UUID REFERENCES cities(id),
  destination_city_id UUID REFERENCES cities(id),
  distance_km NUMERIC(8,2),
  estimated_hours NUMERIC(6,1),
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(operator_id, source_city_id, destination_city_id)
);

CREATE TABLE cargo_hub (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  name VARCHAR(200) NOT NULL,
  city_id UUID REFERENCES cities(id),
  address TEXT,
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  phone VARCHAR(20),
  operating_hours JSONB,           -- {"mon": {"open": "08:00", "close": "20:00"}, ...}
  accepts_dropoff BOOLEAN DEFAULT true,
  accepts_pickup BOOLEAN DEFAULT true,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cargo_pricing_rules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  route_id UUID REFERENCES cargo_routes(id),
  vehicle_type_id UUID REFERENCES cargo_vehicle_types(id),
  cargo_type_id UUID REFERENCES cargo_types(id),
  base_fare_cents INTEGER NOT NULL,
  per_km_rate_cents INTEGER,
  per_kg_rate_cents INTEGER,
  minimum_fare_cents INTEGER,
  surcharge_percent NUMERIC(5,2) DEFAULT 0,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE cargo_shipments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_reference VARCHAR(20) UNIQUE NOT NULL,
  sender_user_id UUID REFERENCES profiles(id),
  operator_id UUID REFERENCES operators(id),
  route_id UUID REFERENCES cargo_routes(id),
  vehicle_id UUID REFERENCES cargo_vehicles(id),
  cargo_type_id UUID REFERENCES cargo_types(id),

  -- Package details
  description TEXT,
  weight_kg NUMERIC(10,2) NOT NULL,
  length_cm NUMERIC(8,2),
  width_cm NUMERIC(8,2),
  height_cm NUMERIC(8,2),
  volume_cbm NUMERIC(10,3),
  declared_value_cents INTEGER,
  special_instructions TEXT,

  -- Pickup
  pickup_type VARCHAR(20) NOT NULL,     -- 'address', 'hub'
  pickup_address TEXT,
  pickup_latitude NUMERIC(10,7),
  pickup_longitude NUMERIC(10,7),
  pickup_hub_id UUID REFERENCES cargo_hub(id),
  pickup_contact_name VARCHAR(200),
  pickup_contact_phone VARCHAR(20),
  pickup_scheduled_at TIMESTAMPTZ,

  -- Delivery
  delivery_type VARCHAR(20) NOT NULL,   -- 'address', 'hub'
  delivery_address TEXT,
  delivery_latitude NUMERIC(10,7),
  delivery_longitude NUMERIC(10,7),
  delivery_hub_id UUID REFERENCES cargo_hub(id),
  delivery_contact_name VARCHAR(200),
  delivery_contact_phone VARCHAR(20),
  delivery_scheduled_at TIMESTAMPTZ,

  -- Pricing
  shipping_speed VARCHAR(20) DEFAULT 'standard',
  currency_code VARCHAR(3) DEFAULT 'INR',
  base_fare_cents INTEGER,
  distance_fare_cents INTEGER,
  weight_fare_cents INTEGER,
  surcharge_cents INTEGER,
  discount_cents INTEGER,
  total_fare_cents INTEGER,

  -- Status
  status VARCHAR(30) DEFAULT 'draft',
  -- draft, quoted, confirmed, pickup_scheduled, picked_up, in_transit,
  -- out_for_delivery, delivered, cancelled, returned

  -- Tracking
  current_latitude NUMERIC(10,7),
  current_longitude NUMERIC(10,7),
  last_location_update TIMESTAMPTZ,
  estimated_delivery_at TIMESTAMPTZ,
  actual_delivered_at TIMESTAMPTZ,

  -- Proof
  pickup_proof_url TEXT,
  delivery_proof_url TEXT,
  recipient_name VARCHAR(200),

  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_cargo_shipments_sender ON cargo_shipments(sender_user_id, status);
CREATE INDEX idx_cargo_shipments_operator ON cargo_shipments(operator_id, status);
CREATE INDEX idx_cargo_shipments_route ON cargo_shipments(route_id, created_at DESC);
CREATE INDEX idx_cargo_shipments_status ON cargo_shipments(status, created_at DESC);

CREATE TABLE cargo_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_id UUID REFERENCES cargo_shipments(id) ON DELETE CASCADE,
  from_status VARCHAR(30),
  to_status VARCHAR(30) NOT NULL,
  location_latitude NUMERIC(10,7),
  location_longitude NUMERIC(10,7),
  location_name VARCHAR(200),
  notes TEXT,
  actor_user_id UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_cargo_status_history ON cargo_status_history(shipment_id, created_at DESC);

CREATE TABLE cargo_tracking_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_id UUID REFERENCES cargo_shipments(id) ON DELETE CASCADE,
  event_type VARCHAR(50) NOT NULL,
  latitude NUMERIC(10,7),
  longitude NUMERIC(10,7),
  address TEXT,
  description TEXT,
  actor_user_id UUID REFERENCES profiles(id),
  device_info JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_cargo_tracking ON cargo_tracking_events(shipment_id, created_at DESC);

CREATE TABLE cargo_bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_reference VARCHAR(20) UNIQUE NOT NULL,
  shipment_id UUID REFERENCES cargo_shipments(id),
  customer_user_id UUID REFERENCES profiles(id),
  operator_id UUID REFERENCES operators(id),
  status VARCHAR(30) DEFAULT 'draft',
  currency_code VARCHAR(3) DEFAULT 'USD',
  subtotal_cents INTEGER,
  tax_cents INTEGER,
  total_cents INTEGER,
  booked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

## D.4 Shared Transaction Tables

```sql
CREATE TABLE passengers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_user_id UUID REFERENCES profiles(id),
  name VARCHAR(200) NOT NULL,
  age SMALLINT,
  gender VARCHAR(10),
  phone VARCHAR(20),
  id_type VARCHAR(30),
  id_number VARCHAR(100),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_reference VARCHAR(20) UNIQUE NOT NULL,
  booking_type VARCHAR(10) NOT NULL,    -- 'bus', 'cargo'
  customer_user_id UUID REFERENCES profiles(id),
  operator_id UUID REFERENCES operators(id),

  -- Bus-specific (nullable)
  trip_id UUID REFERENCES bus_trips(id),
  boarding_point_id UUID REFERENCES boarding_points(id),
  dropping_point_id UUID REFERENCES dropping_points(id),

  -- Cargo-specific (nullable)
  shipment_id UUID REFERENCES cargo_shipments(id),

  status VARCHAR(30) DEFAULT 'draft',
  source_app VARCHAR(20),
  currency_code VARCHAR(3) DEFAULT 'USD',
  subtotal_cents INTEGER,
  tax_total_cents INTEGER,
  service_fee_total_cents INTEGER,
  discount_total_cents INTEGER,
  grand_total_cents INTEGER,
  booked_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_bookings_customer ON bookings(customer_user_id, status);
CREATE INDEX idx_bookings_operator ON bookings(operator_id, status);
CREATE INDEX idx_bookings_type ON bookings(booking_type, status);

CREATE TABLE booking_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  trip_seat_id UUID REFERENCES trip_seats(id),
  passenger_id UUID REFERENCES passengers(id),
  description VARCHAR(200),
  base_fare_cents INTEGER,
  tax_amount_cents INTEGER,
  service_charge_cents INTEGER,
  discount_amount_cents INTEGER,
  total_amount_cents INTEGER,
  UNIQUE(booking_id, trip_seat_id)
);

CREATE TABLE booking_status_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES bookings(id) ON DELETE CASCADE,
  from_status VARCHAR(30),
  to_status VARCHAR(30) NOT NULL,
  reason TEXT,
  actor_user_id UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID REFERENCES bookings(id),
  order_reference VARCHAR(50) UNIQUE NOT NULL,
  status VARCHAR(30) DEFAULT 'created',
  amount_cents INTEGER NOT NULL,
  currency_code VARCHAR(3) DEFAULT 'USD',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES orders(id),
  provider VARCHAR(50),
  provider_transaction_id VARCHAR(200),
  method VARCHAR(30),
  status VARCHAR(30) DEFAULT 'pending',
  amount_cents INTEGER NOT NULL,
  paid_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE refunds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id UUID REFERENCES payments(id),
  booking_id UUID REFERENCES bookings(id),
  amount_cents INTEGER NOT NULL,
  status VARCHAR(30) DEFAULT 'pending',
  provider_reference VARCHAR(200),
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  title VARCHAR(200),
  body TEXT,
  channel VARCHAR(20),
  event_type VARCHAR(50),
  entity_type VARCHAR(50),
  entity_id UUID,
  is_read BOOLEAN DEFAULT false,
  metadata JSONB DEFAULT '{}',
  sent_at TIMESTAMPTZ DEFAULT now(),
  read_at TIMESTAMPTZ
);
CREATE INDEX idx_notifications_user ON notifications(user_id, is_read, sent_at DESC);

CREATE TABLE notification_preferences (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  event_type VARCHAR(50) NOT NULL,
  channel VARCHAR(20) NOT NULL,
  is_enabled BOOLEAN DEFAULT true,
  UNIQUE(user_id, event_type, channel)
);

CREATE TABLE ratings_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id),
  reviewable_type VARCHAR(20) NOT NULL,  -- 'bus_trip', 'cargo_service'
  reviewable_id UUID NOT NULL,
  operator_id UUID REFERENCES operators(id),
  rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  review_text TEXT,
  is_anonymous BOOLEAN DEFAULT false,
  is_approved BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE saved_payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE,
  provider VARCHAR(50) NOT NULL,
  method_type VARCHAR(30) NOT NULL,
  provider_token VARCHAR(200),
  display_name VARCHAR(100),
  metadata JSONB DEFAULT '{}',
  is_default BOOLEAN DEFAULT false,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE wallet (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES profiles(id) UNIQUE,
  balance_cents INTEGER DEFAULT 0,
  currency_code VARCHAR(3) DEFAULT 'USD',
  status VARCHAR(20) DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID REFERENCES wallet(id),
  type VARCHAR(20) NOT NULL,        -- 'credit', 'debit', 'refund', 'topup'
  amount_cents INTEGER NOT NULL,
  balance_after_cents INTEGER,
  description TEXT,
  entity_type VARCHAR(50),
  entity_id UUID,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id UUID REFERENCES profiles(id),
  operator_id UUID REFERENCES operators(id),
  entity_type VARCHAR(50) NOT NULL,
  entity_id UUID NOT NULL,
  action VARCHAR(50) NOT NULL,
  before_json JSONB,
  after_json JSONB,
  request_id VARCHAR(100),
  ip_address INET,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type, entity_id);
```

## D.5 Key Database Functions

### Seat Hold (Bus)
```sql
CREATE OR REPLACE FUNCTION create_seat_hold(
  p_trip_id UUID,
  p_seat_ids UUID[],
  p_ttl_seconds INTEGER DEFAULT 300
) RETURNS JSONB AS $$
DECLARE
  v_hold_id UUID;
  v_hold_token VARCHAR(100);
  v_expires_at TIMESTAMPTZ;
  v_seat RECORD;
  v_available_count INTEGER := 0;
BEGIN
  v_hold_token := encode(gen_random_bytes(24), 'hex');
  v_expires_at := now() + (p_ttl_seconds || ' seconds')::INTERVAL;

  FOR v_seat IN
    SELECT ts.id, ts.status, ts.hold_id
    FROM trip_seats ts
    WHERE ts.trip_id = p_trip_id AND ts.seat_id = ANY(p_seat_ids)
    FOR UPDATE OF ts
  LOOP
    IF v_seat.status = 'available' THEN
      v_available_count := v_available_count + 1;
    ELSIF v_seat.status = 'held' THEN
      IF EXISTS (SELECT 1 FROM seat_holds sh WHERE sh.id = v_seat.hold_id AND sh.expires_at < now() AND sh.status = 'active') THEN
        v_available_count := v_available_count + 1;
      ELSE
        RAISE EXCEPTION 'Seat is held by another user';
      END IF;
    ELSE
      RAISE EXCEPTION 'Seat is not available: %', v_seat.status;
    END IF;
  END LOOP;

  IF v_available_count != array_length(p_seat_ids, 1) THEN
    RAISE EXCEPTION 'Not all seats are available';
  END IF;

  INSERT INTO seat_holds (trip_id, user_id, hold_token, expires_at, status)
  VALUES (p_trip_id, auth.uid(), v_hold_token, v_expires_at, 'active')
  RETURNING id INTO v_hold_id;

  UPDATE trip_seats SET status = 'held', hold_id = v_hold_id, updated_at = now()
  WHERE trip_id = p_trip_id AND seat_id = ANY(p_seat_ids);

  RETURN jsonb_build_object(
    'hold_id', v_hold_id, 'hold_token', v_hold_token,
    'expires_at', v_expires_at, 'seat_ids', p_seat_ids
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### Cargo Price Estimate
```sql
CREATE OR REPLACE FUNCTION estimate_cargo_price(
  p_route_id UUID,
  p_vehicle_type_id UUID,
  p_cargo_type_id UUID,
  p_weight_kg NUMERIC,
  p_length_cm NUMERIC DEFAULT NULL,
  p_width_cm NUMERIC DEFAULT NULL,
  p_height_cm NUMERIC DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_rule RECORD;
  v_distance_km NUMERIC;
  v_volume_cbm NUMERIC;
  v_base INTEGER;
  v_distance_fare INTEGER;
  v_weight_fare INTEGER;
  v_total INTEGER;
  v_min INTEGER;
BEGIN
  -- Get route distance
  SELECT distance_km INTO v_distance_km FROM cargo_routes WHERE id = p_route_id;

  -- Get pricing rule
  SELECT * INTO v_rule FROM cargo_pricing_rules
  WHERE route_id = p_route_id AND vehicle_type_id = p_vehicle_type_id
    AND cargo_type_id = p_cargo_type_id AND is_active = true
  LIMIT 1;

  IF v_rule IS NULL THEN
    RAISE EXCEPTION 'No pricing rule found for this route/vehicle/cargo combination';
  END IF;

  -- Calculate volume if dimensions provided
  IF p_length_cm IS NOT NULL AND p_width_cm IS NOT NULL AND p_height_cm IS NOT NULL THEN
    v_volume_cbm := (p_length_cm * p_width_cm * p_height_cm) / 1000000.0;
  END IF;

  v_base := v_rule.base_fare_cents;
  v_distance_fare := COALESCE(v_rule.per_km_rate_cents, 0) * COALESCE(v_distance_km, 0);
  v_weight_fare := COALESCE(v_rule.per_kg_rate_cents, 0) * p_weight_kg;
  v_total := v_base + v_distance_fare + v_weight_fare;
  v_total := v_total + (v_total * v_rule.surcharge_percent / 100);
  v_min := COALESCE(v_rule.minimum_fare_cents, 0);

  IF v_total < v_min THEN v_total := v_min; END IF;

  RETURN jsonb_build_object(
    'base_fare_cents', v_base,
    'distance_fare_cents', v_distance_fare,
    'weight_fare_cents', v_weight_fare,
    'surcharge_cents', (v_total - v_base - v_distance_fare - v_weight_fare),
    'total_cents', v_total,
    'distance_km', v_distance_km,
    'currency', 'USD'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

## D.6 Row Level Security

```sql
-- Enable RLS on all tables
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE operators ENABLE ROW LEVEL SECURITY;
ALTER TABLE buses ENABLE ROW LEVEL SECURITY;
ALTER TABLE bus_trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_seats ENABLE ROW LEVEL SECURITY;
ALTER TABLE seat_holds ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE cargo_shipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE cargo_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
-- ... enable on ALL tables

-- Profiles: users see own, admin sees all
CREATE POLICY "Users view own profile" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Admin views all profiles" ON profiles FOR SELECT USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'platform_admin')
);

-- Bus trips: public reads scheduled, operator manages own
CREATE POLICY "Public view scheduled trips" ON bus_trips FOR SELECT USING (status IN ('scheduled', 'boarding'));
CREATE POLICY "Operator manages own trips" ON bus_trips FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('operator_admin', 'operator_staff') AND operator_id = bus_trips.operator_id)
);

-- Trip seats: public reads availability
CREATE POLICY "Public view seat availability" ON trip_seats FOR SELECT USING (true);

-- Bookings: customer sees own, operator sees their trips' bookings
CREATE POLICY "Customer views own bookings" ON bookings FOR SELECT USING (customer_user_id = auth.uid());
CREATE POLICY "Operator views own bookings" ON bookings FOR SELECT USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('operator_admin', 'operator_staff') AND operator_id = bookings.operator_id)
);

-- Cargo shipments: sender sees own, operator sees assigned
CREATE POLICY "Sender views own shipments" ON cargo_shipments FOR SELECT USING (sender_user_id = auth.uid());
CREATE POLICY "Operator views own shipments" ON cargo_shipments FOR SELECT USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role IN ('operator_admin', 'operator_staff') AND operator_id = cargo_shipments.operator_id)
);

-- Seat holds: user sees own
CREATE POLICY "User views own holds" ON seat_holds FOR SELECT USING (user_id = auth.uid());

-- Notifications: user sees own
CREATE POLICY "User views own notifications" ON notifications FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "User updates own notifications" ON notifications FOR UPDATE USING (user_id = auth.uid());

-- Wallet: user sees own
CREATE POLICY "User views own wallet" ON wallet FOR SELECT USING (user_id = auth.uid());

-- Operators: public sees active
CREATE POLICY "Public view active operators" ON operators FOR SELECT USING (status = 'active');
```

## D.7 pg_cron Jobs

```sql
-- Release expired seat holds (every minute)
SELECT cron.schedule('release-expired-holds', '* * * * *', $$
  UPDATE seat_holds SET status = 'expired' WHERE status = 'active' AND expires_at < now();
  UPDATE trip_seats SET status = 'available', hold_id = NULL, updated_at = now()
  WHERE status = 'held' AND hold_id IN (SELECT id FROM seat_holds WHERE status = 'expired');
$$);

-- Close booking windows (every 5 minutes)
SELECT cron.schedule('close-booking-windows', '*/5 * * * *', $$
  UPDATE bus_trips SET status = 'boarding', updated_at = now()
  WHERE status = 'scheduled' AND booking_close_at < now();
$$);

-- Auto-update cargo in-transit shipments (every 15 minutes)
SELECT cron.schedule('update-cargo-eta', '*/15 * * * *', $$
  UPDATE cargo_shipments
  SET estimated_delivery_at = estimated_delivery_at
  WHERE status = 'in_transit' AND estimated_delivery_at < now();
$$);
```
 
---
 
# D.8 Seed Data — Boarding/Dropping Points (Sri Vijaya Puram → Diglipur Corridor)
 
```sql
-- Boarding & Dropping Points for Main Corridor
-- Sequence follows the route from Sri Vijaya Puram (Port Blair) to Diglipur
-- GPS coordinates: TO BE FILLED - use Google Maps or GPS device to get exact lat/long for each point
-- Route ID will be set after bus_routes insert for main corridor
INSERT INTO boarding_points (route_id, name, address, latitude, longitude, sequence_no, is_active) VALUES
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Bus Terminus', 'Port Blair Bus Terminus', 11.6234, 92.7265, 1, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Bathu Basti Jn', 'Bathu Basti Junction', NULL, NULL, 2, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Sippighat Jn', 'Sippighat Junction', NULL, NULL, 3, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Chouldari Jn', 'Chouldari Junction', NULL, NULL, 4, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Tushnabad', 'Tushnabad', NULL, NULL, 5, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Ferrargunj', 'Ferrargunj', 11.5833, 92.7167, 6, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Miletilak Dispensary', 'Miletilak Dispensary', NULL, NULL, 7, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Jirkatang-II', 'Jirkatang II', NULL, NULL, 8, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Middle Strait', 'Middle Strait', NULL, NULL, 9, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'South Creek', 'South Creek', NULL, NULL, 10, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Adazig School', 'Adazig School', NULL, NULL, 11, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Gandhi Ghat Jetty', 'Gandhi Ghat Jetty', NULL, NULL, 12, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Kadamtala Out Post-3', 'Kadamtala Out Post 3', NULL, NULL, 13, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Parlob Jig No. 15', 'Parlob Jig No 15', NULL, NULL, 14, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Kaushalya Nagar Dispensary', 'Kaushalya Nagar Dispensary', NULL, NULL, 15, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Bakuntala Jn', 'Bakuntala Junction', NULL, NULL, 16, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Rangat', 'Rangat', 12.5333, 92.8833, 17, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Nimbutala Jn', 'Nimbutala Junction', NULL, NULL, 18, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Panchwati Jn', 'Panchwati Junction', NULL, NULL, 19, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'CFO Nallah', 'CFO Nallah', NULL, NULL, 20, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Billiground Jn', 'Billiground Junction', NULL, NULL, 21, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Nimbudera Jn', 'Nimbudera Junction', NULL, NULL, 22, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Patter Tikrey', 'Patter Tikrey', NULL, NULL, 23, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Rest Camp', 'Rest Camp', NULL, NULL, 24, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Austin Bridge', 'Austin Bridge', NULL, NULL, 25, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Mohanpur', 'Mohanpur', NULL, NULL, 26, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Ganatabla Range Office', 'Ganatabla Range Office', NULL, NULL, 27, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Kala Pahad', 'Kala Pahad', NULL, NULL, 28, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Pailoon School', 'Pailoon School', NULL, NULL, 29, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Kishori Nagar Jn', 'Kishori Nagar Junction', NULL, NULL, 30, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Kalara Jn', 'Kalara Junction', NULL, NULL, 31, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Sita Nagar W/S', 'Sita Nagar W/S', NULL, NULL, 32, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Subhash Gram', 'Subhash Gram', NULL, NULL, 33, true),
  ((SELECT id FROM bus_routes WHERE source_city_id = (SELECT id FROM cities WHERE name ILIKE '%Sri Vijaya Puram%') AND destination_city_id = (SELECT id FROM cities WHERE name ILIKE '%Diglipur%') LIMIT 1), 'Aerial Bay', 'Aerial Bay', NULL, NULL, 34, true);

-- Dropping points mirror boarding points (same locations, reverse order for return trips)
-- Run same INSERT into dropping_points table
```
 
---
 
# E. API & Edge Functions

## E.1 Authentication

| Function | Method | Purpose |
|----------|--------|---------|
| `auth/sign-up` | POST | Register new user (phone + OTP) |
| `auth/send-otp` | POST | Send OTP to phone |
| `auth/verify-otp` | POST | Verify OTP, return JWT |
| `auth/refresh` | POST | Refresh access token |
| `auth/logout` | POST | Invalidate session |

## E.2 Bus — Search

| Function | Method | Purpose |
|----------|--------|---------|
| `search/cities` | GET | Autocomplete city names |
| `search/trips` | GET | Search available bus trips |
| `search/trip-seats` | GET | Get seat map for a trip |
| `search/boarding-points` | GET | Boarding points for trip |
| `search/dropping-points` | GET | Dropping points for trip |

## E.3 Bus — Booking

| Function | Method | Purpose |
|----------|--------|---------|
| `bus/hold-seats` | POST | Temporarily hold seats (with TTL) |
| `bus/release-hold` | DELETE | Release held seats |
| `bus/create-booking` | POST | Convert hold to confirmed booking |
| `bus/cancel-booking` | POST | Cancel with refund calculation |
| `bus/booking-detail` | GET | Full booking details |
| `bus/my-bookings` | GET | User's booking history |

## E.4 Cargo — Shipment

| Function | Method | Purpose |
|----------|--------|---------|
| `cargo/estimate-price` | POST | Get price estimate |
| `cargo/create-shipment` | POST | Create new shipment |
| `cargo/update-shipment` | PUT | Update shipment details |
| `cargo/confirm-shipment` | POST | Confirm and pay for shipment |
| `cargo/cancel-shipment` | POST | Cancel (if not yet picked up) |
| `cargo/my-shipments` | GET | User's shipment history |
| `cargo/shipment-detail` | GET | Full shipment details |

## E.5 Cargo — Tracking

| Function | Method | Purpose |
|----------|--------|---------|
| `cargo/track` | GET | Real-time tracking for shipment |
| `cargo/update-status` | POST | Operator updates shipment status |
| `cargo/update-location` | POST | Operator updates GPS location |
| `cargo/confirm-pickup` | POST | Confirm pickup with proof |
| `cargo/confirm-delivery` | POST | Confirm delivery with proof |

## E.6 Operator — Bus Management

| Function | Method | Purpose |
|----------|--------|---------|
| `operator/buses` | GET/POST | List/create buses |
| `operator/buses/:id` | PUT | Update bus |
| `operator/buses/:id/layout` | PUT | Update seat layout |
| `operator/routes` | GET/POST | List/create routes |
| `operator/services` | GET/POST | List/create services |
| `operator/trips` | GET/POST | List/create trips |
| `operator/trips/:id/inventory` | GET | View seat inventory |
| `operator/trips/:id/bookings` | GET | View trip bookings |
| `operator/trips/:id/manifest` | POST | Generate manifest |
| `operator/trips/:id/manifest` | GET | View manifest |
| `operator/trips/:id/boarding/:itemId` | POST | Mark passenger boarded |

## E.7 Operator — Cargo Management

| Function | Method | Purpose |
|----------|--------|---------|
| `operator/cargo/vehicles` | GET/POST | List/create vehicles |
| `operator/cargo/routes` | GET/POST | List/create cargo routes |
| `operator/cargo/hubs` | GET/POST | List/create hubs |
| `operator/cargo/shipments` | GET | View assigned shipments |
| `operator/cargo/shipments/:id/accept` | POST | Accept shipment |
| `operator/cargo/shipments/:id/reject` | POST | Reject shipment |
| `operator/cargo/shipments/:id/status` | POST | Update status |
| `operator/cargo/shipments/:id/location` | POST | Update GPS |
| `operator/cargo/earnings` | GET | View earnings/statements |

## E.8 Payments

| Function | Method | Purpose |
|----------|--------|---------|
| `payments/create-order` | POST | Create payment order |
| `payments/process` | POST | Initiate payment with provider |
| `payments/webhook` | POST | Receive provider callback |
| `payments/verify` | GET | Verify payment status |

## E.9 User Profile

| Function | Method | Purpose |
|----------|--------|---------|
| `profile` | GET/PUT | View/update profile |
| `profile/saved-passengers` | GET/POST/DELETE | Manage saved passengers |
| `profile/payment-methods` | GET/DELETE | Manage saved payment methods |
| `profile/wallet` | GET | Wallet balance |
| `profile/wallet/topup` | POST | Add money to wallet |
| `profile/notifications` | GET | Notification list |
| `profile/notifications/:id/read` | PATCH | Mark as read |

## E.10 Admin

| Function | Method | Purpose |
|----------|--------|---------|
| `admin/dashboard` | GET | KPI stats |
| `admin/operators` | GET | All operators |
| `admin/operators/:id/approve` | POST | Approve operator |
| `admin/users` | GET | All users |
| `admin/bookings` | GET | All bookings (bus + cargo) |
| `admin/refunds` | GET | Refund queue |
| `admin/refunds/:id/process` | POST | Process refund |
| `admin/audit-logs` | GET | Audit trail |

---

# F. Customer App Screens & Workflows

## F.1 Bus Booking Screens

| # | Screen | Description |
|---|--------|-------------|
| B-01 | Splash / Onboarding | App launch, first-time tutorial |
| B-02 | Login / OTP | Phone number + OTP verification |
| B-03 | Home | Search widget, promo banners, recent trips, upcoming trips |
| B-04 | City Picker | Source/destination selection with autocomplete |
| B-05 | Date Picker | Travel date selection |
| B-06 | Search Results (SRP) | List of available buses with filters/sort |
| B-07 | Bus Details | Operator info, amenities, photos, route, boarding/dropping |
| B-08 | Seat Layout | Interactive seat map with legend |
| B-09 | Seat Lock / Countdown | Hold timer, continue to checkout |
| B-10 | Passenger Details | Name, age, gender, phone for each passenger |
| B-11 | Payment Selection | UPI, card, netbanking, wallet options |
| B-12 | Payment Processing | Loading/processing state |
| B-13 | Booking Confirmed | Success screen with ticket summary + QR |
| B-14 | Ticket Detail | Full ticket with boarding pass, QR, PDF download |
| B-15 | My Trips | Upcoming / Completed / Cancelled tabs |
| B-16 | Trip Detail | Full booking details, trip status |
| B-17 | Cancellation | Preview refund → confirm → process |
| B-18 | Live Tracking | Map with bus location, ETA (optional) |
| B-19 | Rate Trip | Star rating + review after travel |

## F.2 Cargo Shipping Screens

| # | Screen | Description |
|---|--------|-------------|
| C-01 | Cargo Home | "Send a package" entry, recent shipments |
| C-02 | New Shipment — Route | Origin city, destination city |
| C-03 | New Shipment — Package | Weight, dimensions, cargo type, description |
| C-04 | New Shipment — Pickup | Address pickup or select hub drop-off |
| C-05 | New Shipment — Delivery | Address delivery or select hub pickup |
| C-06 | New Shipment — Speed | Standard / Express / Same-day |
| C-07 | Price Quote | Fare breakdown |
| C-08 | Shipment Confirmation | Confirm + pay |
| C-09 | Shipment Tracking | GPS coordinate matching — status timeline + next milestone ETA (no map API) |
| C-10 | My Shipments | Active / Delivered / Cancelled tabs |
| C-11 | Shipment Detail | Full shipment info, status, tracking history |
| C-12 | Cancel Shipment | Cancel if not yet picked up |

## F.3 Shared Screens

| # | Screen | Description |
|---|--------|-------------|
| S-01 | Profile | View/edit personal info |
| S-02 | Saved Passengers | Manage frequent co-passengers |
| S-03 | Payment Methods | Saved cards/wallets |
| S-04 | Wallet | Balance, transactions, top-up |
| S-05 | Notifications | In-app notification list |
| S-06 | Notification Preferences | Toggle notification types |
| S-07 | Language | Switch app language |
| S-08 | Settings | Account settings, about, logout |

---

# G. Operator App Screens & Workflows

## G.1 Bus Operator Screens

| # | Screen | Description |
|---|--------|-------------|
| OB-01 | Login | Email + password |
| OB-02 | Dashboard | Today's trips, stats, quick actions |
| OB-03 | Fleet — Bus List | All buses with status |
| OB-04 | Fleet — Bus Detail | Bus info, seat layout, amenities |
| OB-05 | Fleet — Add/Edit Bus | Create or modify bus |
| OB-06 | Routes — List | All routes |
| OB-07 | Routes — Create/Edit | Route with boarding/dropping points |
| OB-08 | Services — List | Scheduled services |
| OB-09 | Services — Create | New service (route + bus + timing) |
| OB-10 | Trips — Today | Today's trips with status |
| OB-11 | Trips — Calendar | Trips by date |
| OB-12 | Trip Detail | Seat inventory, bookings, manifest |
| OB-13 | Passenger Manifest | Passenger list, boarding status |
| OB-14 | QR Scanner | Scan ticket QR to verify |
| OB-15 | Quick Booking | Book for walk-in customer |
| OB-16 | Wallet / Statements | Balance, transaction history |

## G.2 Cargo Operator Screens

| # | Screen | Description |
|---|--------|-------------|
| OC-01 | Dashboard | Pending shipments, active deliveries, stats |
| OC-02 | Shipments — Incoming | New cargo requests |
| OC-03 | Shipments — Active | In-transit shipments |
| OC-04 | Shipments — Delivered | Completed shipments |
| OC-05 | Shipment Detail | Package info, route, tracking |
| OC-06 | Accept/Reject Shipment | Review and accept cargo request |
| OC-07 | Update Status | Change shipment status (picked up → in transit → delivered) |
| OC-08 | Update Location | GPS location update |
| OC-09 | Confirm Pickup | Pickup with photo/signature proof |
| OC-10 | Confirm Delivery | Delivery with photo/signature proof |
| OC-11 | Fleet — Vehicles | Cargo vehicles with capacity |
| OC-12 | Fleet — Add Vehicle | Register new cargo vehicle |
| OC-13 | Routes — Cargo Routes | Cargo routes with pricing |
| OC-14 | Hubs — List | Drop-off/pickup hubs |
| OC-15 | Hubs — Add/Edit Hub | Hub details, operating hours |
| OC-16 | Earnings | Revenue, settlements, statements |

---

# H. Admin Panel Screens & Workflows

| # | Screen | Description |
|---|--------|-------------|
| A-01 | Login | Admin email + password |
| A-02 | Dashboard | KPIs: total bookings, revenue, active operators |
| A-03 | Operators — List | All operators (bus + cargo) |
| A-04 | Operators — Approve | Approval workflow |
| A-05 | Operators — Detail | Full operator profile, fleet, stats |
| A-06 | Users — List | All registered users |
| A-07 | Users — Detail | User profile, bookings, shipments |
| A-08 | Bus — Trips | All bus trips with filters |
| A-09 | Bus — Bookings | All bus bookings |
| A-10 | Cargo — Shipments | All cargo shipments |
| A-11 | Refunds — Queue | Pending refund requests |
| A-12 | Refunds — Process | Approve/reject refund |
| A-13 | Finance — Reports | Revenue by operator, route, period |
| A-14 | Audit Logs | System audit trail |
| A-15 | Settings | System configuration |

---

# I. Implementation Phases

## Phase 1: Project Setup + Database (Days 1-4)

1. Initialize monorepo structure
2. Create Supabase project
3. Run all database migrations (shared + bus + cargo tables)
4. Set up RLS policies
5. Set up pg_cron jobs
6. Insert seed data (countries, cities, cargo vehicle types, cargo types)
7. Create storage buckets (bus photos, cargo proof photos, user avatars)

## Phase 2: Authentication (Days 5-6)

1. Supabase Auth — phone OTP for customers
2. Supabase Auth — email/password for operators and admin
3. Profile creation trigger on first login
4. Role assignment (customer, operator_admin, platform_admin)
5. JWT claims with role + operator_id

## Phase 3: Bus Backend (Days 7-14)

1. Edge Function: city search (trigram)
2. Edge Function: trip search with filters
3. Edge Function: seat map
4. Edge Function: boarding/dropping points
5. Edge Function: hold seats (with PL/pgSQL)
6. Edge Function: release expired holds
7. Edge Function: create booking
8. Edge Function: confirm booking (post-payment)
9. Edge Function: cancel booking + refund
10. Edge Function: my bookings
11. Edge Function: manifest generation
12. Edge Function: QR verification

## Phase 4: Cargo Backend (Days 15-20)

1. Edge Function: cargo price estimate
2. Edge Function: create shipment
3. Edge Function: confirm shipment (with payment)
4. Edge Function: cancel shipment
5. Edge Function: my shipments
6. Edge Function: update shipment status
7. Edge Function: update GPS location
8. Edge Function: confirm pickup (with proof)
9. Edge Function: confirm delivery (with proof)
10. Edge Function: cargo tracking events

## Phase 5: Payment Integration (Days 21-24)

1. Payment adapter (Razorpay / PayU / Stripe)
2. Edge Function: create order
3. Edge Function: process payment
4. Edge Function: payment webhook handler
5. Idempotent payment processing
6. Refund processing

## Phase 6: Notifications (Days 25-27)

1. FCM setup via Edge Functions
2. Notification templates (bus + cargo events)
3. Push notification dispatch
4. Notification preferences
5. Email confirmation (booking + shipment)

## Phase 7: Customer App — Bus (Days 28-38)

1. Flutter project setup, routing, state management
2. Design system / theme
3. Login/OTP screens
4. Home screen with search widget
5. City picker
6. Search results (SRP) with filters/sort
7. Bus details screen
8. Seat layout/selection
9. Seat lock + countdown
10. Passenger details form
11. Payment selection + processing
12. Booking confirmation + QR ticket
13. PDF ticket generation + download
14. My Trips (tabs: upcoming/completed/cancelled)
15. Trip detail
16. Cancellation flow
17. Live tracking (optional)
18. Rate/review after trip

## Phase 8: Customer App — Cargo (Days 39-47)

1. Cargo home screen
2. New shipment flow (route → package → pickup → delivery → speed → quote → confirm)
3. Price estimate display
4. Shipment tracking screen (map + timeline)
5. My Shipments (tabs: active/delivered/cancelled)
6. Shipment detail
7. Cancel shipment

## Phase 9: Customer App — Shared (Days 48-52)

1. Profile screen
2. Saved passengers
3. Wallet (balance, top-up, transactions)
4. Notifications center
5. Language switcher
6. Settings

## Phase 10: Operator App — Bus (Days 53-62)

1. Login + dashboard
2. Fleet management (buses, layouts)
3. Route management (boarding/dropping points)
4. Service/trip scheduling
5. Trip detail + seat inventory
6. Passenger manifest
7. QR scanner
8. Quick booking (walk-in)
9. Wallet/statements

## Phase 11: Operator App — Cargo (Days 63-72)

1. Cargo dashboard
2. Incoming shipments (accept/reject)
3. Active shipments management
4. Update status + GPS
5. Confirm pickup + delivery (with photo proof)
6. Vehicle management
7. Cargo route management
8. Hub management
9. Earnings/statements

## Phase 12: Admin Panel (Days 73-82)

1. Next.js project setup
2. Login + dashboard
3. Operator management (list, approve, detail)
4. User management
5. Bus bookings overview
6. Cargo shipments overview
7. Refund processing
8. Revenue reports
9. Audit logs

## Phase 13: Testing & QA (Days 83-90)

1. Unit tests (seat hold, cargo pricing, booking states)
2. Integration tests (bus booking flow, cargo flow)
3. E2E tests (search → book → pay → ticket)
4. E2E tests (cargo: quote → ship → track → deliver)
5. Concurrency tests (double-booking prevention)
6. RLS policy tests
7. Payment edge cases
8. Performance testing

## Phase 14: Deployment (Days 91-95)

1. Supabase production setup
2. Edge Functions deployment
3. Flutter app builds (customer + operator)
4. Admin web deployment
5. Monitoring + error tracking setup
6. Documentation

---

# J. Pre-Build Checklist

## J.1 Bus Booking

| # | Feature | Status |
|---|---------|--------|
| 1 | Phone/OTP authentication | READY |
| 2 | City search (autocomplete) | READY |
| 3 | Trip search with filters/sort | READY |
| 4 | Seat layout/selection | READY |
| 5 | Seat hold with countdown timer | READY |
| 6 | Passenger details (multi-passenger) | READY |
| 7 | Boarding/dropping point selection | READY |
| 8 | Payment (UPI, card, netbanking) | NEEDS: payment provider account |
| 9 | Booking confirmation + QR | READY |
| 10 | PDF ticket download | READY |
| 11 | My Trips (upcoming/completed/cancelled) | READY |
| 12 | Cancellation with refund | READY |
| 13 | Live tracking | READY (optional) |
| 14 | Ratings/reviews | READY |
| 15 | Operator fleet management | READY |
| 16 | Operator route/service/trip management | READY |
| 17 | Operator manifest + QR scan | READY |
| 18 | Wallet + top-up | READY |

## J.2 Cargo Shipping

| # | Feature | Status |
|---|---------|--------|
| 1 | Cargo type selection | READY |
| 2 | Package details (weight, dimensions) | READY |
| 3 | Price estimation | READY |
| 4 | Pickup (address or hub) | READY |
| 5 | Delivery (address or hub) | READY |
| 6 | Shipping speed selection | READY |
| 7 | Shipment confirmation + payment | READY |
| 8 | Real-time tracking | READY |
| 9 | Status updates (operator side) | READY |
| 10 | Pickup confirmation with proof | READY |
| 11 | Delivery confirmation with proof | READY |
| 12 | Shipment history | READY |
| 13 | Cancel (pre-pickup) | READY |
| 14 | Operator vehicle management | READY |
| 15 | Operator insurance compliance | READY |
| 16 | Operator hub management | READY |
| 17 | Operator cargo route management | READY |
| 18 | Operator earnings/statements | READY |

## J.3 Infrastructure
 
 | # | Item | Status |
 |---|------|--------|
 | 1 | Supabase project | **DONE** — URL: `https://xdrthrdwdfzhzhqkhnnf.supabase.co`, Anon Key: configured |
 | 2 | Database migrations | READY |
 | 3 | RLS policies | READY |
 | 4 | Edge Functions | READY |
 | 5 | Storage buckets | READY |
 | 6 | pg_cron jobs | READY |
 | 7 | Payment gateway | **Test Ready** — Razorpay Test Key: `rzp_test_TfTr1V6YzjFqVP` (Secret & Webhook Secret in Supabase Vault) |
 | 8 | FCM setup | **DONE** — Firebase Project: `308858536267` (Service Account in Supabase Vault) |
 | 9 | Email service | NEEDS: SendGrid/account |
 | 10 | Maps (GPS coordinate matching) | **Free** — no API key needed; match live lat/long with boarding/dropping point coordinates |

## J.4 Decisions Made
 
 | # | Question | Decision |
 |---|----------|----------|
 | 1 | Payment provider? | **Razorpay** |
 | 2 | Which country for MVP? | **India — Andaman & Nicobar Islands** |
 | 3 | Languages for MVP? | **English + Hindi** |
 | 4 | Cargo insurance? | **Operator compliance only** (not sold to customers) |
 | 5 | Live bus tracking? | **Yes — Dual Mode**: GPS Tracker Device (bus, driver-independent) + Phone GPS (cargo, flexible) |
 | 6 | Cargo hub model? | **Operator-added + Admin approval** — operators add bus boarding points & cargo hubs, admin approves, then visible in customer app |
 | 7 | Same-day cargo delivery? | **TBD** — discuss later |
 | 8 | Boarding points for main corridor? | **Pre-seeded** — 34 points from Bus Terminus to Aerial Bay (editable via admin panel) |
 
 ## J.5 Remaining Questions
 
 | # | Question | Options |
 |---|----------|---------|
 | 1 | Same-day cargo delivery? | Yes (dispatch complexity) / No (standard + express only) |
| 2 | GPS tracker device integration spec? | Protocol/format for hardware vendors (to be defined) |
 
 ---
 
 # J.6 Environment Variables Reference (Agent Setup)
 
 **NEVER put actual secrets in this plan or repo.** Agent reads from Supabase Vault / GitHub Secrets / `.env.local` at runtime.
 
 | Variable | Source | Purpose | Example Value |
 |----------|--------|---------|---------------|
 | `SUPABASE_URL` | Supabase Dashboard | Project URL | `https://xdrthrdwdfzhzhqkhnnf.supabase.co` |
 | `SUPABASE_ANON_KEY` | Supabase Dashboard | Client-side auth | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...` |
 | `SUPABASE_SERVICE_ROLE_KEY` | Supabase Dashboard → Settings → API | Server-only (Edge Functions) | **PUT IN SUPABASE VAULT ONLY** |
 | `RAZORPAY_KEY_ID` | Razorpay Dashboard | Client + Server | `rzp_test_TfTr1V6YzjFqVP` |
 | `RAZORPAY_KEY_SECRET` | Razorpay Dashboard | **Server-only** | **PUT IN SUPABASE VAULT ONLY** |
 | `RAZORPAY_WEBHOOK_SECRET` | Razorpay Dashboard → Webhooks | Verify webhooks | **PUT IN SUPABASE VAULT ONLY** |
 | `FCM_SERVER_KEY` | Firebase Console → Cloud Messaging | Push notifications | **PUT IN SUPABASE VAULT ONLY** |
 | `FCM_SENDER_ID` | Firebase Console → Project Settings | Push notifications | `308858536267` |
 | `SENDGRID_API_KEY` | SendGrid Dashboard | Transactional emails | **PUT IN SUPABASE VAULT ONLY** |
 
 **Setup Order:**
 1. Create Supabase project → get URL + anon key
 2. Add all `*_SECRET` keys to **Supabase Dashboard → Edge Functions → Secrets**
 3. Configure Razorpay webhook URL: `https://<project>.supabase.co/functions/v1/payments/webhook`
 4. Add Firebase service account JSON to Supabase Vault for FCM
 
 ---
 
 **END OF FOCUSED PLAN**

*This document covers ONLY bus booking + cargo shipping. All other features from the APK (hotels, auto, rail, gamification, etc.) have been excluded. Ready for AI coding agent handoff.*
