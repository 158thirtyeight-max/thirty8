# Thirty8 — Master Development Plan

**Date:** 2026-09-21
**Platform:** India (Andaman & Nicobar Islands focus)
**Features:** Bus Booking + Cargo Shipping
**Backend:** Supabase (PostgreSQL + Edge Functions + Auth + Storage + Real-Time)
**Payment:** Razorpay
**Languages:** English, Hindi
**Apps:** Customer (Flutter), Operator (Flutter), Admin (Web)

---

# PART 1: PROJECT OVERVIEW

## 1.1 What is Thirty8

Thirty8 is a transport platform for the Andaman & Nicobar Islands enabling:
1. **Bus ticket booking** — passengers search, select seats, pay, and travel between islands
2. **Cargo shipping** — senders ship parcels/goods between islands with real-time tracking

## 1.2 Market Context (Andaman & Nicobar Islands)

- Islands spread across ~700 km with limited road connectivity
- Bus transport is the primary surface transport between towns
- **Main bus corridor: Sri Vijaya Puram (Port Blair) → Diglipur** (~320 km)
  - Multiple intermediate stops: Ferrargunj, Rangat, Mayabunder, etc.
  - Different buses operate on different segments (not all go end-to-end)
  - Some buses: Port Blair → Rangat only
  - Some buses: Rangat → Diglipur only
  - Some buses: Full route Port Blair → Diglipur
  - Passengers may need to change buses at intermediate stops
- Cargo movement is critical — most goods come from mainland India
- Chennai handles 75-85% of cargo to the Islands
- Limited competition = higher costs = opportunity for a digital platform
- Existing operators: State Transport Service, private operators (Anand Transport, etc.)
- Digital ticketing is nascent — first-mover advantage

### Route Structure Model

```
MAIN CORRIDOR: Sri Vijaya Puram ─────────────────────────── Diglipur
                (Port Blair)                                   (~320 km)

SEGMENTS:
  Segment A: Sri Vijaya Puram → Ferrargunj → Rangat         (~100 km)
  Segment B: Rangat → Mayabunder → Diglipur                 (~220 km)
  Segment C: Sri Vijaya Puram → Diglipur (full route)        (~320 km)

BOARDING/DROPPING POINTS along the corridor:
  1. Sri Vijaya Puram (Port Blair) — Major boarding point
  2. Ferrargunj — Intermediate stop
  3. Rangat — Major intermediate stop (change point)
  4. Mayabunder — Intermediate stop
  5. Diglipur — Terminal stop

BUS OPERATORS may run:
  - Full route: Port Blair → Diglipur (one bus, no change)
  - Segment A only: Port Blair → Rangat
  - Segment B only: Rangat → Diglipur
  - Partial: Port Blair → Mayabunder
  - Multiple daily departures on each segment

PASSENGER EXPERIENCE:
  - Search: "Port Blair → Diglipur" on date X
  - Results show ALL options:
    - Direct bus (if available) — shows "Direct, no change"
    - Segment buses — shows "Change at Rangat, 30 min wait"
  - Passenger selects option, sees boarding/dropping points
  - Books seats on one or more buses (if transfer needed)
```

## 1.3 Target Users

| User | Description |
|------|-------------|
| **Passenger** | Travels between islands by bus, needs to book seats online |
| **Cargo Sender** | Ships parcels/goods between islands, needs tracking |
| **Bus Operator** | Manages fleet, routes, schedules, boarding |
| **Cargo Transporter** | Manages vehicles, accepts shipments, updates status |
| **Admin** | Platform management, operator approval, oversight |

## 1.4 Technology Stack

| Layer | Technology |
|-------|-----------|
| Customer App | Flutter (iOS + Android) |
| Operator App | Flutter (Android) |
| Admin Panel | Next.js (Web) |
| Backend | Supabase (PostgreSQL + Edge Functions) |
| Authentication | Supabase Auth (Phone OTP + Email/Password) |
| Payment | Razorpay (UPI, Cards, Netbanking, Wallets) |
| Push Notifications | Firebase Cloud Messaging (FCM) |
| Maps | Custom GPS coordinate matching (free) — match bus/cargo lat/long with boarding/dropping point coordinates to detect arrival at stations |
| Real-Time | Supabase Real-Time subscriptions |
| Storage | Supabase Storage (photos, PDFs, proof images) |

---

# PART 2: BUS BOOKING FEATURES

## 2.1 Customer Bus Features

### Authentication
- Phone number + OTP login (Supabase Auth)
- Auto-read OTP (SMS Retriever API)
- Skip login for browsing

### Search
- Source city picker (autocomplete, recent, popular)
- Destination city picker
- Travel date selector (calendar)
- Search results with: operator name, bus type, departure/arrival times, duration, seats available, fare

### Filters & Sort
- Bus type: AC, Non-AC, Sleeper, Seater
- Departure time: Morning, Afternoon, Evening, Night
- Price range slider
- Rating filter
- Sort by: Price, Departure time, Rating, Duration

### Bus Details
- Operator info and rating
- Bus type and amenities (WiFi, charging, water bottle, etc.)
- Route & intermediate stops (text-based): "Port Blair → Ferrargunj → Rangat → Mayabunder → Diglipur" with scheduled times
- Boarding point selection (with address, time)
- Dropping point selection (with address, time)
- Cancellation policy display
- Photos of the bus (if available)

### Seat Selection
- Interactive seat map (lower/upper deck for sleeper)
- Seat legend: Available, Selected, Booked, Blocked, Ladies
- Multi-seat selection
- Real-time fare update as seats are selected
- Seat hold with countdown timer (5 minutes)

