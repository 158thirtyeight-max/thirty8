-- Rollback for 20261003000400_gateb_ledger.sql
-- Drops the ledger and its hooks. WARNING: this destroys the posted journals; take a
-- backup first if any real money has been posted. The journals can be rebuilt from
-- payments/refunds with private.ledger_backfill() after re-applying the migration.
drop trigger if exists payments_ledger on public.payments;
drop trigger if exists refunds_ledger on public.refunds;
drop function if exists private.ledger_payment_trigger();
drop function if exists private.ledger_refund_trigger();
drop function if exists private.ledger_backfill();
drop function if exists public.admin_reverse_journal(uuid, text);
drop view if exists public.ledger_account_balances;

-- immutability triggers would block the drops' cascades of rows, so remove them first
drop trigger if exists ledger_entries_immutable on public.ledger_entries;
drop trigger if exists ledger_journals_immutable on public.ledger_journals;
drop trigger if exists ledger_entries_no_truncate on public.ledger_entries;
drop trigger if exists ledger_journals_no_truncate on public.ledger_journals;
drop trigger if exists ledger_accounts_immutable on public.ledger_accounts;

drop table if exists public.ledger_entries;
drop table if exists public.ledger_journals;
drop table if exists public.ledger_accounts;
drop type if exists public.ledger_account_type;

drop function if exists private.ledger_post_payment_captured(uuid);
drop function if exists private.ledger_post_refund_approved(uuid);
drop function if exists private.ledger_post_refund_processed(uuid);
drop function if exists private.post_journal(text, text, jsonb, text, text, uuid, uuid, jsonb);
drop function if exists private.ledger_check_balance();
drop function if exists private.ledger_require_writer();
drop function if exists private.ledger_block_change();
