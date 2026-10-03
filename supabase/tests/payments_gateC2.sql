-- =========================================================================
-- Checks for Gate C2 (20261003000600_gatec2_refund_policy.sql)
--   * policies: admin-only creation/edit, validation, versions + audit, overlap guard, no seeded rates
--   * operators / customers / support cannot touch policies, percentages, approvals, overrides, recoveries
--   * booking snapshot immune to later policy edits
--   * calculation: floor rounding, windows, categories, no policy => no approval, admin-selected policy,
--     zero-percent refund refused
--   * override: reason, permitted policy only, recorded, audited, kept on approval
--   * allocation + ledger: refund / operator share / cancellation income, before and after settlement
--   * recoveries: partial recovery, write-off, closed
--   * operator + customer read-only RPCs, RLS isolation, dashboard
-- Everything is rolled back.
-- =========================================================================
begin;
-- @include fixtures/trip_fixture.sql

insert into auth.users (id, email) values ('77777777-0000-0000-0000-000000000007', 'support@test.invalid');
insert into public.user_roles (user_id, role) values ('77777777-0000-0000-0000-000000000007', 'platform_support');

create function pg_temp.reset_all() returns void language plpgsql as $f$
begin
  perform pg_temp.as_server();
  set constraints all immediate;
  alter table public.ledger_journals disable trigger ledger_journals_immutable;
  alter table public.ledger_entries disable trigger ledger_entries_immutable;
  delete from public.operator_earnings;
  delete from public.ledger_entries;
  delete from public.ledger_journals;
  alter table public.ledger_journals enable trigger ledger_journals_immutable;
  alter table public.ledger_entries enable trigger ledger_entries_immutable;
  delete from public.reconciliation_exceptions;
  delete from public.refunds;
  delete from public.payments;
  delete from public.orders;
  delete from public.boarding_events;
  delete from public.passenger_boarding;
  delete from public.booking_items;
  delete from public.passenger_identity;
  delete from public.passengers;
  delete from public.booking_status_history;
  delete from public.bookings;
  update public.trip_seats set status = 'available', hold_id = null;
  delete from public.seat_holds;
  set constraints all deferred;
end $f$;

create function pg_temp.bal(p_code text) returns bigint language sql as $f$
  select coalesce(sum(balance_cents), 0)::bigint from public.ledger_account_balances where account_code = p_code
$f$;
create function pg_temp.item_of(p_tag text) returns uuid language sql security definer as $f$
  select bi.id from public.booking_items bi join public.orders o on o.orderable_id = bi.booking_id
   where o.id = (select id from t_ref where tag = p_tag) limit 1
$f$;
create function pg_temp.booking_of(p_tag text) returns uuid language sql security definer as $f$
  select orderable_id from public.orders where id = (select id from t_ref where tag = p_tag)
$f$;
create function pg_temp.refund_of(p_tag text) returns public.refunds language sql security definer as $f$
  select r from public.refunds r join public.payments p on p.id = r.payment_id
   where p.order_id = (select id from t_ref where tag = p_tag) order by r.created_at desc limit 1
$f$;
create function pg_temp.sale(p_tag text, p_seat int, p_pay text) returns void language plpgsql as $f$
declare o public.orders;
begin
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', p_tag, p_seat);
  perform pg_temp.as_server();
  select * into o from public.orders where id = (select id from t_ref where tag = p_tag);
  perform public.confirm_booking_after_payment(o.order_reference, p_pay, o.amount_cents, 'INR');
end $f$;
create function pg_temp.customer_cancels(p_tag text) returns void language plpgsql as $f$
begin
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  perform public.cancel_booking(pg_temp.booking_of(p_tag), 'plans changed');
  perform pg_temp.as_server();
end $f$;
create function pg_temp.as_admin() returns void language sql as $f$ select pg_temp.as_user('ffffffff-0000-0000-0000-00000000000f') $f$;
create function pg_temp.save_policy(p_name text, p_cat text, p_bps int, p_share int, p_min numeric, p_max numeric, p_override boolean, p_status text default 'active', p_id uuid default null)
returns uuid language plpgsql as $f$
declare v uuid;
begin
  perform pg_temp.as_admin();
  v := public.admin_save_refund_policy(p_name, p_cat, p_bps, p_share, p_min, p_max, current_date - 1, null, 'test', p_override, p_status, p_id);
  perform pg_temp.as_server();
  return v;
