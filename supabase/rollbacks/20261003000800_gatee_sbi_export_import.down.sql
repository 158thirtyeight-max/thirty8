-- Rollback for 20261003000800_gatee_sbi_export_import.sql
-- WARNING: deletes export snapshots, bank import history and settlement payment records. Batches already
-- marked paid keep their status/ledger journals; take a backup first if real payouts were recorded.
select cron.unschedule('daily-reconciliation');
drop function if exists private.cron_reconciliation();
drop function if exists public.admin_resolve_exception(uuid, text, text);
drop function if exists public.admin_run_reconciliation();
drop function if exists private.run_reconciliation(uuid);
drop function if exists public.admin_settle_zero_batch(uuid, text);
drop function if exists public.admin_confirm_bank_result(uuid);
drop function if exists public.admin_preview_bank_result(text, jsonb, text);
drop function if exists private.settlement_mark_failed(uuid, text, uuid, uuid);
drop function if exists private.settlement_mark_paid(uuid, text, text, date, uuid, uuid);
drop function if exists public.admin_list_settlement_exports();
drop function if exists public.admin_get_settlement_export(uuid);
drop function if exists public.admin_export_settlement_file(uuid[]);
drop function if exists private.cfg_template();
drop table if exists public.reconciliation_runs;
drop table if exists public.bank_result_rows;
drop table if exists public.bank_result_imports;
drop table if exists public.settlement_payments;
drop trigger if exists settlement_export_rows_immutable on public.settlement_export_rows;
drop trigger if exists settlement_exports_immutable on public.settlement_exports;
update public.settlements set export_id = null;
alter table public.settlements drop column if exists export_id;
drop table if exists public.settlement_export_rows;
drop table if exists public.settlement_exports;
drop function if exists private.export_immutable();
drop function if exists private.csv_cell(text);
drop function if exists private.validate_export_template(jsonb);
delete from public.platform_settings where key = 'settlement_export_template';
-- admin_set_platform_setting keeps the (harmless) export-template branch; re-run 20261003000700 to restore it exactly.
