# 12 — Evidence → Thirty8 Traceability Matrix

| Reference evidence | Evidence class | Thirty8 implementation | Test |
|---|---|---|---|
| Customer has OTP screens/reducers/receiver | OBSERVED | OTP auth flow | auth OTP tests |
| Customer has SRP package/activity | OBSERVED | trip search/results | search acceptance tests |
| Customer has seat layout + seat lock package | OBSERVED | seat map + transactional hold | concurrency tests |
| Payment repository exposes order/payment/seat-release concepts | OBSERVED | orders/payments + release-on-failure | payment state tests |
| Customer has TripDatabase/TripDao | OBSERVED | local cached trip DB | persistence tests |
| Customer has BusBuddy/ticket/QR | OBSERVED | ticket + QR post-booking | ticket/QR tests |
| Customer has cancellation/reschedule stores | OBSERVED | cancellation/reschedule APIs | refund/reschedule tests |
| Customer has live tracking stores/services | OBSERVED | optional live trip tracking | tracking tests |
| Operator has reservation/seat/passenger layouts | OBSERVED | operator booking/inventory UI | operator booking tests |
| Operator has manifests/driver manifests/QR | OBSERVED | manifest + boarding | manifest tests |
| Operator has wallet/statement screens | OBSERVED | operator financial reporting | finance tests |
| Customer and operator expose different hosts | OBSERVED | one Thirty8 canonical backend | integration tests verify both clients |
| Both roles need current seat state | INFERRED | one authoritative inventory ledger | race-condition tests |
| Reference product uses exactly the same physical DB for both apps | UNKNOWN | do not assume; Thirty8 intentionally uses one DB | architecture review |
