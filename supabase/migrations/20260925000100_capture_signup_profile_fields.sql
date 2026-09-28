-- =========================================================================
-- handle_new_user() only ever wrote id/phone(column)/email to profiles,
-- ignoring full_name and the metadata-carried phone number collected by the
-- signup form (auth.users.phone is a distinct column used only for
-- phone/OTP-based auth, which this app doesn't use for customer signup).
-- This also backfills full_name/photo_url from Google OAuth metadata
-- (full_name/name, avatar_url/picture) so a Google sign-in produces a
-- complete profile without a separate write from the client.
-- =========================================================================

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_full_name text;
  v_phone text;
  v_avatar_url text;
begin
  v_full_name := coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name');
  v_phone := coalesce(new.raw_user_meta_data ->> 'phone', new.phone);
  v_avatar_url := coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture');

  insert into public.profiles (id, phone, email, full_name, avatar_url)
  values (new.id, v_phone, new.email, v_full_name, v_avatar_url)
  on conflict (id) do update set
    full_name = coalesce(public.profiles.full_name, excluded.full_name),
    phone = coalesce(public.profiles.phone, excluded.phone),
    avatar_url = coalesce(public.profiles.avatar_url, excluded.avatar_url);

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
