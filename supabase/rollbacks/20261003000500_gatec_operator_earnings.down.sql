-- Rollback for 20261003000500_gatec_operator_earnings.sql
-- Drops earnings, recoveries and their triggers; restores the previous commission lookup/admin function.
-- WARNING: earnings and recoveries are deleted (journals already posted for them stay on the
-- ledger and must be reversed by an admin first if any real money was involved).
-- private.trip_financials keeps the floor + snapshot logic after a rollback: re-run the
-- original definition from 20261002001900_settlements_and_earnings.sql to restore it exactly.

drop trigger if exists booking_items_earning on public.booking_items;
drop trigger if exists passenger_boarding_earning on public.passenger_boarding;
drop trigger if exists refunds_earning on public.refunds;
drop function if exists private.earning_item_trigger();
drop function if exists private.earning_boarding_trigger();
drop function if exists private.earning_refund_trigger();

drop function if exists public.get_operator_earnings_breakdown(uuid, date, date);
drop function if exists public.admin_deactivate_commission(uuid);
drop function if exists private.earnings_backfill();
drop function if exists private.earnings_resolve_unresolved(uuid);
drop function if exists private.earning_on_cancelled(uuid);
drop function if exists private.earning_reevaluate(uuid);
drop function if exists private.earning_ensure(uuid);
drop function if exists private.earning_post_eligible(public.operator_earnings, integer);
drop function if exists private.reverse_journal_system(uuid, text);

drop table if exists public.operator_recovery;
drop table if exists public.operator_earnings;
drop function if exists private.earning_guard_snapshot();

-- previous admin_set_commission (platform admin, no windows)
create or replace function public.admin_set_commission(p_operator_id uuid, p_rate_bps integer, p_effective_from date default current_date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  insert into public.operator_commission_config (operator_id, rate_bps, effective_from, created_by)
  values (p_operator_id, p_rate_bps, coalesce(p_effective_from, current_date), (select auth.uid())) returning id into v_id;
  perform private.write_audit('commission.set', 'operator', p_operator_id, null,
    jsonb_build_object('rate_bps', p_rate_bps, 'effective_from', p_effective_from));
  return v_id;
end; $$;

create or replace function private.commission_rate_bps(p_operator_id uuid, p_on date)
returns integer language sql stable security definer set search_path = '' as $$
  select c.rate_bps from public.operator_commission_config c
  where (c.operator_id = p_operator_id or c.operator_id is null) and c.effective_from <= p_on
  order by (c.operator_id is not null) desc, c.effective_from desc, c.created_at desc limit 1;
$$;
revoke execute on function private.commission_rate_bps(uuid, date) from public, anon, authenticated;

alter table public.operator_commission_config drop constraint if exists operator_commission_window_chk;
alter table public.operator_commission_config
  drop column if exists effective_to, drop column if exists is_active,
  drop column if exists deactivated_by, drop column if exists deactivated_at;
