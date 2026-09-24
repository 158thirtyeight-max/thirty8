# 07 — Thirty8 API Contract

## API design

Use versioned REST APIs:

`/api/v1/...`

Auth: short-lived access token + refresh token or an equivalent secure session design.

Every mutating request must carry a client/request id for idempotency where relevant.

## Authentication

### Customer

- `POST /auth/send-otp`
- `POST /auth/verify-otp`
- `POST /auth/refresh`
- `POST /auth/logout`

### Operator / staff

- `POST /operator/auth/login`
- `POST /operator/auth/refresh`
- `POST /operator/auth/logout`

## Search

- `GET /cities?query=`
- `GET /routes/search?from=&to=&date=`
- `GET /trips/search?from=&to=&date=`
- `GET /trips/{tripId}`
- `GET /trips/{tripId}/seat-map`
- `GET /trips/{tripId}/boarding-points`
- `GET /trips/{tripId}/dropping-points`

## Seat locking

### Create hold
`POST /trips/{tripId}/seat-holds`

Request:

```json
{
  "seatIds": ["uuid1", "uuid2"],
  "ttlSeconds": 300,
  "requestId": "client-generated-id"
}
```

Response must include:

- hold id
- hold token
- expiry timestamp
- selected seats
- current fare snapshot

### Release hold
`DELETE /seat-holds/{holdId}`

### Validate hold
`GET /seat-holds/{holdId}`

## Customer checkout

- `POST /bookings/quote`
- `POST /orders`
- `GET /orders/{orderId}`
- `POST /payments/attempts`
- `GET /payments/{paymentId}`
- `POST /payments/webhook/{provider}`
- `POST /bookings/{bookingId}/confirm`
- `GET /bookings/{bookingId}`
- `GET /bookings`

## Cancellation / refund

- `GET /bookings/{bookingId}/cancellation-preview`
- `POST /bookings/{bookingId}/cancel`
- `GET /refunds/{refundId}`

## Reschedule

- `GET /bookings/{bookingId}/reschedule-options`
- `POST /bookings/{bookingId}/reschedule`

## Operator

### Fleet

- `GET /operator/buses`
- `POST /operator/buses`
- `PATCH /operator/buses/{id}`
- `GET /operator/buses/{id}/layout`
- `PUT /operator/buses/{id}/layout`

### Services/routes

- `GET /operator/routes`
- `POST /operator/routes`
- `GET /operator/services`
- `POST /operator/services`
- `PATCH /operator/services/{id}`

### Trips

- `GET /operator/trips`
- `GET /operator/trips/{tripId}`
- `GET /operator/trips/{tripId}/inventory`
- `PATCH /operator/trips/{tripId}/inventory`

### Bookings

- `GET /operator/bookings?tripId=`
- `POST /operator/bookings`
- `GET /operator/bookings/{bookingId}`
- `POST /operator/bookings/{bookingId}/cancel`

### Manifest/boarding

- `POST /operator/trips/{tripId}/manifest`
- `GET /operator/trips/{tripId}/manifest`
- `POST /operator/trips/{tripId}/boarding/{bookingItemId}`
- `POST /operator/trips/{tripId}/qr/verify`

## Admin

- operator approval
- user/operator management
- route/service auditing
- bookings oversight
- refund oversight
- configuration
- audit logs

Do not allow the admin web app to bypass domain services. All mutations must use the same backend command paths so rules remain consistent.