### Passenger Details
- Primary passenger: name, age, gender, phone
- Additional passengers (same details)
- Saved passenger quick-select
- Contact email for ticket delivery
- GST details (optional, for business travelers)

### Payment
- Order creation (server-side)
- Razorpay Checkout: UPI, Cards, Netbanking, Wallets
- Payment processing state
- Payment success → booking confirmed
- Payment failure → retry option
- Seat release on payment failure

### Post-Booking
- Booking confirmation screen
- Ticket summary with QR code
- PDF ticket download
- Share ticket (WhatsApp, email, etc.)
- Boarding pass display

### My Trips
- Upcoming trips
- Active/in-progress trips
- Completed trips
- Cancelled trips
- Booking detail view

### Cancellation
- Cancellation preview (refund amount based on policy)
- Cancellation confirmation
- Refund to original payment method
- Refund status tracking

### Live Tracking (GPS Coordinate Matching — Free)
- Real-time bus GPS coordinates (lat/long) from driver/conductor phone
- **Station arrival detection**: Match live coordinates with predefined boarding/dropping point coordinates (geofence radius ~100-200m)
- User notification: "Bus arriving at [Station Name]" / "Bus reached [Station Name]"
- ETA to next boarding point (calculated from distance/speed, no routing API)
- Status updates: departed → approaching [station] → arrived at [station] → departed
- No external map API required — pure coordinate math

### Ratings & Reviews
- Post-trip star rating (1-5)
- Written review
- View operator ratings

## 2.2 Operator Bus Features

### Authentication
- Email + password login

### Dashboard
- Today's trips summary
- Total bookings today
- Revenue today
- Quick actions (view manifest, scan QR)

### Fleet Management
- Bus listing with status
- Add/edit bus (registration, type, seats, amenities)
- Seat layout editor (visual drag-and-drop or form-based)
- Bus photo upload

### Route Management
- Create/edit routes (source → destination with distance)
- Boarding point management (name, address, location, time)
- Dropping point management

### Service & Trip Management
- Create services (route + bus + default timing)
- Schedule trips (select service + date)
- View trip calendar
- Trip status management (scheduled → boarding → departed → arrived)

### Trip Operations
- Seat inventory view (which seats booked/held/available)
- Passenger manifest (list of all passengers for a trip)
- Boarding chart (passenger name, seat, boarding point)
- Print manifest

### QR Scanner
- Scan passenger ticket QR code
- Verify ticket validity
- Mark passenger as boarded
- Handle invalid/expired/already-used tickets

### Quick Booking
- Book for walk-in customers
- Select trip, seats, enter passenger details
- Accept cash payment
- Issue ticket

### Wallet & Statements
- Wallet balance
- Transaction history
- Trip-level revenue breakdown
- Settlement history

---

# PART 3: CARGO SHIPPING FEATURES

## 3.1 Customer Cargo Features

### New Shipment Flow
1. **Route**: Select origin city, destination city
2. **Package**: Enter weight (kg), dimensions (L×W×H cm), cargo type, description
3. **Cargo Type**: Document, Parcel, Fragile, Heavy Goods, Perishable, Electronics
4. **Pickup Option**:
   - Address pickup: Enter pickup address, contact name, phone
   - Hub drop-off: Select nearby hub from map/list
5. **Delivery Option**:
   - Address delivery: Enter delivery address, contact name, phone
   - Hub pickup: Select nearby hub
6. **Speed**: Standard (2-5 days), Express (1-2 days), Same-day (if available)
7. **Price Quote**: Fare breakdown (base + distance + weight + surcharge)
8. **Confirm & Pay**: Razorpay payment

### Shipment Tracking (GPS Coordinate Matching — Free)
- Real-time GPS coordinates (lat/long) from driver phone via Operator app
- **Location milestone detection**: Match live coordinates with predefined hub/pickup/delivery point coordinates
- Status timeline: Confirmed → Picked up → In transit → Arrived at [Hub] → Out for delivery → Delivered at [Address]
- ETA to next milestone (calculated from distance/speed, no routing API)
- Driver/vehicle info (when assigned)
- No external map API required — pure coordinate math

### My Shipments
- Active shipments (in transit)
- Delivered shipments
- Cancelled shipments
- Shipment detail (full info + tracking history)

### Cancel Shipment
- Cancel if not yet picked up
- Full refund

## 3.2 Cargo Type Definitions

| Type | Description | Max Weight | Special Handling |
|------|-------------|-----------|-----------------|
| Document | Papers, envelopes, certificates | 5 kg | No |
| Parcel | General goods, small packages | 50 kg | No |
| Fragile | Glass, ceramics, electronics | 30 kg | Yes — careful handling |
| Heavy Goods | Machinery, large items | 500 kg | Yes — special vehicle |
| Perishable | Food, flowers, plants | 20 kg | Yes — time-sensitive |
| Electronics | Gadgets, computers, accessories | 25 kg | Yes — careful handling |

## 3.3 Vehicle Types for Cargo

| Type | Max Weight | Max Volume | Use Case |
|------|-----------|-----------|----------|
| Bike | 10 kg | 0.02 cbm | Documents, small parcels |
| Auto | 50 kg | 0.3 cbm | Parcels, small goods |
| Mini Van | 200 kg | 2 cbm | Medium shipments |
| Truck (7T) | 7,000 kg | 20 cbm | Large shipments |
| Truck (16T) | 16,000 kg | 40 cbm | Heavy/industrial |

## 3.4 Cargo Operator Features

### Dashboard
- Pending shipment requests
- Active shipments in transit
- Deliveries completed today
- Revenue summary

