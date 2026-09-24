-- =========================================================================
-- Phase 6 (Notifications): device tokens, message templates, and DB-driven
-- dispatch. Rather than editing every booking/cargo function to also "send
-- a notification", a trigger on booking_status_history / cargo_status_history
-- (which every status change already writes to) fires an async HTTP call
-- via pg_net to the send-notification Edge Function. Business logic stays
-- untouched; notifications are a side effect of the audit trail that
-- already exists.
-- =========================================================================

create extension if not exists pg_net with schema extensions;

insert into private.app_secrets (key, value)
values ('internal_dispatch_secret', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

insert into private.app_secrets (key, value)
values ('functions_base_url', 'https://xdrthrdwdfzhzhqkhnnf.supabase.co/functions/v1')
on conflict (key) do nothing;

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles (id) on delete cascade,
  fcm_token text not null unique,
  platform text not null check (platform in ('ios', 'android', 'web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.device_tokens
  for each row execute function private.set_updated_at();

create index device_tokens_profile_id_idx on public.device_tokens (profile_id);

alter table public.device_tokens enable row level security;

create policy device_tokens_owner_all on public.device_tokens
  for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

-- Registers (or re-associates) a device token to the current user. Upsert on
-- fcm_token, not (profile_id, fcm_token): the same token can only ever
-- belong to one profile at a time (e.g. a shared device switching accounts).
create or replace function public.register_device_token(p_fcm_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Must be authenticated';
  end if;

  insert into public.device_tokens (profile_id, fcm_token, platform)
  values ((select auth.uid()), p_fcm_token, p_platform)
  on conflict (fcm_token) do update
    set profile_id = excluded.profile_id, platform = excluded.platform, updated_at = now();
end;
$$;

revoke execute on function public.register_device_token(text, text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;

-- Reusable message templates. {{placeholders}} are substituted by the
-- send-notification Edge Function from the `data` payload it's given.
create table public.notification_templates (
  key text primary key,
  title_template text not null,
  body_template text not null,
  created_at timestamptz not null default now()
);

alter table public.notification_templates enable row level security;

create policy notification_templates_admin_all on public.notification_templates
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
-- No select policy for anon/authenticated: templates are an internal
-- dispatch detail, read only by the service-role Edge Function.

insert into public.notification_templates (key, title_template, body_template) values
  ('booking_confirmed', 'Booking confirmed', 'Your booking {{booking_reference}} is confirmed. Have a safe trip!'),
  ('booking_cancelled', 'Booking cancelled', 'Your booking {{booking_reference}} has been cancelled.'),
  ('booking_failed', 'Booking payment failed', 'Payment for booking {{booking_reference}} failed. Please try again.'),
  ('booking_expired', 'Booking expired', 'Your booking session expired before payment was completed.'),
  ('shipment_confirmed', 'Shipment confirmed', 'Your shipment {{shipment_reference}} is confirmed and awaiting pickup.'),
  ('shipment_picked_up', 'Shipment picked up', 'Your shipment {{shipment_reference}} has been picked up.'),
  ('shipment_out_for_delivery', 'Out for delivery', 'Your shipment {{shipment_reference}} is out for delivery.'),
  ('shipment_delivered', 'Shipment delivered', 'Your shipment {{shipment_reference}} has been delivered.'),
  ('shipment_cancelled', 'Shipment cancelled', 'Your shipment {{shipment_reference}} has been cancelled.')
on conflict (key) do nothing;

-- =========================================================================
-- Dispatch triggers
-- =========================================================================

create or replace function private.dispatch_booking_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_template_key text;
  v_profile_id uuid;
  v_booking_reference text;
  v_secret text;
  v_base_url text;
begin
  v_template_key := case new.to_status
    when 'confirmed' then 'booking_confirmed'
    when 'cancelled' then 'booking_cancelled'
    when 'failed' then 'booking_failed'
    when 'expired' then 'booking_expired'
    else null
  end;
  if v_template_key is null then
    return new;
  end if;

  select b.customer_id, b.booking_reference into v_profile_id, v_booking_reference
  from public.bookings b where b.id = new.booking_id;

  select value into v_secret from private.app_secrets where key = 'internal_dispatch_secret';
  select value into v_base_url from private.app_secrets where key = 'functions_base_url';
  if v_base_url is null then
    return new; -- functions base URL not configured yet; skip silently
  end if;

  perform net.http_post(
    url := v_base_url || '/send-notification',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
    body := jsonb_build_object(
      'profile_id', v_profile_id,
      'template_key', v_template_key,
      'data', jsonb_build_object('booking_reference', v_booking_reference)
    )
  );

  return new;
end;
$$;

create trigger dispatch_booking_notification
  after insert on public.booking_status_history
  for each row execute function private.dispatch_booking_notification();

create or replace function private.dispatch_cargo_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_template_key text;
  v_profile_id uuid;
  v_shipment_reference text;
  v_secret text;
  v_base_url text;
begin
  v_template_key := case new.to_status
    when 'confirmed' then 'shipment_confirmed'
    when 'picked_up' then 'shipment_picked_up'
    when 'out_for_delivery' then 'shipment_out_for_delivery'
    when 'delivered' then 'shipment_delivered'
    when 'cancelled' then 'shipment_cancelled'
    else null
  end;
  if v_template_key is null then
    return new;
  end if;

  select s.sender_user_id, s.shipment_reference into v_profile_id, v_shipment_reference
  from public.cargo_shipments s where s.id = new.shipment_id;

  select value into v_secret from private.app_secrets where key = 'internal_dispatch_secret';
  select value into v_base_url from private.app_secrets where key = 'functions_base_url';
  if v_base_url is null then
    return new;
  end if;

  perform net.http_post(
    url := v_base_url || '/send-notification',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', v_secret),
    body := jsonb_build_object(
      'profile_id', v_profile_id,
      'template_key', v_template_key,
      'data', jsonb_build_object('shipment_reference', v_shipment_reference)
    )
  );

  return new;
end;
$$;

create trigger dispatch_cargo_notification
  after insert on public.cargo_status_history
  for each row execute function private.dispatch_cargo_notification();
