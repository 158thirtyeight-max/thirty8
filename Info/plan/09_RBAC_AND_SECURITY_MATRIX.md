# 09 — RBAC & Security Matrix

| Capability | Customer | Operator Admin | Operator Staff | Driver/Conductor | Platform Admin |
|---|---:|---:|---:|---:|---:|
| Search public trips | ✓ | ✓ | ✓ | ✓ | ✓ |
| Create customer booking | ✓ | ✓ | ✓ | optional | ✓ |
| View own bookings | ✓ | no | no | no | support-only |
| View operator bookings | no | ✓ | ✓ limited | assigned trips | ✓ |
| Manage fleet | no | ✓ | limited | no | ✓ |
| Manage service schedule | no | ✓ | limited | no | ✓ |
| Modify seat inventory | no | ✓ | ✓ | assigned trip only | ✓ |
| Generate manifest | no | ✓ | ✓ | assigned trip | ✓ |
| Verify QR | no | ✓ | ✓ | assigned trip | ✓ |
| Mark passenger boarded | no | ✓ | ✓ | assigned trip | ✓ |
| Cancel booking | own policy | operator policy | policy-limited | no | ✓ |
| Refund | no direct | policy-limited | no | no | ✓ / finance role |
| View operator statements | no | ✓ | limited | no | ✓ |
| Manage operators | no | no | no | no | ✓ |
| View audit logs | own | operator scope | limited | own actions | ✓ |

## Security requirements

- JWT/session authorization enforced on backend.
- Every operator query must be scoped by `operator_id` derived from authenticated context, never a freely trusted client parameter.
- Sensitive fields are masked in logs.
- Payment secrets stay server-side.
- Webhooks validate provider signatures.
- Rate-limit OTP and login endpoints.
- QR verification must be replay-aware.
- Admin actions require stronger authentication where practical.
- Audit every inventory, fare, booking-status, refund and role change.