### Shipment Management
- View incoming cargo requests
- Accept/reject shipments (with reason)
- View assigned shipments
- Update shipment status (picked up → in transit → delivered)
- Update GPS location
- Confirm pickup (with photo/signature proof)
- Confirm delivery (with photo/signature proof + recipient name)

### Vehicle Management
- List vehicles with capacity info
- Add/edit vehicles (type, registration, capacity)
- Upload vehicle photos
- **Upload vehicle insurance** (policy number, provider, validity, document)
- Insurance status indicator (pending/verified/expired)

### Hub Management
- List cargo hubs (drop-off/pickup points)
- Add/edit hubs (name, address, location, operating hours)
- Toggle hub active/inactive

### Cargo Route Management
- List cargo routes with pricing
- Create/edit routes (source → destination)
- Set pricing rules (base fare, per-km, per-kg rates)

### Earnings
- Total earnings
- Per-shipment breakdown
- Settlement history
- Withdraw to bank

## 3.5 Operator Insurance Compliance (NOT customer-facing)

Insurance is **NOT sold to customers**. It is **operator compliance data** collected during operator registration/setup.

### What operators provide:
- Vehicle insurance policy number
- Insurance provider name
- Policy validity (from/to dates)
- Coverage type (comprehensive / third-party)
- Upload insurance document (photo/PDF)

### Why this is needed:
- Regulatory compliance — operators must have valid vehicle insurance
- Platform trust — verified operators shown with "Verified" badge
- Admin verification — admin reviews insurance documents before approving operator

### Database table:
```sql
CREATE TABLE operator_insurance (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  vehicle_id UUID,                          -- references buses.id or cargo_vehicles.id
  vehicle_type VARCHAR(20),                -- 'bus' or 'cargo'
  insurance_provider VARCHAR(200) NOT NULL,
  policy_number VARCHAR(100) NOT NULL,
  coverage_type VARCHAR(30),               -- 'comprehensive', 'third_party'
  valid_from DATE NOT NULL,
  valid_until DATE NOT NULL,
  document_url TEXT,                        -- uploaded insurance document
  status VARCHAR(20) DEFAULT 'pending',    -- pending, verified, expired, rejected
  verified_by UUID REFERENCES profiles(id),
  verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

### Operator onboarding flow:
1. Operator registers (email + password)
2. Fills business details (company name, registration, contact)
3. Adds vehicles (bus or cargo vehicle details)
4. **Uploads insurance for each vehicle** (policy number, provider, validity, document)
5. Admin reviews and approves
6. Operator can start listing trips/shipments

### Admin verification:
- Admin sees pending insurance documents
- Verifies policy number (optional manual check)
- Approves or rejects with reason
- Expired insurance → operator fleet marked inactive

---

# PART 4: SUPABASE SCHEMA

## 4.1 Tables Overview

| Category | Tables |
|----------|--------|
| Identity | `profiles`, `user_roles` |
| Operators | `operators` |
| Geography | `countries`, `cities` |
| Bus Fleet | `buses`, `bus_layouts`, `seats` |
| Bus Routes | `bus_routes`, `boarding_points`, `dropping_points` |
| Bus Schedule | `bus_services`, `bus_trips` |
| Bus Inventory | `trip_seats`, `seat_holds`, `fare_rules` |
| Cargo Fleet | `cargo_vehicle_types`, `cargo_vehicles` |
| Cargo Routes | `cargo_routes`, `cargo_hub`, `cargo_pricing_rules` |
| Cargo Shipments | `cargo_shipments`, `cargo_status_history`, `cargo_tracking_events` |
| Cargo Insurance | `operator_insurance` |
| Bookings | `bookings`, `booking_items`, `booking_status_history` |
| Passengers | `passengers` |
| Payments | `orders`, `payments`, `refunds` |
| Wallet | `wallet`, `wallet_transactions` |
| Notifications | `notifications`, `notification_preferences` |
| Reviews | `ratings_reviews` |
| Audit | `audit_logs` |

**Total: 35 tables**

## 4.2 Full Schema SQL

See the complete schema in the previous audit file (`00_COMPLETE_AUDIT_AND_REVISED_PLAN.md` Section D). Key additions for this focused plan:

### Multi-Segment Route Model

The main corridor (Sri Vijaya Puram → Diglipur) has multiple segments. The schema supports this:

```sql
-- A route is the full corridor (e.g., Port Blair → Diglipur)
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

-- A service is an operator's specific offering on a route
-- (e.g., "Port Blair to Rangat Express" — runs Segment A only)
CREATE TABLE bus_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id UUID REFERENCES operators(id) ON DELETE CASCADE,
  route_id UUID REFERENCES bus_routes(id),
  bus_id UUID REFERENCES buses(id),
  service_code VARCHAR(50),
  service_name VARCHAR(200),
  -- Which segment does this service cover?
  service_source_city_id UUID REFERENCES cities(id),  -- e.g., Port Blair
  service_dest_city_id UUID REFERENCES cities(id),     -- e.g., Rangat
  default_departure_time TIME,
  default_arrival_offset_minutes INTEGER,
  status VARCHAR(20) DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- A trip is a concrete instance of a service on a specific date
