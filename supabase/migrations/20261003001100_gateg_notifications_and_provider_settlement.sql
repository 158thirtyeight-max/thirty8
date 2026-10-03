-- =========================================================================
-- Gate G (part 1): financial notifications + manual recording of Razorpay -> bank settlements
--
--   Notifications reuse the existing notifications table / templates / send-notification push function.
--   The in-app row is written by SQL (authoritative, idempotent per event); push is a best-effort extra.
--   Text NEVER contains amounts or bank details (push text can be seen on a lock screen).
--
--   Operators (operator admins): payout profile verified / needs attention, boarding made earnings eligible,
--     settlement approved / sent to bank / paid / failed / on hold, ticket cancelled or recovered.
--   Customers: payment failed, refund requested / approved / completed / declined
--     (payment success is already covered by booking_confirmed).
--
--   admin_record_provider_settlement: books money Razorpay settled to the bank (Dr settlement_bank / Cr
--     razorpay_clearing) from Razorpay's settlement report, once per Razorpay settlement id.
--
-- Reversible: supabase/rollbacks/20261003001100_gateg_notifications_and_provider_settlement.down.sql
-- =========================================================================

-- one notification per recipient per business event (replays and retries never duplicate)
create unique index notifications_event_key_idx on public.notifications (profile_id, (data ->> 'event_key')) where data ? 'event_key';

