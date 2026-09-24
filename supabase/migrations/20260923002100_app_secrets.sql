-- =========================================================================
-- Private secret storage for server-side-only signing keys (currently just
-- the QR ticket HMAC key). Never exposed via PostgREST — the `private`
-- schema is not in the API's exposed schema list and has no grants to
-- anon/authenticated.
-- =========================================================================

create table private.app_secrets (
  key text primary key,
  value text not null,
  created_at timestamptz not null default now()
);

insert into private.app_secrets (key, value)
values ('qr_hmac_key', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;