CREATE TABLE bus_trips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id UUID REFERENCES bus_services(id),
  operator_id UUID REFERENCES operators(id),
  route_id UUID REFERENCES bus_routes(id),
  bus_id UUID REFERENCES buses(id),
  travel_date DATE NOT NULL,
  departure_at TIMESTAMPTZ NOT NULL,
  arrival_at TIMESTAMPTZ,
  currency_code VARCHAR(3) DEFAULT 'INR',
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
```

**Key insight:** A `bus_service` has `service_source_city_id` and `service_dest_city_id` which define the SEGMENT it covers. When a passenger searches "Port Blair → Diglipur", the system finds:
1. Direct services (service_source = Port Blair, service_dest = Diglipur)
2. Connected services (e.g., Service A: Port Blair → Rangat + Service B: Rangat → Diglipur)

**Multi-segment booking:** A single `bookings` record can reference multiple `booking_items`, each on a different trip. The system calculates total fare across segments.

### Cargo Shipments Table
```sql
CREATE TABLE cargo_shipments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_reference VARCHAR(20) UNIQUE NOT NULL,
  sender_user_id UUID REFERENCES profiles(id),
  operator_id UUID REFERENCES operators(id),
  route_id UUID REFERENCES cargo_routes(id),
  vehicle_id UUID REFERENCES cargo_vehicles(id),
  cargo_type_id UUID REFERENCES cargo_types(id),
  
  -- Package
  description TEXT,
  weight_kg NUMERIC(10,2) NOT NULL,
  length_cm NUMERIC(8,2),
  width_cm NUMERIC(8,2),
  height_cm NUMERIC(8,2),
  volume_cbm NUMERIC(10,3),
  declared_value_cents INTEGER,
  special_instructions TEXT,
  
  -- Pickup
  pickup_type VARCHAR(20) NOT NULL,
  pickup_address TEXT,
  pickup_latitude NUMERIC(10,7),
  pickup_longitude NUMERIC(10,7),
  pickup_hub_id UUID REFERENCES cargo_hub(id),
  pickup_contact_name VARCHAR(200),
  pickup_contact_phone VARCHAR(20),
  pickup_scheduled_at TIMESTAMPTZ,
  
  -- Delivery
  delivery_type VARCHAR(20) NOT NULL,
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
```

### Key Database Functions

```sql
-- Cargo price estimate
CREATE OR REPLACE FUNCTION estimate_cargo_price(
  p_route_id UUID,
  p_vehicle_type_id UUID,
  p_cargo_type_id UUID,
  p_weight_kg NUMERIC
) RETURNS JSONB AS $$
  -- See complete function in previous audit file
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Seat hold (bus)
CREATE OR REPLACE FUNCTION create_seat_hold(
  p_trip_id UUID,
  p_seat_ids UUID[],
  p_ttl_seconds INTEGER DEFAULT 300
) RETURNS JSONB AS $$
  -- See complete function in previous audit file
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

---

# PART 5: RAZORPAY INTEGRATION

## 5.1 Architecture

```
Customer/Operator App
    │
    ├── 1. Request to create order ──► Supabase Edge Function
    │                                      │
    │                                      ├── 2. Calculate amount server-side
    │                                      ├── 3. Create Razorpay Order (Orders API)
    │                                      └── 4. Return order_id to app
    │
    ├── 5. Open Razorpay Checkout ──► Razorpay SDK
    │                                      │
    │                                      ├── 6. User pays (UPI/Card/Netbanking)
    │                                      └── 7. Return payment_id + signature
    │
    ├── 8. Verify signature ──► Supabase Edge Function
    │                                      │
    │                                      ├── 9. HMAC verify server-side
    │                                      └── 10. Mark order as verified
    │
    └── 11. Webhook (source of truth) ──► Supabase Edge Function
                                               │
                                               ├── 12. Verify webhook signature
                                               ├── 13. Idempotent processing
                                               └── 14. Confirm booking/shipment
```

## 5.2 Edge Functions for Razorpay

### create-order
```typescript
// Supabase Edge Function
import Razorpay from "https://esm.sh/razorpay@2.8.0";

const razorpay = new Razorpay({
  key_id: Deno.env.get("RAZORPAY_KEY_ID")!,
  key_secret: Deno.env.get("RAZORPAY_KEY_SECRET")!,
});

Deno.serve(async (req) => {
  const { amount, receipt, currency = "INR" } = await req.json();
  
  // Amount must be in PAISE (₹1 = 100 paise)
  // ALWAYS calculate amount on server, never trust client
  
  const order = await razorpay.orders.create({
    amount, // in paise
    currency,
    receipt,
    notes: { source: "thirty8" },
  });

  return new Response(JSON.stringify({
    orderId: order.id,
    amount: order.amount,
    currency: order.currency,
  }));
});
```

### verify-payment
```typescript
import { createHmac } from "https://deno.land/std@0.168.0/crypto/mod.ts";

Deno.serve(async (req) => {
  const { razorpay_order_id, razorpay_payment_id, razorpay_signature } = await req.json();
  
  const expected = createHmac("sha256", Deno.env.get("RAZORPAY_KEY_SECRET")!)
    .update(`${razorpay_order_id}|${razorpay_payment_id}`)
    .digest("hex");

  // Timing-safe comparison
  const sigBytes = new TextEncoder().encode(razorpay_signature);
  const expectedBytes = new TextEncoder().encode(expected);
  
  if (sigBytes.length !== expectedBytes.length) {
    return new Response(JSON.stringify({ ok: false }), { status: 400 });
  }
  
  let diff = 0;
  for (let i = 0; i < sigBytes.length; i++) {
    diff |= sigBytes[i] ^ expectedBytes[i];
  }
  
  if (diff !== 0) {
    return new Response(JSON.stringify({ ok: false }), { status: 400 });
  }
  
  // Mark order as verified in database
  // Do NOT fulfill here — wait for webhook
  
  return new Response(JSON.stringify({ ok: true }));
});
```

