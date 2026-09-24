# 10 — Thirty8 UI Design System Derived from Reference Patterns

## Principle

Use the reference apps for **functional composition patterns** and information hierarchy. Build original Thirty8 visual design tokens.

## Core components

### Customer

- top app bar
- source/destination selector
- date picker
- trip/service card
- filter chips
- sort sheet
- seat map
- seat legend
- fare summary
- boarding/drop selector
- passenger card
- payment method card
- countdown/hold banner
- booking success card
- QR ticket card
- trip status card
- cancellation sheet
- refund status card
- profile menu

### Operator

- operator header
- trip/date selector
- inventory table/grid
- seat map
- quick booking form
- passenger table
- boarding chart
- manifest
- QR scanner
- driver/co-driver assignment
- print/share action sheet
- statement table
- wallet/balance card

### Admin

- navigation rail
- KPI cards
- filters/date range
- operator table
- trip inventory table
- booking table
- refund queue
- audit log viewer

## State variants every reusable component should support

- loading
- success
- empty
- disabled
- validation error
- server error
- retry
- permission denied

## Seat component states

At minimum:

- available
- selected
- booked
- blocked
- reserved/held
- gender-constrained
- boarded where shown in operator context

Use a legend and do not rely on color alone; include icon/label semantics for accessibility.
