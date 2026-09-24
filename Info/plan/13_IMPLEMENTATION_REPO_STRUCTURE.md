# 13 — Recommended Thirty8 Repository Structure

```text
thirty8/
├── apps/
│   ├── customer_app/              # Flutter customer app
│   ├── operator_app/              # Flutter operator/crew app
│   └── admin_web/                 # Web admin panel
├── backend/
│   ├── api/
│   ├── domain/
│   ├── application/
│   ├── infrastructure/
│   ├── migrations/
│   ├── seeders/
│   └── tests/
├── packages/
│   ├── api_models/
│   ├── auth/
│   ├── booking_domain/
│   ├── seat_domain/
│   ├── ui_kit/
│   └── analytics/
├── infra/
│   ├── docker/
│   ├── nginx/
│   ├── ci/
│   └── terraform/                 # optional
├── docs/
│   ├── reverse_engineering/
│   ├── architecture/
│   ├── api/
│   ├── database/
│   └── qa/
└── README.md
```

## Build order

1. Backend/domain model
2. Database migrations
3. Authentication/RBAC
4. Route/service/trip management
5. Seat inventory + locking
6. Booking/order/payment abstraction
7. Customer search
8. Customer seat/checkout
9. Customer ticket/My Trips
10. Operator inventory/booking
11. Manifest/boarding/QR
12. Admin web
13. Notifications
14. Reporting
15. QA hardening

Do not start by polishing screens while seat inventory and booking transactions are unresolved.