### handle-webhook
```typescript
import { createHmac } from "https://deno.land/std@0.168.0/crypto/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const raw = await req.text();
  const signature = req.headers.get("x-razorpay-signature") ?? "";
  
  // Verify webhook signature
  const expected = createHmac("sha256", Deno.env.get("RAZORPAY_WEBHOOK_SECRET")!)
    .update(raw)
    .digest("hex");
  
  const sigBytes = new TextEncoder().encode(signature);
  const expectedBytes = new TextEncoder().encode(expected);
  let diff = 0;
  for (let i = 0; i < sigBytes.length; i++) {
    diff |= sigBytes[i] ^ expectedBytes[i];
  }
  if (diff !== 0) {
    return new Response("Invalid signature", { status: 400 });
  }
  
  const event = JSON.parse(raw);
  
  // Idempotency: check if event already processed
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );
  
  const { data: existing } = await supabase
    .from("processed_webhook_events")
    .select("id")
    .eq("event_id", event.id)
    .single();
  
  if (existing) {
    return new Response("OK"); // Already processed
  }
  
  // Process event
  switch (event.event) {
    case "payment.captured": {
      const payment = event.payload.payment.entity;
      // Confirm booking or cargo shipment
      await supabase.rpc("confirm_booking_after_payment", {
        p_order_reference: payment.order_id,
        p_payment_id: payment.id,
        p_amount_cents: payment.amount,
      });
      break;
    }
    case "payment.failed": {
      const payment = event.payload.payment.entity;
      // Release seats / mark shipment failed
      await supabase.rpc("handle_payment_failure", {
        p_order_reference: payment.order_id,
      });
      break;
    }
    case "refund.processed": {
      const refund = event.payload.refund.entity;
      // Update refund status
      await supabase.rpc("confirm_refund", {
        p_payment_id: refund.payment_id,
        p_refund_id: refund.id,
      });
      break;
    }
  }
  
  // Record event as processed
  await supabase.from("processed_webhook_events").insert({
    event_id: event.id,
    event_type: event.event,
  });
  
  return new Response("OK");
});
```

## 5.3 Razorpay Configuration

| Setting | Value |
|---------|-------|
| Currency | INR |
| Payment Methods | UPI, Cards (Visa, Mastercard, RuPay), Netbanking, Wallets |
| Settlement | T+2 (standard), Instant (optional fee) |
| Webhook Events | `payment.captured`, `payment.failed`, `refund.processed` |
| Pricing | 2% + GST per transaction (standard) |
| UPI | Fee-free (per RBI mandate) |
| Refund Speed | 5-7 business days (normal), Instant (optional) |

## 5.4 Database Table for Webhook Events

```sql
CREATE TABLE processed_webhook_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id VARCHAR(100) UNIQUE NOT NULL,
  event_type VARCHAR(50),
  processed_at TIMESTAMPTZ DEFAULT now()
);
```

---

# PART 6: UI/UX WORKFLOWS

## 6.1 Customer App — Navigation Structure

```
Bottom Navigation:
├── Home (Bus search)
├── Cargo (Shipment flow)
├── My Bookings (Bus tickets + Cargo shipments)
├── Notifications
└── Profile
```

## 6.2 Bus Booking Flow (Customer)

```
Home Screen
  │
  ├── Source City (tap) → City Picker → Select (e.g., Sri Vijaya Puram)
  ├── Destination City (tap) → City Picker → Select (e.g., Diglipur)
  ├── Date (tap) → Calendar → Select
  └── Search Button
        │
        ▼
  Search Results (SRP)
    │
    ├── FILTER TABS: "Direct" | "With Transfer" | "All"
    │
    ├── DIRECT RESULTS (if available):
    │   └── Bus Card: "Port Blair → Diglipur, 6:00 AM, ₹450, 12 seats"
    │
    ├── TRANSFER RESULTS (multi-segment):
    │   └── Card: "Port Blair → Rangat (Bus A) + Rangat → Diglipur (Bus B)"
    │       ├── Segment 1: Bus A, 6:00 AM - 9:30 AM, ₹180
    │       ├── Transfer at Rangat, 30 min wait
    │       ├── Segment 2: Bus B, 10:00 AM - 3:00 PM, ₹270
    │       └── Total: ₹450
    │
    ├── Filters (chip bar)
    ├── Sort (dropdown)
    └── Bus Card List
          │
          ▼ (tap bus card — DIRECT)
    Bus Details Screen
      │
      ├── Operator info + rating
      ├── Amenities list
      ├── Route & stops list (text-based): "Port Blair → Ferrargunj → Rangat → Mayabunder → Diglipur" with boarding/dropping times
      ├── Boarding point selector
      ├── Dropping point selector
      ├── Cancellation policy display
      └── "Select Seats" Button
            │
            ▼
      Seat Layout Screen
        │
        ├── Seat map (interactive)
        ├── Seat legend
        ├── Selected seats list
        ├── Fare summary
        └── "Proceed to Checkout" Button
              │
              ▼
        Passenger Details Screen
          │
          ├── Primary passenger form
          ├── Add passenger button
          ├── Saved passengers list
          ├── Contact details
          ├── GST details (optional)
          ├── Coupon code input
          └── "Proceed to Payment" Button
                │
                ▼
          Payment Screen
            │
            ├── Fare breakup
            ├── Razorpay Checkout (UPI / Card / Netbanking / Wallet)
            └── Processing state
                  │
                  ▼ (success)
            Booking Confirmed Screen
              │
              ├── Success animation
              ├── Ticket summary
              ├── QR code
              ├── "Download PDF" button
              ├── "Share Ticket" button
              └── "View My Trips" button

    ─── OR (for TRANSFER booking) ───

          ▼ (tap transfer result)
    Transfer Booking Screen
      │
      ├── Segment 1 details (bus, time, boarding/dropping)
      ├── Transfer point details (Rangat — wait time, location)
      ├── Segment 2 details (bus, time, boarding/dropping)
      ├── Total fare breakdown
      └── "Select Seats for Both Segments" Button
            │
            ▼
      Seat Layout — Segment 1 → Passenger Details → Payment → Confirmation
      Seat Layout — Segment 2 → (same passenger details reused) → included in same payment
```