end $f$;

-- ---- 1. policy administration -------------------------------------------------------------
do $$
declare p1 uuid; p2 uuid; n int;
begin
  if exists (select 1 from public.refund_policies) then raise exception 'FAIL 1a: policies must not be seeded'; end if;

  p1 := pg_temp.save_policy('Early cancellation', 'passenger_cancellation', 8000, 2500, 24, null, true);
  insert into t_ref values ('P1', p1);
  if (select deduction_bps from public.refund_policies where id = p1) <> 2000 then raise exception 'FAIL 1b: deduction not derived'; end if;
  if (select version from public.refund_policies where id = p1) <> 1 or (select count(*) from public.refund_policy_versions where policy_id = p1) <> 1 then raise exception 'FAIL 1c: version 1'; end if;
  if not exists (select 1 from public.audit_logs where action = 'refund_policy.create' and entity_id = p1) then raise exception 'FAIL 1d: create not audited'; end if;

  perform pg_temp.save_policy('Early cancellation', 'passenger_cancellation', 7500, 2500, 24, null, true, 'active', p1);
  if (select version from public.refund_policies where id = p1) <> 2 or (select count(*) from public.refund_policy_versions where policy_id = p1) <> 2 then raise exception 'FAIL 1e: update must create version 2'; end if;
  if (select (snapshot ->> 'refund_bps')::int from public.refund_policy_versions where policy_id = p1 and version = 1) <> 8000 then raise exception 'FAIL 1f: old version changed'; end if;
  if not exists (select 1 from public.audit_logs where action = 'refund_policy.update' and entity_id = p1) then raise exception 'FAIL 1g: update not audited'; end if;
  perform pg_temp.save_policy('Early cancellation', 'passenger_cancellation', 8000, 2500, 24, null, true, 'active', p1);   -- back to 80%

  -- validation
  begin perform pg_temp.save_policy('x', 'passenger_cancellation', 10001, 0, 0, 24, false); raise exception 'FAIL 1h: above 100 percent accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  begin perform pg_temp.save_policy('x', 'passenger_cancellation', 5000, 10001, 0, 24, false); raise exception 'FAIL 1i: share above 100 percent accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  begin perform pg_temp.save_policy('x', 'passenger_cancellation', 5000, 0, 24, 24, false); raise exception 'FAIL 1j: empty window accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  begin perform pg_temp.save_policy('x', 'Bad Category!', 5000, 0, 0, 24, false); raise exception 'FAIL 1k: bad category accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();

  -- overlap with an active policy of the same category is refused
  begin perform pg_temp.save_policy('Overlap', 'passenger_cancellation', 5000, 0, 48, null, false); raise exception 'FAIL 1l: overlapping policy accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'policy_overlap%' then raise exception 'FAIL 1l2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();
  p2 := pg_temp.save_policy('Late cancellation', 'passenger_cancellation', 5000, 0, 0, 24, false);   -- adjacent window: fine
  insert into t_ref values ('P2', p2);

  -- nobody but a full admin
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.admin_save_refund_policy('op', 'default', 10000, 0, null, null, current_date, null, null, false, 'active'); raise exception 'FAIL 1m: operator created a policy';
  exception when insufficient_privilege then null; end;
  begin perform public.admin_set_refund_policy_status(p1, 'inactive'); raise exception 'FAIL 1n: operator changed a policy';
  exception when insufficient_privilege then null; end;
  begin insert into public.refund_policies (name, category, refund_bps, deduction_operator_share_bps) values ('direct', 'default', 10000, 0); raise exception 'FAIL 1o: operator wrote the table';
  exception when insufficient_privilege then null; end;
  if exists (select 1 from public.refund_policies) or exists (select 1 from public.refund_policy_versions) then raise exception 'FAIL 1p: operator can read policies'; end if;
  perform pg_temp.as_user('77777777-0000-0000-0000-000000000007');
  begin perform public.admin_save_refund_policy('s', 'default', 10000, 0, null, null, current_date, null, null, false, 'active'); raise exception 'FAIL 1q: platform_support created a policy';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin perform public.admin_save_refund_policy('c', 'default', 10000, 0, null, null, current_date, null, null, false, 'active'); raise exception 'FAIL 1r: customer created a policy';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  begin update public.refund_policy_versions set changed_by = null; raise exception 'FAIL 1s: policy history edited';
  exception when object_not_in_prerequisite_state then null; end;
