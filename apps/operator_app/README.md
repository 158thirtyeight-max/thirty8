# Thirty8 Plus (operator app)

Flutter app for bus operators and cargo transporters.

Built so far (Phases 10–11):
- Auth (email/password) + self-service operator registration (`register_operator` RPC), gated on platform-admin approval (`operators.status`)
- Bus ops: fleet (buses + auto-generated 2+2 seat layout), routes + boarding/dropping points, services/trips scheduling, manifest view, trip status control, QR boarding scanner (`verify_ticket_qr`)
- Cargo ops: shipment queue (accept/reject/assign vehicle), pickup/delivery confirmation with photo proof, vehicle fleet management
- Shared: dashboard stats, insurance policy upload, sign out

Not yet built: wallet (bus), earnings dashboard (cargo), driver/conductor role scoping (only operator_admin flow tested), staff invites.

Depends on: `supabase/migrations` (schema), `supabase/functions` (Phases 3–6).