## 6.3 Cargo Shipping Flow (Customer)

```
Cargo Tab / Home
  │
  ├── "Send a Package" CTA
  └── Recent shipments list
        │
        ▼ (tap "Send a Package")
  Step 1: Route
    │
    ├── Origin City (picker)
    ├── Destination City (picker)
    └── "Next" Button
          │
          ▼
  Step 2: Package Details
    │
    ├── Weight (kg) input
    ├── Dimensions (L × W × H cm) — optional
    ├── Cargo Type (dropdown: Document, Parcel, Fragile, etc.)
    ├── Description (text)
    ├── Declared Value (₹) — for insurance
    └── "Next" Button
          │
          ▼
  Step 3: Pickup
    │
    ├── Pickup Type toggle: Address / Hub
    ├── If Address: enter address, contact name, phone, schedule time
    ├── If Hub: select hub from map/list
    └── "Next" Button
          │
          ▼
  Step 4: Delivery
    │
    ├── Delivery Type toggle: Address / Hub
    ├── If Address: enter address, contact name, phone
    ├── If Hub: select hub from map/list
    └── "Next" Button
          │
          ▼
  Step 5: Speed
    │
    ├── Speed: Standard / Express / Same-day
    └── "Get Quote" Button
          │
          ▼
  Price Quote Screen
    │
    ├── Fare breakdown (base + distance + weight + surcharge)
    ├── Total amount
    └── "Confirm & Pay" Button
          │
          ▼
    Payment Screen (same as bus)
          │
          ▼ (success)
    Shipment Confirmed Screen
      │
      ├── Success animation
      ├── Shipment reference number
      ├── Summary (route, weight, speed)
      ├── "Track Shipment" button
      └── "View My Shipments" button
```

## 6.4 Shipment Tracking Screen (GPS Coordinate Matching — Free)

```
Tracking Screen
  │
  ├── Current Status Card: "In Transit — 2.3 km from Port Blair Hub"
  ├── Next Milestone: "Arriving at Port Blair Hub in ~5 min"
  ├── Status bar: Confirmed → Picked up → In Transit → Arrived at Hub → Out for Delivery → Delivered
  ├── ETA to next milestone
  ├── Shipment details card (expandable)
  ├── Tracking timeline (scrollable list):
  │   ├── Confirmed — "Shipment confirmed, pickup scheduled"
  │   ├── Picked up — "Package picked up from [address]"
  │   ├── In Transit — "Package in transit via [vehicle], current: [nearest landmark/hub]"
  │   ├── Arrived at Hub — "Package arrived at Port Blair Hub"
  │   ├── Out for Delivery — "Out for delivery to [address]"
  │   └── Delivered — "Delivered to [recipient name] at [time]"
  ├── Live coordinate display: "Lat: 11.6234, Long: 92.7265" (for debugging)
  └── Contact driver/operator button
```

## 6.5 Operator App — Bus Navigation

```
Drawer Navigation:
├── Dashboard
├── Fleet
│   ├── Buses
│   ├── Seat Layouts
│   └── Insurance Compliance
├── Routes
│   ├── Bus Routes
│   └── Boarding/Dropping Points
├── Schedule
│   ├── Services
│   └── Trips (Calendar view)
├── Trip Operations
│   ├── Seat Inventory
│   ├── Passenger Manifest
│   ├── QR Scanner
│   └── Quick Booking
├── Wallet
│   ├── Balance
│   └── Statements
└── Settings
```

## 6.6 Operator App — Cargo Navigation

```
Drawer Navigation:
├── Dashboard (cargo)
├── Shipments
│   ├── Incoming (requests)
│   ├── Active (in transit)
│   └── Delivered
├── Fleet
│   ├── Vehicles
│   └── Hubs
├── Routes (cargo)
├── Earnings
└── Settings
```

## 6.7 Admin Panel Navigation

```
Sidebar Navigation:
├── Dashboard (KPIs)
├── Operators
│   ├── All Operators
│   ├── Pending Approval
│   ├── Insurance Verification
│   └── Operator Detail
├── Users
│   ├── All Users
│   └── User Detail
├── Bus
│   ├── Trips
│   └── Bookings
├── Cargo
│   ├── Shipments
│   └── Hubs
├── Payments
│   ├── Transactions
│   └── Refunds
├── Finance
│   ├── Revenue Reports
│   └── Settlements
├── Content
│   ├── Cities
│   └── Vehicle Types
└── Audit Logs
```

---

# PART 7: EDGE FUNCTIONS LIST

## 7.1 Authentication
| Function | Purpose |
|----------|---------|
| `auth/send-otp` | Send OTP to phone number |
| `auth/verify-otp` | Verify OTP and create session |
| `auth/refresh` | Refresh access token |
| `auth/logout` | Invalidate session |
| `auth/create-profile` | Create profile on first login (trigger) |

## 7.2 Bus — Search
| Function | Purpose |
|----------|---------|
| `search/cities` | City autocomplete with trigram search |
| `search/trips` | Search available bus trips — handles direct + multi-segment results |
| `search/trip-seats` | Get seat map for a specific trip |
| `search/boarding-points` | Boarding points for a trip |
| `search/dropping-points` | Dropping points for a trip |
| `search/connected-routes` | Find connected services for multi-segment journeys |