end $$;

-- ---- 2. booking snapshot is immune to later policy edits ---------------------------------------
do $$
declare p1 uuid := (select id from t_ref where tag = 'P1'); t jsonb; t2 jsonb;
begin
  perform pg_temp.sale('S2A', 1, 'pay_2a');
  select tiers into t from public.booking_policy_snapshot where booking_id = pg_temp.booking_of('S2A');
  if jsonb_array_length(t) <> 2 then raise exception 'FAIL 2a: snapshot should hold the 2 active tiers, got %', t; end if;

  perform pg_temp.save_policy('Early cancellation', 'passenger_cancellation', 6000, 2500, 24, null, true, 'active', p1);
  select tiers into t2 from public.booking_policy_snapshot where booking_id = pg_temp.booking_of('S2A');
  if t2 <> t then raise exception 'FAIL 2b: a policy edit changed an existing booking snapshot'; end if;

  perform pg_temp.sale('S2B', 2, 'pay_2b');
  if (select (e ->> 'refund_bps')::int from public.booking_policy_snapshot s, jsonb_array_elements(s.tiers) e
       where s.booking_id = pg_temp.booking_of('S2B') and e ->> 'id' = p1::text) <> 6000 then raise exception 'FAIL 2c: new booking did not capture the new rate'; end if;
  if (select (e ->> 'version')::int from public.booking_policy_snapshot s, jsonb_array_elements(s.tiers) e
       where s.booking_id = pg_temp.booking_of('S2A') and e ->> 'id' = p1::text) >= (select version from public.refund_policies where id = p1) then raise exception 'FAIL 2d: version not captured'; end if;
  perform pg_temp.save_policy('Early cancellation', 'passenger_cancellation', 8000, 2500, 24, null, true, 'active', p1);
end $$;

-- ---- 3. calculation, approval, allocation, ledger --------------------------------------------------
select pg_temp.reset_all();
do $$
declare p1 uuid := (select id from t_ref where tag = 'P1'); r public.refunds; c jsonb; v_op uuid := (select id from t_ops where tag = 'A'); v_adj public.operator_adjustments;
begin
  perform pg_temp.sale('S3', 1, 'pay_3');
  perform pg_temp.customer_cancels('S3');
  r := pg_temp.refund_of('S3');
  if r.status <> 'requested' or r.reason_category <> 'passenger_cancellation' or r.requested_cents <> 50000 then raise exception 'FAIL 3a: %', r; end if;

  perform pg_temp.as_user('77777777-0000-0000-0000-000000000007');
  c := public.admin_preview_refund(r.id);                 -- support may review
  perform pg_temp.as_server();
  if (c ->> 'refund_cents')::bigint <> 40000 or (c ->> 'deduction_cents')::bigint <> 10000 or (c ->> 'operator_share_cents')::bigint <> 2500
     or (c ->> 'platform_retained_cents')::bigint <> 7500 or c ->> 'source' <> 'booking_snapshot' or c ->> 'policy_id' <> p1::text then
    raise exception 'FAIL 3b: preview %', c;
  end if;
  if (select amount_cents from public.refunds where id = r.id) <> 50000 or (select status from public.refunds where id = r.id) <> 'requested' then raise exception 'FAIL 3c: preview changed the refund'; end if;

  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_preview_refund(r.id); raise exception 'FAIL 3d: operator previewed a refund';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.admin_approve_refund(r.id); raise exception 'FAIL 3e: customer approved';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('77777777-0000-0000-0000-000000000007'); perform public.admin_approve_refund(r.id); raise exception 'FAIL 3f: support approved';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();

  perform pg_temp.as_admin();
  perform public.admin_approve_refund(r.id);
  perform pg_temp.as_server();
  r := pg_temp.refund_of('S3');
  if r.status <> 'approved' or r.amount_cents <> 40000 or r.policy_id <> p1 or r.policy_refund_bps <> 8000 or r.calc_source <> 'booking_snapshot'
     or r.calc_eligible_cents <> 50000 or r.calc_deduction_cents <> 10000 or r.calc_operator_share_cents <> 2500 or r.calculated_by is null then
    raise exception 'FAIL 3g: stored calculation %', r;
  end if;
  select * into v_adj from public.operator_adjustments where refund_id = r.id;
  if v_adj.amount_cents <> 2500 or v_adj.operator_id <> v_op then raise exception 'FAIL 3h: operator share adjustment %', v_adj; end if;
  if not exists (select 1 from public.audit_logs where action = 'refund.approve' and entity_id = r.id and (after ->> 'policy_id') = p1::text) then raise exception 'FAIL 3i: approval audit lacks the policy'; end if;

  if pg_temp.bal('refund_payable') <> 40000 or pg_temp.bal('operator_payable') <> 2500 or pg_temp.bal('cancellation_income') <> 7500 or pg_temp.bal('booking_liability') <> 0 then
    raise exception 'FAIL 3j: approval journal (% / % / % / %)', pg_temp.bal('refund_payable'), pg_temp.bal('operator_payable'), pg_temp.bal('cancellation_income'), pg_temp.bal('booking_liability');
  end if;

  begin perform pg_temp.as_admin(); perform public.admin_approve_refund(r.id); raise exception 'FAIL 3k: approved twice';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();

  -- execute + provider confirms: the retained deduction stays in clearing
  perform pg_temp.as_admin();
  perform public.admin_begin_refund_execution(r.id);
  perform pg_temp.as_server();
  perform public.record_refund_provider_result(r.id, 'rfnd_3', 'processed');
  if pg_temp.bal('razorpay_clearing') <> 10000 or pg_temp.bal('refund_payable') <> 0 then raise exception 'FAIL 3l: clearing % payable %', pg_temp.bal('razorpay_clearing'), pg_temp.bal('refund_payable'); end if;
  if (select sum(amount_cents) filter (where side = 'debit') from public.ledger_entries) <> (select sum(amount_cents) filter (where side = 'credit') from public.ledger_entries) then
    raise exception 'FAIL 3m: trial balance';
  end if;
