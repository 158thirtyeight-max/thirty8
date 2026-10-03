-- Rollback for 20261003000600_gatec2_refund_policy.sql
-- Drops the refund policy system and restores the Gate A/B approval + ledger functions.
-- WARNING: policies, snapshots, overrides and operator adjustments are deleted. Journals already posted
-- (including the cancellation_income / bad_debt accounts) stay on the immutable ledger.

drop function if exists public.admin_refund_dashboard();
drop function if exists public.get_my_refund_status(uuid);
drop function if exists public.get_booking_cancellation_policy(uuid);
drop function if exists public.list_operator_recoveries(uuid);
drop function if exists public.get_operator_refund_adjustments(uuid, date, date);
drop function if exists public.admin_update_recovery(uuid, text, bigint, text);
drop function if exists public.admin_override_refund(uuid, integer, text, uuid);
drop function if exists public.admin_approve_refund(uuid, uuid);
drop function if exists public.admin_set_refund_policy_status(uuid, text);
drop function if exists public.admin_save_refund_policy(text, text, integer, integer, numeric, numeric, date, date, text, boolean, text, uuid);
drop function if exists public.admin_preview_refund(uuid, uuid);

-- Gate A approval (no calculation)
create or replace function public.admin_approve_refund(p_refund_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.refunds;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  select * into v from public.refunds where id = p_refund_id for update;
  if v.id is null then raise exception 'Refund not found'; end if;
  if v.status <> 'requested' then raise exception 'refund_not_requested: status is %', v.status; end if;
  update public.refunds set status = 'approved', approved_by = (select auth.uid()), approved_at = now() where id = v.id;
  perform private.write_audit('refund.approve', 'refund', v.id,
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'approved', 'amount_cents', v.amount_cents));
end; $$;
revoke execute on function public.admin_approve_refund(uuid) from public, anon;
grant execute on function public.admin_approve_refund(uuid) to authenticated;

-- Gate B refund-approved journal (no allocation)
create or replace function private.ledger_post_refund_approved(p_refund_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v public.refunds;
begin
  select * into v from public.refunds where id = p_refund_id;
  if v.id is null or v.amount_cents <= 0 then return null; end if;
  return private.post_journal(
    'refund:' || v.id || ':approved', 'refund_approved',
    jsonb_build_array(
      jsonb_build_object('account', 'booking_liability', 'side', 'debit', 'amount_cents', v.amount_cents),
      jsonb_build_object('account', 'refund_payable', 'side', 'credit', 'amount_cents', v.amount_cents)),
    'Refund approved', 'refund', v.id);
end; $$;

drop trigger if exists bookings_policy_snapshot on public.bookings;
drop trigger if exists refunds_fill_defaults on public.refunds;
drop table if exists public.operator_adjustments;
drop table if exists public.refund_overrides;
drop table if exists public.booking_policy_snapshot;
drop table if exists public.refund_policy_versions;
drop table if exists public.refund_policies;
alter table public.refunds
  drop column if exists reason_category, drop column if exists requested_cents, drop column if exists policy_id,
  drop column if exists policy_version, drop column if exists policy_refund_bps, drop column if exists calc_source,
  drop column if exists calc_eligible_cents, drop column if exists calc_deduction_cents,
  drop column if exists calc_operator_share_bps, drop column if exists calc_operator_share_cents,
  drop column if exists hours_before_departure, drop column if exists calculated_at, drop column if exists calculated_by;
drop function if exists private.refund_fill_defaults();
drop function if exists private.snapshot_booking_policy();
drop function if exists private.compute_refund(uuid, uuid);
drop function if exists private.pick_policy(jsonb, text, numeric, date);
drop function if exists private.refund_operator(uuid);
drop function if exists private.assert_no_policy_overlap(public.refund_policies);
drop function if exists private.policy_tier(public.refund_policies);
drop function if exists private.refund_policy_bump();
drop function if exists private.refund_policy_record_version();
drop function if exists private.refund_versions_immutable();