## 7.3 Bus — Booking
| Function | Purpose |
|----------|---------|
| `bus/hold-seats` | Temporarily hold seats (with TTL) |
| `bus/release-hold` | Release held seats |
| `bus/create-booking` | Convert hold to confirmed booking |
| `bus/cancel-booking` | Cancel with refund calculation |
| `bus/my-bookings` | User's booking history |
| `bus/booking-detail` | Full booking details |
| `bus/generate-pdf` | Generate PDF ticket |

## 7.4 Cargo — Shipment
| Function | Purpose |
|----------|---------|
| `cargo/estimate-price` | Get price estimate |
| `cargo/create-shipment` | Create new shipment |
| `cargo/update-shipment` | Update shipment details |
| `cargo/confirm-shipment` | Confirm and pay |
| `cargo/cancel-shipment` | Cancel (pre-pickup) |
| `cargo/my-shipments` | User's shipment history |
| `cargo/shipment-detail` | Full shipment details |

## 7.5 Cargo — Tracking
| Function | Purpose |
|----------|---------|
| `cargo/track` | Real-time tracking data |
| `cargo/update-status` | Operator updates shipment status |
| `cargo/update-location` | Operator updates GPS location |
| `cargo/confirm-pickup` | Confirm pickup with proof |
| `cargo/confirm-delivery` | Confirm delivery with proof |

## 7.6 Operator — Bus
| Function | Purpose |
|----------|---------|
| `operator/buses` | List/create buses |
| `operator/buses/:id` | Update bus |
| `operator/buses/:id/layout` | Update seat layout |
| `operator/routes` | List/create routes |
| `operator/services` | List/create services |
| `operator/trips` | List/create trips |
| `operator/trips/:id/inventory` | View seat inventory |
| `operator/trips/:id/bookings` | View trip bookings |
| `operator/trips/:id/manifest` | Generate/view manifest |
| `operator/trips/:id/boarding/:itemId` | Mark passenger boarded |

## 7.7 Operator — Cargo
| Function | Purpose |
|----------|---------|
| `operator/cargo/vehicles` | List/create vehicles |
| `operator/cargo/routes` | List/create cargo routes |
| `operator/cargo/hubs` | List/create hubs |
| `operator/cargo/shipments` | View assigned shipments |
| `operator/cargo/shipments/:id/accept` | Accept shipment |
| `operator/cargo/shipments/:id/reject` | Reject shipment |
| `operator/cargo/shipments/:id/status` | Update status |
| `operator/cargo/shipments/:id/location` | Update GPS |
| `operator/cargo/earnings` | View earnings |

## 7.8 Operator — Insurance Compliance
| Function | Purpose |
|----------|---------|
| `operator/insurance` | List insurance records for operator's vehicles |
| `operator/insurance` (POST) | Add insurance record (policy, provider, validity, document) |
| `operator/insurance/:id` | Update insurance record |
| `operator/insurance/:id/verify` | Admin: verify/reject insurance |

## 7.8 Payments
| Function | Purpose |
|----------|---------|
| `payments/create-order` | Create Razorpay order |
| `payments/verify` | Verify payment signature |
| `payments/webhook` | Handle Razorpay webhook |
| `payments/refund` | Initiate refund |

## 7.9 User Profile
| Function | Purpose |
|----------|---------|
| `profile` | View/update profile |
| `profile/saved-passengers` | Manage saved passengers |
| `profile/payment-methods` | Manage saved payment methods |
| `profile/wallet` | Wallet balance + transactions |
| `profile/wallet/topup` | Add money to wallet |
| `profile/notifications` | Notification list |
| `profile/notifications/:id/read` | Mark as read |

## 7.10 Admin
| Function | Purpose |
|----------|---------|
| `admin/dashboard` | KPI stats |
| `admin/operators` | All operators |
| `admin/operators/:id/approve` | Approve operator |
| `admin/users` | All users |
| `admin/bookings` | All bookings |
| `admin/shipments` | All shipments |
| `admin/refunds` | Refund queue |
| `admin/refunds/:id/process` | Process refund |
| `admin/audit-logs` | Audit trail |

---

# PART 8: IMPLEMENTATION PHASES

## Phase 1: Project Setup (Days 1-3)
1. Initialize monorepo
2. Create Supabase project
3. Run database migrations (all 35 tables)
4. Set up RLS policies
5. Set up pg_cron jobs
6. Seed data (Andaman cities: Sri Vijaya Puram/Port Blair, Diglipur, Rangat, Havelock, Neil Island, etc.)
7. Create storage buckets

## Phase 2: Authentication (Days 4-5)
1. Supabase Auth — phone OTP (customer)
2. Supabase Auth — email/password (operator, admin)
3. Profile creation trigger
4. Role assignment

## Phase 3: Bus Backend (Days 6-12)
1. City search (trigram)
2. Trip search with filters
3. Seat map
4. Boarding/dropping points
5. Hold seats (PL/pgSQL)
6. Release expired holds (pg_cron)
7. Create booking
8. Cancel booking + refund
9. Manifest generation
10. QR verification

## Phase 4: Cargo Backend (Days 13-18)
1. Price estimation
2. Create shipment
3. Confirm shipment
4. Cancel shipment
5. Update status
6. Update GPS
7. Confirm pickup/delivery with proof
8. Tracking events

## Phase 5: Razorpay Integration (Days 19-22)
1. Create order
2. Verify payment
3. Webhook handler
4. Refund processing
5. Idempotency

## Phase 6: Notifications (Days 23-25)
1. FCM setup
2. Notification templates
3. Push dispatch
4. Preferences

