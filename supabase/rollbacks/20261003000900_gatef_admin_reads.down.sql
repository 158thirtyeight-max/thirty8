-- Rollback for 20261003000900_gatef_admin_reads.sql (read-only functions; no data is touched)
drop function if exists public.admin_list_refunds(text, integer);
drop function if exists public.admin_list_payment_profiles();
drop function if exists public.admin_finance_dashboard();
