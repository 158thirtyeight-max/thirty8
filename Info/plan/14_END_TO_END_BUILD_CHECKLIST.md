# 14 — A-to-Z Build Checklist for the Coding Agent

## Step 1 — Analyze references

- validate package identities
- hash inputs
- inspect base/split APKs
- inventory resources/classes/endpoints
- produce evidence labels

## Step 2 — Create Thirty8 architecture

- monorepo
- backend
- database
- customer app
- operator app
- admin web

## Step 3 — Database

- migrations
- constraints
- indexes
- seed cities/routes/operators/buses
- seat-layout templates
- audit tables

## Step 4 — Authentication

- customer OTP/auth
- operator staff auth
- RBAC
- refresh/session handling

## Step 5 — Operator configuration

- operator
- staff
- buses
- seat layouts
- routes
- services
- boarding/dropping points
- trips

## Step 6 — Search

- city lookup
- route search
- trip search
- filtering/sort
- service details

## Step 7 — Inventory

- seat map
- availability endpoint
- hold endpoint
- expiration worker
- operator block/unblock

## Step 8 — Booking/payment

- quote
- order
- payment provider adapter
- webhook verification
- booking confirmation
- cancellation/refund
- reconciliation

## Step 9 — Customer post-booking

- tickets
- QR
- My Trips
- tracking
- support

## Step 10 — Operator operations

- booking lookup
- quick booking
- passenger list
- manifest
- boarding
- QR scanning
- driver assignment
- print/export

## Step 11 — Admin

- operators
- users
- trips
- bookings
- refunds
- audit logs
- configuration

## Step 12 — QA

Minimum mandatory tests:

- two customers booking the same seat simultaneously
- customer vs operator racing for same seat
- hold expiration
- payment success after client timeout
- duplicate webhook
- cancellation/refund
- unauthorized operator access
- QR replay
- trip closure
- offline/reconnect recovery

## Definition of done

The agent must not declare the project complete merely because the apps compile. It is complete only when:

- database migrates from empty state
- seed/demo data loads
- customer can search → seat-hold → pay sandbox → receive ticket
- operator sees the same booking immediately
- operator can generate manifest
- operator can verify QR/boarding
- cancellation/refund state is reflected for both clients
- audit trail exists
- automated tests pass
- docs describe deployment and rollback
