-- =========================================================================
-- Gate F (operator app): the settlement detail the operator sees now also carries what the new engine added:
-- cancellation-share credits, recovery netted, and the approved / exported / bank-paid dates.
-- Read-only; the existing function is patched in place (drafts stay hidden from operators, see Gate D).
-- Reversible: supabase/rollbacks/20261003001000_gatef_operator_settlement_detail.down.sql
-- =========================================================================
do $patch$
declare
  v_def text;
  v_a constant text := $q$'sale_items', v_sales, 'adjustment_items', v_adj, 'trips', v_trips);$q$;
  v_b constant text := $q$'adjustment_credits_cents', s.adjustment_credits_cents, 'recovery_netted_cents', s.recovery_netted_cents,
    'approved_at', s.approved_at, 'exported_at', s.exported_at, 'bank_paid_at', s.bank_paid_at,
    'sale_items', v_sales, 'adjustment_items', v_adj, 'trips', v_trips);$q$;
begin
  v_def := pg_get_functiondef('public.get_settlement_detail(uuid)'::regprocedure);
  if position(v_a in v_def) = 0 then raise exception 'Gate F: get_settlement_detail text drifted'; end if;
  execute replace(v_def, v_a, v_b);
end
$patch$;
