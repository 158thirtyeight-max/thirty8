-- =========================================================================
-- Identity: profiles, roles, operators, operator insurance compliance
-- =========================================================================

create type public.app_role as enum (
  'customer',
  'operator_admin',
  'operator_staff',
  'driver',
  'conductor',
  'platform_admin',
  'platform_support'
);

create type public.operator_status as enum ('pending', 'approved', 'rejected', 'suspended');
create type public.operator_business_type as enum ('bus', 'cargo', 'both');

-- One row per Supabase Auth user.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  phone text unique,
  email text unique,
  avatar_url text,
  preferred_language text not null default 'en',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'Extends auth.users with app-facing profile fields. One row per user, created automatically on signup.';

create trigger set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- Auto-create a profile row when a new auth user signs up.
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
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Operators: bus companies and/or cargo transporters onboarded onto the platform.
create table public.operators (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  legal_name text,
  business_type public.operator_business_type not null default 'bus',
  contact_email text,
  contact_phone text,
  status public.operator_status not null default 'pending',
  rating numeric(2, 1),
  settlement_config jsonb not null default '{}'::jsonb,
  approved_by uuid references public.profiles (id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.operators
  for each row execute function private.set_updated_at();

create index operators_status_idx on public.operators (status);

-- A user can hold multiple roles, and operator-scoped roles carry an operator_id.
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.app_role not null,
  operator_id uuid references public.operators (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint user_roles_operator_scope_chk check (
    (role in ('operator_admin', 'operator_staff', 'driver', 'conductor') and operator_id is not null)
    or (role in ('customer', 'platform_admin', 'platform_support') and operator_id is null)
  ),
  unique (user_id, role, operator_id)
);

create index user_roles_user_id_idx on public.user_roles (user_id);
create index user_roles_operator_id_idx on public.user_roles (operator_id) where operator_id is not null;

-- Role-check helpers (now that user_roles exists). Used throughout RLS below
-- and in later migrations. They read public.user_roles directly rather than
-- JWT custom claims, so RLS is correct even before the Phase 2 auth-hook work.
create or replace function private.is_platform_admin()
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid())
      and ur.role in ('platform_admin', 'platform_support')
  );
$$;

create or replace function private.is_operator_staff(p_operator_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid())
      and ur.operator_id = p_operator_id
      and ur.role in ('operator_admin', 'operator_staff', 'driver', 'conductor')
  );
$$;

create or replace function private.is_operator_admin(p_operator_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1 from public.user_roles ur
    where ur.user_id = (select auth.uid())
      and ur.operator_id = p_operator_id
      and ur.role = 'operator_admin'
  );
$$;

revoke execute on function private.is_platform_admin() from public, anon;
revoke execute on function private.is_operator_staff(uuid) from public, anon;
revoke execute on function private.is_operator_admin(uuid) from public, anon;
grant execute on function private.is_platform_admin() to authenticated;
grant execute on function private.is_operator_staff(uuid) to authenticated;
grant execute on function private.is_operator_admin(uuid) to authenticated;

-- Operator vehicle insurance compliance (not customer-facing).
create table public.operator_insurance (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators (id) on delete cascade,
  bus_id uuid,
  cargo_vehicle_id uuid,
  insurance_provider text not null,
  policy_number text not null,
  coverage_type text check (coverage_type in ('comprehensive', 'third_party')),
  valid_from date not null,
  valid_until date not null,
  document_url text,
  status text not null default 'pending' check (status in ('pending', 'verified', 'expired', 'rejected')),
  verified_by uuid references public.profiles (id),
  verified_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operator_insurance_one_vehicle_chk check (
    (bus_id is not null and cargo_vehicle_id is null)
    or (bus_id is null and cargo_vehicle_id is not null)
  )
);

create trigger set_updated_at
  before update on public.operator_insurance
  for each row execute function private.set_updated_at();

create index operator_insurance_operator_id_idx on public.operator_insurance (operator_id);
create index operator_insurance_status_idx on public.operator_insurance (status);

-- =========================================================================
-- RLS
-- =========================================================================

alter table public.profiles enable row level security;
alter table public.operators enable row level security;
alter table public.user_roles enable row level security;
alter table public.operator_insurance enable row level security;

-- profiles
create policy profiles_select_own on public.profiles
  for select to authenticated
  using ((select auth.uid()) = id or private.is_platform_admin());

create policy profiles_update_own on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- operators
create policy operators_select_public on public.operators
  for select to anon, authenticated
  using (status = 'approved' or private.is_operator_staff(id) or private.is_platform_admin());

create policy operators_update_own on public.operators
  for update to authenticated
  using (private.is_operator_admin(id))
  with check (private.is_operator_admin(id));

create policy operators_admin_all on public.operators
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

-- No direct INSERT policy on operators: self-registration goes through
-- public.register_operator() below, which atomically creates the operator
-- row and grants the caller 'operator_admin' for it (there would otherwise
-- be no way to grant that first operator_admin role, since user_roles only
-- allows an existing operator_admin to grant staff/driver/conductor roles).

-- user_roles
create policy user_roles_select_own on public.user_roles
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or private.is_operator_admin(operator_id)
    or private.is_platform_admin()
  );

create policy user_roles_operator_admin_manage on public.user_roles
  for insert to authenticated
  with check (
    private.is_operator_admin(operator_id)
    and role in ('operator_staff', 'driver', 'conductor')
  );

create policy user_roles_operator_admin_delete on public.user_roles
  for delete to authenticated
  using (private.is_operator_admin(operator_id));

create policy user_roles_admin_all on public.user_roles
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

-- Only platform admins may move an insurance record into verified/rejected status;
-- operators can freely edit their own draft/pending records otherwise.
create or replace function private.protect_insurance_verification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then
    if new.status is distinct from old.status
      or new.verified_by is distinct from old.verified_by
      or new.verified_at is distinct from old.verified_at then
      raise exception 'Only platform admins can change insurance verification status';
    end if;
  end if;
  return new;
end;
$$;

create trigger protect_insurance_verification
  before update on public.operator_insurance
  for each row execute function private.protect_insurance_verification();

-- operator_insurance
create policy operator_insurance_operator_manage on public.operator_insurance
  for all to authenticated
  using (private.is_operator_staff(operator_id))
  with check (private.is_operator_staff(operator_id));

create policy operator_insurance_admin_all on public.operator_insurance
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

-- =========================================================================
-- Operator self-registration (public RPC)
-- =========================================================================

create or replace function public.register_operator(
  p_name text,
  p_legal_name text,
  p_business_type public.operator_business_type,
  p_contact_email text,
  p_contact_phone text
)
returns public.operators
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operator public.operators;
begin
  if (select auth.uid()) is null then
    raise exception 'Must be authenticated to register an operator';
  end if;

  insert into public.operators (name, legal_name, business_type, contact_email, contact_phone)
  values (p_name, p_legal_name, p_business_type, p_contact_email, p_contact_phone)
  returning * into v_operator;

  insert into public.user_roles (user_id, role, operator_id)
  values ((select auth.uid()), 'operator_admin', v_operator.id);

  return v_operator;
end;
$$;

revoke execute on function public.register_operator(text, text, public.operator_business_type, text, text) from public, anon;
grant execute on function public.register_operator(text, text, public.operator_business_type, text, text) to authenticated;
