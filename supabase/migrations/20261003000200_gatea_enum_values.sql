-- =========================================================================
-- Gate A (payment integrity) step 1/2: new enum values.
-- ALTER TYPE ... ADD VALUE must commit before the value is used, so this file
-- only adds values; 20261003000300_gatea_payment_integrity.sql uses them.
--
--   refund_status: requested -> approved -> submitted_to_provider -> processed | failed
--                  (+ rejected). The legacy value `pending` is kept so older SQL
--                  that still inserts it keeps working; a trigger maps it to
--                  `requested` and no row may stay `pending`.
--   payment_status: duplicate_captured = a second real capture for an order that
--                  is already paid. It is money received that must be refunded,
--                  and it is excluded from every `status = 'captured'` check.
-- =========================================================================
alter type public.refund_status add value if not exists 'requested';
alter type public.refund_status add value if not exists 'approved';
alter type public.refund_status add value if not exists 'submitted_to_provider';
alter type public.refund_status add value if not exists 'rejected';
alter type public.payment_status add value if not exists 'duplicate_captured';
