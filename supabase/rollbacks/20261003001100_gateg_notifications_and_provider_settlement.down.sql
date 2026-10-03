-- Rollback for 20261003001100_gateg_notifications_and_provider_settlement.sql
-- Existing notification rows are kept; the new templates/triggers/functions and provider_settlements are removed
-- (journals already posted for provider settlements stay on the immutable ledger).
select cron.unschedule('provider-reconciliation');
drop function if exists private.cron_provider_reconciliation();
drop function if exists public.admin_record_provider_settlement(text, bigint, date, text);
drop table if exists public.provider_settlements;
drop trigger if exists payments_failed_notify on public.payments;
drop trigger if exists refunds_notify on public.refunds;
drop trigger if exists earnings_notify on public.operator_earnings;
drop trigger if exists settlements_notify on public.settlements;
drop trigger if exists payment_profiles_notify on public.operator_payment_profiles;
drop function if exists private.notify_payment_failed_trigger();
drop function if exists private.notify_refund_trigger();
drop function if exists private.notify_earning_trigger();
drop function if exists private.notify_settlement_trigger();
drop function if exists private.notify_profile_trigger();
drop function if exists private.notify_operator_admins(uuid, text, jsonb, text);
drop function if exists private.notify(uuid, text, jsonb, text);
delete from public.notification_templates where key in ('operator_payment_profile_verified','operator_payment_profile_failed','operator_earning_eligible',
  'operator_settlement_approved','operator_payout_processing','operator_payout_paid','operator_payout_failed','operator_settlement_on_hold',
  'operator_ticket_cancelled','operator_ticket_recovered','payment_failed','refund_requested','refund_approved','refund_completed','refund_rejected');
drop index if exists public.notifications_event_key_idx;