end $$;

-- 3b. the late-cancellation tier (0-24h) and floor rounding on an uneven fare
select pg_temp.reset_all();
do $$
declare p2 uuid := (select id from t_ref where tag = 'P2'); r public.refunds; c jsonb; v_dep timestamptz := (select departure_at from public.bus_trips where id = (select id from t_ref where tag = 'TRIP'));
begin
  perform pg_temp.sale('S3B', 1, 'pay_3b');
  update public.bus_trips set departure_at = now() + interval '10 hours' where id = (select id from t_ref where tag = 'TRIP');
  perform pg_temp.customer_cancels('S3B');
  r := pg_temp.refund_of('S3B');
  c := private.compute_refund(r.id);
  if c ->> 'policy_id' <> p2::text or (c ->> 'refund_cents')::bigint <> 25000 or (c ->> 'operator_share_cents')::bigint <> 0 then raise exception 'FAIL 3n: late tier %', c; end if;
  update public.bus_trips set departure_at = v_dep where id = (select id from t_ref where tag = 'TRIP');

  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'S3C', 2);
  perform pg_temp.as_server();
  update public.booking_items set fare_cents = 33333 where booking_id = pg_temp.booking_of('S3C');
  update public.bookings set total_fare_cents = 33333 where id = pg_temp.booking_of('S3C');
  update public.orders set amount_cents = 33333 where id = (select id from t_ref where tag = 'S3C');
  perform public.confirm_booking_after_payment((select order_reference from public.orders where id = (select id from t_ref where tag = 'S3C')), 'pay_3c', 33333, 'INR');
  perform pg_temp.customer_cancels('S3C');
  c := private.compute_refund((pg_temp.refund_of('S3C')).id);
  -- 8000 bps of 33333 = 26666.4 -> 26666 ; deduction 6667 ; operator 25% of 6667 = 1666.75 -> 1666 ; platform 5001
  if (c ->> 'refund_cents')::bigint <> 26666 or (c ->> 'deduction_cents')::bigint <> 6667 or (c ->> 'operator_share_cents')::bigint <> 1666
     or (c ->> 'platform_retained_cents')::bigint <> 5001 then raise exception 'FAIL 3o: rounding %', c; end if;
  if (c ->> 'refund_cents')::bigint + (c ->> 'deduction_cents')::bigint <> 33333 then raise exception 'FAIL 3p: refund + deduction must equal the eligible amount'; end if;
end $$;

