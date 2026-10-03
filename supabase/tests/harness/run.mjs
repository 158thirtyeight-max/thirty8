// Local SQL test harness: applies every migration in supabase/migrations to an in-memory
// Postgres (PGlite, real Postgres engine compiled to WASM) and runs supabase/tests/onboarding_*.sql.
//
// Supabase-specific pieces are STUBBED (roles, auth.users/auth.uid(), storage tables, pg_cron/pg_net),
// so this checks SQL syntax, constraints, RLS, triggers and function logic — not Supabase itself.
// Still run the tests against a real branch/local Supabase DB before production.
//
//   cd supabase/tests/harness && npm install && node run.mjs ../..            # everything
//   node run.mjs ../.. onboarding_phase9.sql onboarding_e2e.sql                 # selected files
//   PROBE="select count(*) from buses" node run.mjs ../..                        # ad-hoc query after migrations
import { PGlite } from '@electric-sql/pglite';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];               // C:/GitHub/thirty8/supabase
const only = process.argv.slice(3);         // optional test file names
const db = new PGlite({ extensions: { pg_trgm, pgcrypto } });

const bootstrap = `
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create role supabase_auth_admin nologin; create role authenticator nologin;
create schema extensions; create schema auth; create schema storage; create schema cron;
create extension pg_trgm with schema extensions;
create extension pgcrypto with schema extensions;
create table auth.users (id uuid primary key default gen_random_uuid(), email text unique, phone text unique,
  raw_user_meta_data jsonb not null default '{}', raw_app_meta_data jsonb not null default '{}',
  encrypted_password text, email_confirmed_at timestamptz, created_at timestamptz default now(), updated_at timestamptz default now(),
  aud text default 'authenticated', role text default 'authenticated', instance_id uuid, is_sso_user boolean default false);
create function auth.uid() returns uuid language sql stable as $$ select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid $$;
create function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', 'anon') $$;
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
create table storage.buckets (id text primary key, name text, public boolean default false, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text, owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select (string_to_array(name, '/'))[1:greatest(array_length(string_to_array(name, '/'), 1) - 1, 0)] $$;
create schema net; create function net.http_post(url text, body jsonb default null, params jsonb default null, headers jsonb default null, timeout_milliseconds integer default null) returns bigint language sql as 'select 1::bigint';
create publication supabase_realtime;
create schema realtime;
create table realtime.messages (id bigserial primary key, topic text not null, extension text not null default 'broadcast', event text, payload jsonb, private boolean default false, inserted_at timestamptz default now());
alter table realtime.messages enable row level security;
create table realtime.sent_log (id bigserial primary key, topic text, event text, payload jsonb, private boolean);
create function realtime.topic() returns text language sql stable as $$ select nullif(current_setting('realtime.topic', true), '') $$;
create function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void language sql as $$ insert into realtime.sent_log (topic, event, payload, private) values (topic, event, payload, private) $$;
grant usage on schema realtime to anon, authenticated, service_role;
grant select on realtime.messages to anon, authenticated;
create function cron.schedule(text, text, text) returns bigint language sql as 'select 1::bigint';
create function cron.schedule(text, text) returns bigint language sql as 'select 1::bigint';
create function cron.unschedule(text) returns boolean language sql as 'select true';
grant usage on schema public, extensions, auth, storage to anon, authenticated, service_role;
grant select on auth.users to authenticated;
grant all on storage.objects, storage.buckets to authenticated, anon, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
`;
await db.exec(bootstrap);

const migDir = path.join(root, 'migrations');
const files = fs.readdirSync(migDir).filter(f => f.endsWith('.sql')).sort();
for (const f of files) {
  let sql = fs.readFileSync(path.join(migDir, f), 'utf8');
  sql = sql.replace(/create extension if not exists pg_cron[^;]*;/gi, '').replace(/create extension if not exists pg_net[^;]*;/gi, '');
  sql = sql.replace(/create extension if not exists pg_trgm[^;]*;/gi, '').replace(/create extension if not exists pgcrypto[^;]*;/gi, '');
  try { await db.exec(sql); }
  catch (e) { console.log('MIGRATION FAILED', f, '\n  ', e.message); process.exit(1); }
}
console.log('applied', files.length, 'migrations');

if (process.env.PROBE) { const r = await db.query(process.env.PROBE); console.log(JSON.stringify(r.rows)); }
const testDir = path.join(root, 'tests');
const tests = fs.readdirSync(testDir).filter(f => (f.startsWith('onboarding_') || f.startsWith('operator_') || f.startsWith('payments_')) && f.endsWith('.sql')).sort((a,b)=>a.localeCompare(b, undefined, {numeric:true}))
  .filter(f => only.length === 0 || only.includes(f));
let failed = 0;
for (const t of tests) {
  let sql = fs.readFileSync(path.join(testDir, t), 'utf8');
  // "-- @include fixtures/x.sql" inlines a shared fixture from tests/.
  sql = sql.replace(/^-- @include (\S+)\s*$/gm, (_, f) => fs.readFileSync(path.join(testDir, f), 'utf8'));
  // Legacy onboarding_* tests predate mandatory passenger IDs; operator_* tests run with the real default (ON).
  await db.exec(`update public.platform_settings set value = '${t.startsWith('onboarding_') ? 'false' : 'true'}' where key = 'passenger_id_required'`);
  try {
    await db.exec(sql);
    console.log('PASS', t);
  } catch (e) {
    failed++;
    console.log('FAIL', t, '\n  ', e.message);
    try { await db.exec('rollback'); } catch {}
    try { await db.exec('reset role'); } catch {}
  }
}
console.log(failed ? `${failed} test file(s) failed` : 'all test files passed');