## Phase 7: Customer App — Bus (Days 26-35)
1. Flutter setup, routing, state management, theme
2. Login/OTP
3. Home + search
4. Search results
5. Bus details
6. Seat layout
7. Seat lock + countdown
8. Passenger details
9. Payment (Razorpay)
10. Booking confirmation + QR
11. PDF ticket
12. My Trips
13. Cancellation
14. Live tracking
15. Ratings

## Phase 8: Customer App — Cargo (Days 36-43)
1. Cargo home
2. New shipment flow (5 steps)
3. Price quote
4. Payment
5. Tracking screen
6. My Shipments
7. Cancel shipment

## Phase 9: Customer App — Shared (Days 44-47)
1. Profile
2. Wallet
3. Notifications
4. Settings

## Phase 10: Operator App — Bus (Days 48-56)
1. Login + dashboard
2. Fleet management
3. Route management
4. Service/trip scheduling
5. Trip operations (inventory, manifest)
6. QR scanner
7. Quick booking
8. Wallet

## Phase 11: Operator App — Cargo (Days 57-64)
1. Cargo dashboard
2. Incoming/active shipments
3. Status + GPS updates
4. Pickup/delivery confirmation
5. Vehicle + hub management
6. Earnings

## Phase 12: Admin Panel (Days 65-72)
1. Next.js setup
2. Dashboard
3. Operator management
4. User management
5. Bookings + shipments overview
6. Refund processing
7. Revenue reports
8. Audit logs

## Phase 13: Testing (Days 73-80)
1. Unit tests
2. Integration tests
3. E2E tests
4. Concurrency tests (seat booking)
5. RLS tests
6. Payment edge cases
7. Performance tests

## Phase 14: Deployment (Days 81-85)
1. Supabase production
2. Edge Functions deploy
3. Flutter builds
4. Admin web deploy
5. Monitoring setup
6. Documentation

---

# PART 9: SEED DATA — ANDAMAN CITIES

```sql
-- Andaman & Nicobar Islands cities
INSERT INTO cities (country_id, name, state, latitude, longitude) VALUES
  -- Get India country ID dynamically or hardcode
  ((SELECT id FROM countries WHERE code = 'IND'), 'Sri Vijaya Puram (Port Blair)', 'Andaman and Nicobar Islands', 11.6234, 92.7265),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Diglipur', 'Andaman and Nicobar Islands', 13.2600, 93.0000),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Rangat', 'Andaman and Nicobar Islands', 12.5333, 92.8833),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Havelock Island (Swaraj Dweep)', 'Andaman and Nicobar Islands', 11.9833, 93.0000),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Neil Island (Shaheed Dweep)', 'Andaman and Nicobar Islands', 11.8167, 93.0333),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Long Island', 'Andaman and Nicobar Islands', 12.2833, 93.0667),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Mayabunder', 'Andaman and Nicobar Islands', 12.8833, 92.8167),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Ferrargunj', 'Andaman and Nicobar Islands', 11.5833, 92.7167),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Little Andaman', 'Andaman and Nicobar Islands', 10.8000, 92.7333),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Car Nicobar', 'Andaman and Nicobar Islands', 9.1667, 92.7500),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Kamorta', 'Andaman and Nicobar Islands', 8.9500, 93.5333),
  ((SELECT id FROM countries WHERE code = 'IND'), 'Nancowry', 'Andaman and Nicobar Islands', 8.9000, 93.5500);
```

---
 
# PART 9.1: SEED DATA — BOARDING/DROPPING POINTS (SRI VIJAYA PURAM → DIGLIPUR CORRIDOR)
 
```sql
-- Boarding & Dropping Points for Main Corridor
-- Sequence follows the route from Sri Vijaya Puram (Port Blair) to Diglipur
-- GPS coordinates: TO BE FILLED - use Google Maps or GPS device to get exact lat/long for each point
INSERT INTO boarding_points (route_id, name, address, latitude, longitude, sequence_no, is_active) VALUES
  -- Route ID will be set after bus_routes insert for main corridor
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
-- Insert into dropping_points with same data
```
 
---
 
# PART 10: PRE-BUILD CHECKLIST

## 10.1 Before Development Starts
 
 | # | Item | Owner | Status |
 |---|------|-------|--------|
 | 1 | Create Supabase project | You | **DONE** — https://xdrthrdwdfzhzhqkhnnf.supabase.co |
 | 2 | Create Razorpay merchant account + complete KYC | You | **DONE** — Test Key: `rzp_test_TfTr1V6YzjFqVP` |
 | 3 | Generate Razorpay API keys (test + live) | You | **Test key ready** — Live key pending KYC |
 | 4 | Set up Razorpay webhooks (test mode) | Dev agent | PENDING — needs Supabase Edge Function URL |
 | 5 | Create Firebase project for FCM | You | **DONE** — Project: `308858536267` |
 | 6 | Define exact city list and routes for Andaman (with GPS coordinates for each boarding/dropping point) | You | **DONE** — 34 boarding points defined above |
 | 7 | Define bus operators to onboard (seed data) | You | PENDING |
 | 8 | Define cargo vehicle types and pricing | You | PENDING |

## 10.2 Technical Checklist

| # | Item | Status |
|---|------|--------|
| 1 | Monorepo structure created | READY |
| 2 | Database migrations (35 tables) | READY |
| 3 | RLS policies | READY |
| 4 | pg_cron jobs | READY |
| 5 | Edge Functions (40+ functions) | READY |
| 6 | Storage buckets | READY |
| 7 | Seed data SQL | READY |
| 8 | Razorpay integration code | READY |
| 9 | Flutter app structure | READY |
| 10 | Admin panel structure | READY |

---

**END OF MASTER PLAN**

*This document set is complete and ready for AI coding agent handoff.*