-- ---- 4. no applicable policy; admin-selected policy; zero percent ---------------------------------------
select pg_temp.reset_all();
do $$
declare p1 uuid := (select id from t_ref where tag = 'P1'); p2 uuid := (select id from t_ref where tag = 'P2'); p0 uuid; r public.refunds;
begin
  perform pg_temp.as_admin();
  perform public.admin_set_refund_policy_status(p1, 'inactive');
  perform public.admin_set_refund_policy_status(p2, 'inactive');
  perform pg_temp.as_server();
  perform pg_temp.sale('S4', 1, 'pay_4');
  if jsonb_array_length((select tiers from public.booking_policy_snapshot where booking_id = pg_temp.booking_of('S4'))) <> 0 then raise exception 'FAIL 4a: snapshot should be empty'; end if;
  perform pg_temp.customer_cancels('S4');
  r := pg_temp.refund_of('S4');
  if private.compute_refund(r.id) ->> 'error' <> 'no_applicable_policy' then raise exception 'FAIL 4b'; end if;
  begin perform pg_temp.as_admin(); perform public.admin_approve_refund(r.id); raise exception 'FAIL 4c: approved with no policy';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'no_applicable_policy%' then raise exception 'FAIL 4c2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();
  begin perform pg_temp.as_admin(); perform public.admin_approve_refund(r.id, p1); raise exception 'FAIL 4d: approved under an inactive policy';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'policy_not_available%' then raise exception 'FAIL 4d2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();

  p0 := pg_temp.save_policy('Non refundable', 'zero_test', 0, 0, null, null, false);
  begin perform pg_temp.as_admin(); perform public.admin_approve_refund(r.id, p0); raise exception 'FAIL 4e: zero refund approved';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'zero_refund%' then raise exception 'FAIL 4e2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();

  perform pg_temp.as_admin();
  perform public.admin_set_refund_policy_status(p1, 'active');
  perform public.admin_approve_refund(r.id, p1);
  perform pg_temp.as_server();
  r := pg_temp.refund_of('S4');
  if r.status <> 'approved' or r.calc_source <> 'admin_selected' or r.amount_cents <> 40000 then raise exception 'FAIL 4f: %', r; end if;
  perform pg_temp.as_admin();
  perform public.admin_set_refund_policy_status(p2, 'active');
  perform pg_temp.as_server();
end $$;

-- ---- 5. override ---------------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare p1 uuid := (select id from t_ref where tag = 'P1'); p3 uuid; r public.refunds; ov public.refund_overrides; res jsonb;
begin
  perform pg_temp.sale('S5', 1, 'pay_5');
  perform pg_temp.customer_cancels('S5');
  r := pg_temp.refund_of('S5');

  begin perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a'); perform public.admin_override_refund(r.id, 45000, 'x'); raise exception 'FAIL 5a: operator override';
  exception when insufficient_privilege then null; end;
  begin perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d'); perform public.admin_override_refund(r.id, 50000, 'x'); raise exception 'FAIL 5b: customer override';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_admin();
  begin perform public.admin_override_refund(r.id, 45000, '  '); raise exception 'FAIL 5c: override without reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_override_refund(r.id, 60000, 'too much'); raise exception 'FAIL 5d: override above the eligible amount';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();

  p3 := pg_temp.save_policy('Strict', 'nooverride', 5000, 0, null, null, false);
  begin perform pg_temp.as_admin(); perform public.admin_override_refund(r.id, 45000, 'goodwill', p3); raise exception 'FAIL 5e: override under a policy that forbids it';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; if sqlerrm not like 'override_not_permitted%' then raise exception 'FAIL 5e2: %', sqlerrm; end if; end;
  perform pg_temp.as_server();

  perform pg_temp.as_admin();
  res := public.admin_override_refund(r.id, 45000, 'service failure on the trip');
  perform pg_temp.as_server();
  select * into ov from public.refund_overrides where refund_id = r.id;
  if ov.original_calculated_cents <> 40000 or ov.final_cents <> 45000 or ov.difference_cents <> 5000 or ov.admin_id <> 'ffffffff-0000-0000-0000-00000000000f' or ov.reason is null then raise exception 'FAIL 5f: %', ov; end if;
  if not exists (select 1 from public.audit_logs where action = 'refund.override' and entity_id = r.id) then raise exception 'FAIL 5g: override not audited'; end if;
  r := pg_temp.refund_of('S5');
  if r.calc_source <> 'override' or r.amount_cents <> 45000 or r.calc_operator_share_cents <> 1250 or r.status <> 'requested' then raise exception 'FAIL 5h: %', r; end if;

  begin perform pg_temp.as_admin(); perform public.admin_override_refund(r.id, 44000, 'again'); raise exception 'FAIL 5i: second override';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_admin();
  perform public.admin_approve_refund(r.id);          -- keeps the authorized amount, does not recalculate
  perform pg_temp.as_server();
  r := pg_temp.refund_of('S5');
  if r.status <> 'approved' or r.amount_cents <> 45000 then raise exception 'FAIL 5j: approval recalculated an override: %', r; end if;
  if (select amount_cents from public.operator_adjustments where refund_id = r.id) <> 1250 then raise exception 'FAIL 5k: share on the overridden deduction'; end if;
  if pg_temp.bal('refund_payable') <> 45000 or pg_temp.bal('operator_payable') <> 1250 or pg_temp.bal('cancellation_income') <> 3750 then
    raise exception 'FAIL 5l: override journal (% / % / %)', pg_temp.bal('refund_payable'), pg_temp.bal('operator_payable'), pg_temp.bal('cancellation_income');
  end if;
