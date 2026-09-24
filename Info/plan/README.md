Akshay Kumar # Thirty8 Bus Booking — Reverse Engineering & Build Handoff Pack

## Purpose

This pack is the working specification for building an independent **Thirty8** bus-booking platform from observable evidence in two supplied Android references:

- verified redBus customer XAPK, version 82.5.5
- redBus Plus operator APK, version 2.0.6

The goal is not to recover or reuse proprietary redBus server source code. The goal is to extract **observable product behavior, client architecture, workflows, data concepts, state transitions, API clues, and UI information architecture**, then implement an original Thirty8 system around the same functional problem space.

## Core Thirty8 architecture

```text
                         THIRTY8 BACKEND
                    ┌───────────────────────┐
                    │ Auth & RBAC           │
                    │ Operators & Fleet     │
                    │ Routes & Trips        │
                    │ Seat Inventory        │
                    │ Bookings              │
                    │ Payments / Refunds    │
                    │ Manifests / Boarding  │
                    │ Notifications         │
                    │ Support / Audit       │
                    └───────────┬───────────┘
                                │
             ┌──────────────────┼──────────────────┐
             │                  │                  │
             ▼                  ▼                  ▼
       Customer App       Operator App        Admin Web
          Flutter             Flutter/Web        Web

                    ONE AUTHORITATIVE DATABASE
```

## Important distinction

The two reference apps do **not** prove that redBus literally uses one physical database. The customer client exposes hosts such as `capi.redbus.com`, while the operator APK exposes `plusmobapi.redbus.com` and Firebase references. That is not evidence of a common database. For Thirty8, intentionally use one canonical backend/database so customer and operator actions converge on the same seat and booking truth.

## Evidence labels

Every analysis and implementation artifact must classify statements as:

- **OBSERVED** — directly present in the supplied APK/XAPK or its extracted resources/classes/strings.
- **INFERRED** — strongly suggested by multiple observations but not directly proven.
- **PROPOSED** — a Thirty8 design decision.
- **UNKNOWN** — cannot be established from APK evidence.

## Deliverables expected from the implementation agent

1. Verified reference inventory and hashes
2. Customer UI/screen map
3. Operator UI/screen map
4. End-to-end workflow/state diagrams
5. Thirty8 domain model
6. Database schema + migrations
7. API contract
8. RBAC matrix
9. Seat concurrency design
10. Customer application
11. Operator application
12. Admin web panel
13. Payment/refund adapters
14. QR/ticket/manifest flows
15. Notifications
16. Automated tests
17. Seed/demo data
18. Deployment and rollback documentation
19. Evidence-to-feature traceability matrix
20. Known limitations / unresolved items

## Non-goals

Do not copy redBus logos, trademarks, copyrighted screenshots, proprietary illustrations, proprietary credentials, signing keys, private user data, payment secrets, session tokens, or inaccessible server internals.