insert into public.notification_templates (key, title_template, body_template) values
  ('operator_payment_profile_verified', 'Payout account verified', 'Your bank details are verified. Weekly payouts can now be made to your account.'),
  ('operator_payment_profile_failed', 'Payout account needs attention', 'We could not verify your bank details. Open Earnings > Payouts to see what to fix.'),
  ('operator_earning_eligible', 'Earnings updated', 'Boarding was recorded on your trip, so those earnings are now eligible for the next weekly settlement.'),
  ('operator_settlement_approved', 'Settlement approved', 'Your weekly settlement {{reference}} has been approved for payment.'),
  ('operator_payout_processing', 'Payout in progress', 'Your settlement {{reference}} has been sent to the bank for payment.'),
  ('operator_payout_paid', 'Payout sent', 'Your settlement {{reference}} has been paid. Open Earnings for the details.'),
  ('operator_payout_failed', 'Payout could not be completed', 'Your settlement {{reference}} could not be paid. thirty8 will contact you; open Earnings for details.'),
  ('operator_settlement_on_hold', 'Settlement on hold', 'Your settlement {{reference}} is on hold. Open Earnings for details or contact thirty8.'),
  ('operator_ticket_cancelled', 'A ticket was cancelled', 'Ticket {{ticket_reference}} was cancelled. Open Earnings > Payouts to see the effect on your earnings.'),
  ('operator_ticket_recovered', 'Cancelled ticket already paid out', 'Ticket {{ticket_reference}} was cancelled after it was paid. The amount will be deducted from future payouts; see Earnings > Payouts.'),
  ('payment_failed', 'Payment failed', 'Your payment for booking {{booking_reference}} did not go through. You can try again from My Trips.'),
  ('refund_requested', 'Refund requested', 'We received your refund request for {{reference}}. thirty8 is reviewing it.'),
  ('refund_approved', 'Refund approved', 'Your refund for {{reference}} was approved and will be sent to your original payment method.'),
  ('refund_completed', 'Refund completed', 'Your refund for {{reference}} has been processed. It can take a few days to show in your account.'),
  ('refund_rejected', 'Refund not approved', 'Your refund request for {{reference}} was not approved. Open the booking for details.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- notify(): write the in-app row (once per event_key) and ask the push function to deliver it
-- ---------------------------------------------------------------------
create or replace function private.notify(p_profile_id uuid, p_template_key text, p_data jsonb, p_event_key text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.notification_templates;
  v_title text;
  v_body text;
  k text;
  v_id uuid;
  v_secret text;
  v_base text;
begin
  if p_profile_id is null then return false; end if;
  select * into t from public.notification_templates where key = p_template_key;
  if t.key is null then return false; end if;
  v_title := t.title_template;
  v_body := t.body_template;
  for k in select jsonb_object_keys(coalesce(p_data, '{}'::jsonb)) loop
    v_title := replace(v_title, '{{' || k || '}}', coalesce(p_data ->> k, ''));
    v_body := replace(v_body, '{{' || k || '}}', coalesce(p_data ->> k, ''));
  end loop;

  insert into public.notifications (profile_id, title, body, data, type)
  values (p_profile_id, v_title, v_body, coalesce(p_data, '{}'::jsonb) || jsonb_build_object('event_key', p_event_key), p_template_key)
  on conflict (profile_id, (data ->> 'event_key')) where data ? 'event_key' do nothing
  returning id into v_id;
  if v_id is null then return false; end if;

  -- push is best effort: a failure here must never block a financial transaction
  begin
    select value into v_secret from private.app_secrets where key = 'internal_dispatch_secret';
    select value into v_base from private.app_secrets where key = 'functions_base_url';
    if v_base is not null and v_secret is not null then
      perform net.http_post(
        url := v_base || '/send-notification',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
        body := jsonb_build_object('profile_id', p_profile_id, 'template_key', p_template_key, 'data', p_data, 'push_only', true));
    end if;
  exception when others then null;
  end;
  return true;
end;
$$;
revoke execute on function private.notify(uuid, text, jsonb, text) from public, anon, authenticated;

create or replace function private.notify_operator_admins(p_operator_id uuid, p_template_key text, p_data jsonb, p_event_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare r record;
begin
  for r in select distinct user_id from public.user_roles where role = 'operator_admin' and operator_id = p_operator_id loop
    perform private.notify(r.user_id, p_template_key, p_data, p_event_key);
  end loop;
end;
$$;
revoke execute on function private.notify_operator_admins(uuid, text, jsonb, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- triggers (side effects of records that already exist; no business function is edited)
-- ---------------------------------------------------------------------
create or replace function private.notify_profile_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.verification_status is distinct from old.verification_status then
    if new.verification_status = 'verified' then
      perform private.notify_operator_admins(new.operator_id, 'operator_payment_profile_verified', '{}'::jsonb,
        'profile:' || new.operator_id || ':verified:' || extract(epoch from new.updated_at)::bigint);
    elsif new.verification_status = 'failed' then
      perform private.notify_operator_admins(new.operator_id, 'operator_payment_profile_failed', '{}'::jsonb,
        'profile:' || new.operator_id || ':failed:' || extract(epoch from new.updated_at)::bigint);
    end if;
  end if;
  return null;
end;
$$;
create trigger payment_profiles_notify after update of verification_status on public.operator_payment_profiles
  for each row execute function private.notify_profile_trigger();

create or replace function private.notify_settlement_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_key text;
begin
  if new.status is not distinct from old.status then return null; end if;
  v_key := case new.status
    when 'approved' then 'operator_settlement_approved'
    when 'exported' then 'operator_payout_processing'
    when 'paid' then 'operator_payout_paid'
    when 'failed' then 'operator_payout_failed'
    when 'on_hold' then 'operator_settlement_on_hold'
    else null end;
  if v_key is not null then
    perform private.notify_operator_admins(new.operator_id, v_key, jsonb_build_object('reference', new.reference),
      'settlement:' || new.id || ':' || new.status || ':' || extract(epoch from now())::bigint);
  end if;
  return null;
end;
$$;
create trigger settlements_notify after update of status on public.settlements
  for each row execute function private.notify_settlement_trigger();

create or replace function private.notify_earning_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_ref text;
begin
  -- boarding made earnings eligible: one notice per trip per day, not one per ticket
  if new.eligible_at is not null and old.eligible_at is null then
    perform private.notify_operator_admins(new.operator_id, 'operator_earning_eligible', jsonb_build_object('trip_id', new.trip_id),
      'eligible:' || new.trip_id || ':' || (new.eligible_at at time zone 'Asia/Kolkata')::date);
  end if;
  if new.status is distinct from old.status and new.status in ('void', 'clawed_back') then
    select booking_reference into v_ref from public.bookings where id = new.booking_id;
    if new.status = 'clawed_back' then
      perform private.notify_operator_admins(new.operator_id, 'operator_ticket_recovered', jsonb_build_object('ticket_reference', v_ref),
        'earning:' || new.id || ':clawed_back');
    elsif old.eligible_at is not null or old.status in ('eligible', 'on_hold', 'in_batch') then
      perform private.notify_operator_admins(new.operator_id, 'operator_ticket_cancelled', jsonb_build_object('ticket_reference', v_ref),
        'earning:' || new.id || ':void');
    end if;
  end if;
  return null;
end;
$$;
create trigger earnings_notify after update on public.operator_earnings
  for each row execute function private.notify_earning_trigger();

create or replace function private.notify_refund_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_ref text; v_key text;
begin
  if tg_op = 'UPDATE' then
    if new.status is not distinct from old.status then return null; end if;
  end if;
  v_key := case new.status when 'requested' then 'refund_requested' when 'approved' then 'refund_approved'
              when 'processed' then 'refund_completed' when 'rejected' then 'refund_rejected' else null end;
  if v_key is null then return null; end if;
  select o.customer_id, coalesce(b.booking_reference, o.order_reference) into v_customer, v_ref
    from public.payments p join public.orders o on o.id = p.order_id
    left join public.bookings b on o.orderable_type = 'booking' and b.id = o.orderable_id
   where p.id = new.payment_id;
  perform private.notify(v_customer, v_key, jsonb_build_object('reference', v_ref), 'refund:' || new.id || ':' || new.status);
  return null;
end;
$$;
create trigger refunds_notify after insert or update of status on public.refunds
  for each row execute function private.notify_refund_trigger();

create or replace function private.notify_payment_failed_trigger()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_customer uuid; v_ref text;
begin
  if new.status = 'failed' and (tg_op = 'INSERT' or old.status is distinct from 'failed') then
    select o.customer_id, b.booking_reference into v_customer, v_ref
      from public.orders o join public.bookings b on o.orderable_type = 'booking' and b.id = o.orderable_id
     where o.id = new.order_id;
    if v_ref is not null then
      perform private.notify(v_customer, 'payment_failed', jsonb_build_object('booking_reference', v_ref), 'payment:' || new.id || ':failed');
    end if;
  end if;
  return null;
end;
$$;
create trigger payments_failed_notify after insert or update of status on public.payments
  for each row execute function private.notify_payment_failed_trigger();

-- ---------------------------------------------------------------------
-- money Razorpay settled to the bank (from Razorpay's settlement report), booked once per Razorpay settlement id
-- ---------------------------------------------------------------------
create table public.provider_settlements (
  id uuid primary key default gen_random_uuid(),
  provider_reference text not null unique,
  amount_cents bigint not null check (amount_cents > 0),
  settled_on date not null,
  note text,
  journal_id uuid references public.ledger_journals (id),
  recorded_by uuid references public.profiles (id),
  recorded_at timestamptz not null default now()
);
alter table public.provider_settlements enable row level security;
revoke all on public.provider_settlements from anon, authenticated;
grant select on public.provider_settlements to authenticated;
create policy provider_settlements_admin_select on public.provider_settlements for select to authenticated using (private.is_platform_admin());

create or replace function public.admin_record_provider_settlement(p_provider_reference text, p_amount_cents bigint, p_settled_on date, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid; v_j uuid; v_existing public.provider_settlements;
begin
  if not private.is_full_admin() then raise exception 'not_authorized: full admin required' using errcode = '42501'; end if;
  if nullif(btrim(p_provider_reference), '') is null then raise exception 'The Razorpay settlement id is required'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'The settled amount must be positive'; end if;
  select * into v_existing from public.provider_settlements where provider_reference = btrim(p_provider_reference);
  if v_existing.id is not null then
    if v_existing.amount_cents <> p_amount_cents then
      raise exception 'provider_settlement_conflict: % was already recorded with a different amount', btrim(p_provider_reference);
    end if;
    return v_existing.id;     -- recording the same Razorpay settlement twice is a no-op
  end if;
  v_j := private.post_journal('provider_settlement:' || btrim(p_provider_reference), 'provider_settlement',
    jsonb_build_array(
      jsonb_build_object('account', 'settlement_bank', 'side', 'debit', 'amount_cents', p_amount_cents),
      jsonb_build_object('account', 'razorpay_clearing', 'side', 'credit', 'amount_cents', p_amount_cents)),
    'Razorpay settlement ' || btrim(p_provider_reference), 'provider_settlement', null);
  insert into public.provider_settlements (provider_reference, amount_cents, settled_on, note, journal_id, recorded_by)
  values (btrim(p_provider_reference), p_amount_cents, coalesce(p_settled_on, current_date), nullif(btrim(p_note), ''), v_j, (select auth.uid()))
  returning id into v_id;
  perform private.write_audit('provider_settlement.record', 'provider_settlement', v_id, null,
    jsonb_build_object('reference', btrim(p_provider_reference), 'amount_cents', p_amount_cents, 'settled_on', p_settled_on));
  return v_id;
end;
$$;
revoke execute on function public.admin_record_provider_settlement(text, bigint, date, text) from public, anon;
grant execute on function public.admin_record_provider_settlement(text, bigint, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- daily comparison with Razorpay (the edge function does the fetching; this schedules it)
-- ---------------------------------------------------------------------
create or replace function private.cron_provider_reconciliation()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_secret text; v_base text;
begin
  select value into v_secret from private.app_secrets where key = 'internal_dispatch_secret';
  select value into v_base from private.app_secrets where key = 'functions_base_url';
  if v_base is null or v_secret is null then return; end if;
  perform net.http_post(url := v_base || '/reconcile-payments',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
    body := jsonb_build_object('days', 3));
end;
$$;
revoke execute on function private.cron_provider_reconciliation() from public, anon, authenticated;
select cron.schedule('provider-reconciliation', '45 21 * * *', $$select private.cron_provider_reconciliation();$$);