end $$;

-- ---- 6. customer cannot manipulate; read-only customer RPCs -----------------------------------------------------
select pg_temp.reset_all();
do $$
declare r public.refunds; t jsonb; s jsonb;
begin
  perform pg_temp.sale('S6', 1, 'pay_6');
  perform pg_temp.customer_cancels('S6');
  r := pg_temp.refund_of('S6');

  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  update public.refunds set amount_cents = 1 where id = r.id;      -- RLS: no policy lets a customer write, so 0 rows change
  perform pg_temp.as_server();
  if (select amount_cents from public.refunds where id = r.id) <> r.amount_cents then raise exception 'FAIL 6a: customer edited a refund amount'; end if;
  perform pg_temp.as_user('dddddddd-0000-0000-0000-00000000000d');
  begin insert into public.refunds (payment_id, amount_cents, reason) values (r.payment_id, 1, 'x'); raise exception 'FAIL 6b: customer inserted a refund';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_update_recovery(gen_random_uuid(), 'write_off', null, 'x'); raise exception 'FAIL 6c: customer touched recoveries';
  exception when insufficient_privilege then null; end;

  t := public.get_booking_cancellation_policy(pg_temp.booking_of('S6'));
  if jsonb_array_length(t -> 'tiers') <> 4 or (t -> 'tiers' -> 0) ? 'id' or (t -> 'tiers' -> 0) ? 'deduction_operator_share_bps' then raise exception 'FAIL 6d: customer policy view %', t; end if;
  s := public.get_my_refund_status(pg_temp.booking_of('S6'));
  if jsonb_array_length(s) <> 1 or s -> 0 ->> 'status' <> 'requested' then raise exception 'FAIL 6e: %', s; end if;

  perform pg_temp.as_user('eeeeeeee-0000-0000-0000-00000000000e');
  begin perform public.get_booking_cancellation_policy(pg_temp.booking_of('S6')); raise exception 'FAIL 6f: other customer read the policy';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.get_my_refund_status(pg_temp.booking_of('S6')); raise exception 'FAIL 6g: other customer read the refund';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
end $$;

