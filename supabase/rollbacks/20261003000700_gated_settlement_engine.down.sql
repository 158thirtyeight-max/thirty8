-- Rollback for 20261003000700_gated_settlement_engine.sql
-- WARNING: deletes settlement batches' new structure (beneficiaries, runs, payout profiles) and any batch
-- items of the new kinds. Cancel or finish open batches first. The patched list/detail functions keep the
-- draft filter after a rollback (harmless); re-run 20261002001900 to restore them exactly.

select cron.unschedule('build-weekly-settlements');
drop function if exists private.cron_build_weekly_settlement();
drop function if exists public.admin_get_settlement_beneficiary(uuid);
drop function if exists public.admin_hold_earning(uuid, boolean, text);
drop function if exists public.admin_cancel_settlement(uuid, text);
drop function if exists public.admin_release_settlement_hold(uuid);
drop function if exists public.admin_hold_settlement(uuid, text);
drop function if exists public.admin_approve_settlement(uuid);
drop function if exists public.admin_build_weekly_settlement(date, uuid);
drop function if exists private.build_settlements(date, date, uuid, uuid);
drop function if exists private.build_operator_settlement(uuid, date, date, uuid);
drop function if exists private.settlement_period(timestamptz);
drop function if exists private.recovery_reserved(uuid);

-- return earnings/adjustments to the pool before dropping batch references
update public.operator_earnings set status = 'eligible', settlement_id = null where status = 'in_batch';
update public.operator_adjustments set status = 'open', settlement_id = null where status = 'in_batch';
delete from public.settlement_items where kind in ('operator_adjustment', 'recovery_netting');
delete from public.settlements where status in ('draft', 'approved', 'on_hold', 'cancelled', 'exported', 'partially_paid');

drop table if exists public.settlement_runs;
drop table if exists public.settlement_beneficiaries;
drop index if exists public.settlement_items_earning_idx;
drop index if exists public.settlement_items_recovery_per_batch_idx;
drop index if exists public.settlement_items_one_adjustment_credit_idx;
alter table public.settlement_items drop constraint if exists settlement_items_ref_chk;
alter table public.settlement_items drop constraint if exists settlement_items_kind_check;
alter table public.settlement_items add constraint settlement_items_kind_check check (kind in ('sale', 'refund_adjustment'));
alter table public.settlement_items drop column if exists earning_id, drop column if exists adjustment_id,
  drop column if exists recovery_id, drop column if exists net_cents;
alter table public.settlement_items alter column booking_item_id set not null;

drop policy if exists settlements_select on public.settlements;
create policy settlements_select on public.settlements
  for select to authenticated using (private.is_platform_admin() or private.is_operator_admin(operator_id));
drop index if exists public.settlements_operator_period_idx;
alter table public.settlements drop constraint if exists settlements_status_check;
alter table public.settlements add constraint settlements_status_check check (status in ('pending', 'processing', 'paid', 'failed', 'reversed'));
alter table public.settlements alter column status set default 'pending';
alter table public.settlements
  drop column if exists generated_at, drop column if exists approved_by, drop column if exists approved_at,
  drop column if exists exported_at, drop column if exists bank_paid_at, drop column if exists status_before_hold,
  drop column if exists hold_reason, drop column if exists held_by, drop column if exists held_at,
  drop column if exists adjustment_credits_cents, drop column if exists recovery_netted_cents,
  drop column if exists cancelled_by, drop column if exists cancelled_at, drop column if exists cancel_reason;

drop function if exists public.get_my_payment_profile(uuid);
drop function if exists public.admin_set_payout_hold(uuid, boolean, text);
drop function if exists public.admin_set_payment_profile_status(uuid, text, text);
drop function if exists private.payout_block_reason(uuid);
drop function if exists private.bank_details_hash(uuid);
drop table if exists public.operator_payment_profiles;
drop function if exists private.cfg_text(text, text);
drop function if exists private.cfg_int(text, integer);
delete from public.platform_settings where key in ('settlement_timezone', 'settlement_week_start_dow', 'settlement_run_dow',
  'settlement_run_hour', 'settlement_recovery_cap_bps', 'settlement_provider', 'settlement_maker_checker', 'razorpay_route_enabled');

-- previous admin_set_platform_setting (no settlement validation)
create or replace function public.admin_set_platform_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_platform_admin() then raise exception 'Only platform admins can do this'; end if;
  if p_key not in (select key from public.platform_settings) then raise exception 'Unknown setting %', p_key; end if;
  update public.platform_settings set value = p_value, updated_by = (select auth.uid()), updated_at = now() where key = p_key;
  perform private.write_audit('platform_setting.set', 'platform_setting', null, null, jsonb_build_object('key', p_key, 'value', p_value));
end; $$;
-- admin_create_settlement / admin_update_settlement: re-run their definitions from 20261002001900 to restore the manual flow.
