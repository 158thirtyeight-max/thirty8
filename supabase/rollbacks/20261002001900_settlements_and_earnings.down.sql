-- Rolls back 20261002001900_settlements_and_earnings.sql.
-- WARNING: drops settlements and commission configuration.
drop function if exists public.admin_update_settlement(uuid, text, bigint, text, text, text);
drop function if exists public.admin_create_settlement(uuid, date, date);
drop function if exists public.admin_set_commission(uuid, integer, date);
drop function if exists public.get_operator_home_summary(uuid);
drop function if exists public.get_settlement_detail(uuid);
drop function if exists public.list_operator_settlements(uuid, text, int, int);
drop function if exists public.list_operator_earnings_by_trip(uuid, date, date, int, int);
drop function if exists public.get_operator_revenue_trend(uuid, date, date, text, text);
drop function if exists public.get_operator_earnings_summary(uuid, date, date, text);
drop function if exists public.get_trip_financials(uuid);
drop function if exists private.trip_financials(uuid[]);
drop function if exists private.finance_access(uuid);
drop function if exists private.commission_rate_bps(uuid, date);
drop table if exists public.settlement_items;
drop table if exists public.settlements;
drop table if exists public.operator_commission_config;
-- get_service_disable_impact: re-run the definition from 20261002001500_operator_services.sql to restore the original.