-- ---- 7. refund before settlement: operator view + ledger ---------------------------------------------------------
select pg_temp.reset_all();
select pg_temp.as_admin();
select public.admin_set_commission((select id from t_ops where tag = 'A'), 1000);
select pg_temp.as_server();
do $$
declare r public.refunds; j jsonb; v_a uuid := (select id from t_ops where tag = 'A');
begin
  perform pg_temp.sale('S7', 1, 'pay_7');
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.verify_passenger_boarding(pg_temp.item_of('S7'), true);
  perform public.confirm_boarding(pg_temp.item_of('S7'));
  perform pg_temp.as_server();
  perform pg_temp.customer_cancels('S7');
  r := pg_temp.refund_of('S7');
  perform pg_temp.as_admin();
  perform public.admin_approve_refund(r.id);
  perform pg_temp.as_server();
  if pg_temp.bal('operator_payable') <> 2500 or pg_temp.bal('platform_commission') <> 0 or pg_temp.bal('cancellation_income') <> 7500
     or pg_temp.bal('refund_payable') <> 40000 or pg_temp.bal('booking_liability') <> 0 then
    raise exception 'FAIL 7a: boarded-then-refunded balances (% / % / % / % / %)', pg_temp.bal('operator_payable'), pg_temp.bal('platform_commission'),
      pg_temp.bal('cancellation_income'), pg_temp.bal('refund_payable'), pg_temp.bal('booking_liability');
  end if;

  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  j := public.get_operator_refund_adjustments(v_a);
  if jsonb_array_length(j) <> 1 then raise exception 'FAIL 7b: %', j; end if;
  if (j -> 0 ->> 'original_amount_cents')::bigint <> 50000 or (j -> 0 ->> 'refund_amount_cents')::bigint <> 40000
     or (j -> 0 ->> 'cancellation_deduction_cents')::bigint <> 10000 or (j -> 0 ->> 'commission_adjustment_cents')::bigint <> 5000
     or (j -> 0 ->> 'net_impact_cents')::bigint <> -42500 or j -> 0 ->> 'refund_status' <> 'approved' then
    raise exception 'FAIL 7c: operator refund view %', j;
  end if;
  if (select count(*) from public.operator_adjustments) <> 1 then raise exception 'FAIL 7d: operator A should see its adjustment'; end if;
  begin perform public.admin_approve_refund(r.id); raise exception 'FAIL 7e: operator approved';
  exception when insufficient_privilege then null; end;

  perform pg_temp.as_user('bbbbbbbb-0000-0000-0000-00000000000b');
  begin perform public.get_operator_refund_adjustments(v_a); raise exception 'FAIL 7f: operator B read operator A refunds';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  if exists (select 1 from public.operator_adjustments) then raise exception 'FAIL 7g: operator B sees adjustments'; end if;
  perform pg_temp.as_server();
end $$;

-- ---- 8. refund after settlement: recovery, partial recovery, write-off -------------------------------------------------
select pg_temp.reset_all();
do $$
declare r public.refunds; v_rec uuid; v_a uuid := (select id from t_ops where tag = 'A'); b jsonb;
begin
  perform pg_temp.sale('S8', 1, 'pay_8');
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.verify_passenger_boarding(pg_temp.item_of('S8'), true);
  perform public.confirm_boarding(pg_temp.item_of('S8'));
  perform pg_temp.as_server();
  update public.operator_earnings set status = 'settled' where booking_item_id = pg_temp.item_of('S8');
  perform private.post_journal('test:payout8', 'settlement_paid', jsonb_build_array(
    jsonb_build_object('account', 'operator_payable', 'side', 'debit', 'amount_cents', 45000, 'operator_id', v_a),
    jsonb_build_object('account', 'settlement_bank', 'side', 'credit', 'amount_cents', 45000)));
  perform pg_temp.as_admin();
  perform public.cancel_booking(pg_temp.booking_of('S8'), 'refund after settlement');
  perform pg_temp.as_server();
  r := pg_temp.refund_of('S8');
  perform pg_temp.as_admin();
  perform public.admin_approve_refund(r.id, (select id from t_ref where tag = 'P1'));   -- admin cancellation = admin_discretion: the admin picks the policy
  perform pg_temp.as_server();

  if pg_temp.bal('operator_receivable') <> 45000 or pg_temp.bal('operator_payable') <> 2500 or pg_temp.bal('booking_liability') <> 0
     or pg_temp.bal('cancellation_income') <> 7500 or pg_temp.bal('refund_payable') <> 40000 then
    raise exception 'FAIL 8a: after-settlement balances (% / % / % / % / %)', pg_temp.bal('operator_receivable'), pg_temp.bal('operator_payable'),
      pg_temp.bal('booking_liability'), pg_temp.bal('cancellation_income'), pg_temp.bal('refund_payable');
  end if;
  select id into v_rec from public.operator_recovery;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  b := public.get_operator_earnings_breakdown(v_a);
  if (b ->> 'recovery_open_cents')::bigint <> 45000 then raise exception 'FAIL 8b: operator cannot see the outstanding recovery %', b; end if;
  if jsonb_array_length(public.list_operator_recoveries(v_a)) <> 1 then raise exception 'FAIL 8c'; end if;
  begin perform public.admin_update_recovery(v_rec, 'write_off', null, 'x'); raise exception 'FAIL 8d: operator wrote off its own debt';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_user('77777777-0000-0000-0000-000000000007');
  begin perform public.admin_update_recovery(v_rec, 'write_off', null, 'x'); raise exception 'FAIL 8e: support wrote off a debt';
  exception when insufficient_privilege then null; end;

  perform pg_temp.as_admin();
  begin perform public.admin_update_recovery(v_rec, 'record_recovery', 10000, ''); raise exception 'FAIL 8f: no reason';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin perform public.admin_update_recovery(v_rec, 'record_recovery', 45001, 'too much'); raise exception 'FAIL 8g: over-recovery';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform public.admin_update_recovery(v_rec, 'record_recovery', 10000, 'bank transfer from operator');
  perform pg_temp.as_server();
  if (select status from public.operator_recovery where id = v_rec) <> 'partially_recovered' or pg_temp.bal('operator_receivable') <> 35000 then raise exception 'FAIL 8h: partial recovery'; end if;
  perform pg_temp.as_admin();
  perform public.admin_update_recovery(v_rec, 'write_off', null, 'operator closed down');
  perform pg_temp.as_server();
  if (select status from public.operator_recovery where id = v_rec) <> 'written_off' or pg_temp.bal('operator_receivable') <> 0 or pg_temp.bal('bad_debt') <> 35000 then raise exception 'FAIL 8i: write-off'; end if;
  begin perform pg_temp.as_admin(); perform public.admin_update_recovery(v_rec, 'record_recovery', 1, 'late'); raise exception 'FAIL 8j: closed recovery changed';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  perform pg_temp.as_server();
  if not exists (select 1 from public.audit_logs where action = 'recovery.write_off' and entity_id = v_rec) then raise exception 'FAIL 8k: write-off not audited'; end if;
  if (select sum(amount_cents) filter (where side = 'debit') from public.ledger_entries) <> (select sum(amount_cents) filter (where side = 'credit') from public.ledger_entries) then
    raise exception 'FAIL 8l: trial balance';
  end if;
