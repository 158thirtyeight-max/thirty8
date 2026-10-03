-- Rollback for 20261003001000_gatef_operator_settlement_detail.sql
-- Removes the extra keys from get_settlement_detail (the Gate D draft filter stays).
do $patch$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.get_settlement_detail(uuid)'::regprocedure);
  execute replace(v_def,
    E'''adjustment_credits_cents'', s.adjustment_credits_cents, ''recovery_netted_cents'', s.recovery_netted_cents,\n    ''approved_at'', s.approved_at, ''exported_at'', s.exported_at, ''bank_paid_at'', s.bank_paid_at,\n    ''sale_items'', v_sales',
    '''sale_items'', v_sales');
end
$patch$;
