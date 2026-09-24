-- =========================================================================
-- Interim: customer app uses email/password until a phone/SMS OTP provider
-- is configured (Twilio/MSG91/Gupshup) in the Supabase Dashboard. Once that
-- happens, switch the customer app back to phone OTP — the `new.phone is
-- not null` branch below already handles that path, so no further schema
-- change will be needed, just an app-side auth flow swap.
--
-- Since both the customer app and the operator/admin apps now use
-- email/password, we can no longer use "has a phone" vs "has an email" to
-- tell them apart. Instead, the customer app must pass
-- `options: { data: { app: 'customer' } }` when calling
-- `supabase.auth.signUp()`, which lands in `raw_user_meta_data`.
-- =========================================================================

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, phone, email)
  values (new.id, new.phone, new.email)
  on conflict (id) do nothing;

  if new.phone is not null or new.raw_user_meta_data ->> 'app' = 'customer' then
    if not exists (
      select 1 from public.user_roles
      where user_id = new.id and role = 'customer' and operator_id is null
    ) then
      insert into public.user_roles (user_id, role) values (new.id, 'customer');
    end if;
  end if;

  return new;
end;
$$;