end $$;

-- ---- 9. reason categories + dashboard -------------------------------------------------------------------------------------
select pg_temp.reset_all();
do $$
declare d jsonb;
begin
  perform pg_temp.sale('S9A', 1, 'pay_9a');                           -- customer cancel
  perform pg_temp.customer_cancels('S9A');
  perform pg_temp.sale('S9B', 2, 'pay_9b');                           -- admin cancel on a normal trip
  perform pg_temp.as_admin();
  perform public.cancel_booking(pg_temp.booking_of('S9B'), 'admin');
  perform pg_temp.as_server();
  perform pg_temp.sale('S9C', 3, 'pay_9c');                           -- admin cancel on a cancelled trip
  update public.bus_trips set status = 'cancelled' where id = (select id from t_ref where tag = 'TRIP');
  perform pg_temp.as_admin();
  perform public.cancel_booking(pg_temp.booking_of('S9C'), 'bus cancelled');
  perform pg_temp.as_server();
  update public.bus_trips set status = 'scheduled' where id = (select id from t_ref where tag = 'TRIP');
  perform pg_temp.book('dddddddd-0000-0000-0000-00000000000d', 'S9D', 4);
  perform pg_temp.as_server();
  perform public.confirm_booking_after_payment((select order_reference from public.orders where id = (select id from t_ref where tag = 'S9D')), 'pay_9d', 123, 'INR');   -- unapplied payment

  if (pg_temp.refund_of('S9A')).reason_category <> 'passenger_cancellation' then raise exception 'FAIL 9a'; end if;
  if (pg_temp.refund_of('S9B')).reason_category <> 'admin_discretion' then raise exception 'FAIL 9b: %', (pg_temp.refund_of('S9B')).reason_category; end if;
  if (pg_temp.refund_of('S9C')).reason_category <> 'operator_cancelled' then raise exception 'FAIL 9c: %', (pg_temp.refund_of('S9C')).reason_category; end if;
  if (pg_temp.refund_of('S9D')).reason_category <> 'system_failure' then raise exception 'FAIL 9d'; end if;

  perform pg_temp.as_admin();
  d := public.admin_refund_dashboard();
  if (d ->> 'total_requests')::int <> 4 or (d ->> 'pending_approval')::int <> 4 or (d ->> 'refunded')::int <> 0 then raise exception 'FAIL 9e: dashboard %', d; end if;
  perform pg_temp.as_user('aaaaaaaa-0000-0000-0000-00000000000a');
  begin perform public.admin_refund_dashboard(); raise exception 'FAIL 9f: operator read the refund dashboard';
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_server();
end $$;

rollback;
