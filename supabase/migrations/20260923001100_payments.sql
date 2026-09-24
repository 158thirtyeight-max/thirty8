-- =========================================================================
-- Payments: orders, payments, refunds, webhook idempotency, wallets
-- =========================================================================

create type public.orderable_type as enum ('booking', 'cargo_shipment');
create type public.order_status as enum ('created', 'paid', 'failed', 'cancelled', 'refunded');
create type public.payment_status as enum ('pending', 'captured', 'failed', 'refunded');
create type public.refund_status as enum ('pending', 'processed', 'failed');
create type public.wallet_owner_type as enum ('profile', 'operator');
create type public.wallet_txn_type as enum ('credit', 'debit');

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_reference text not null unique,
  orderable_type public.orderable_type not null,
  orderable_id uuid not null,
  customer_id uuid not null references public.profiles (id),
  amount_cents integer not null check (amount_cents >= 0),
  currency_code text not null default 'INR',
  status public.order_status not null default 'created',
  razorpay_order_id text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger set_updated_at
  before update on public.orders
  for each row execute function private.set_updated_at();

create index orders_customer_id_idx on public.orders (customer_id);
create index orders_orderable_idx on public.orders (orderable_type, orderable_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  razorpay_payment_id text unique,
  method text,
  amount_cents integer not null check (amount_cents >= 0),
  status public.payment_status not null default 'pending',
  captured_at timestamptz,
  raw_response jsonb,
  created_at timestamptz not null default now()
);

create index payments_order_id_idx on public.payments (order_id);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id),
  amount_cents integer not null check (amount_cents >= 0),
  reason text,
  status public.refund_status not null default 'pending',
  razorpay_refund_id text unique,
  processed_at timestamptz,
  created_at timestamptz not null default now()
);

create index refunds_payment_id_idx on public.refunds (payment_id);

-- Webhook idempotency: a Razorpay event is only ever applied once.
create table public.processed_webhook_events (
  id uuid primary key default gen_random_uuid(),
  event_id text not null unique,
  event_type text,
  processed_at timestamptz not null default now()
);

create table public.wallet (
  id uuid primary key default gen_random_uuid(),
  owner_type public.wallet_owner_type not null,
  owner_id uuid not null,
  balance_cents integer not null default 0,
  currency_code text not null default 'INR',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_type, owner_id)
);

create trigger set_updated_at
  before update on public.wallet
  for each row execute function private.set_updated_at();

create table public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null references public.wallet (id) on delete cascade,
  amount_cents integer not null,
  type public.wallet_txn_type not null,
  reference_type text,
  reference_id uuid,
  description text,
  created_at timestamptz not null default now()
);

create index wallet_transactions_wallet_id_idx on public.wallet_transactions (wallet_id, created_at desc);

-- =========================================================================
-- RLS — payments/orders/refunds are owner-read-only; all writes go through
-- SECURITY DEFINER functions and Edge Functions using the service role
-- (which bypasses RLS), never direct client inserts/updates.
-- =========================================================================

alter table public.orders enable row level security;
alter table public.payments enable row level security;
alter table public.refunds enable row level security;
alter table public.processed_webhook_events enable row level security;
alter table public.wallet enable row level security;
alter table public.wallet_transactions enable row level security;

create policy orders_select_own on public.orders
  for select to authenticated
  using (customer_id = (select auth.uid()) or private.is_platform_admin());

create policy orders_admin_all on public.orders
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy payments_select_own on public.payments
  for select to authenticated
  using (
    exists (select 1 from public.orders o where o.id = payments.order_id and o.customer_id = (select auth.uid()))
    or private.is_platform_admin()
  );

create policy payments_admin_all on public.payments
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy refunds_select_own on public.refunds
  for select to authenticated
  using (
    exists (
      select 1 from public.payments p
      join public.orders o on o.id = p.order_id
      where p.id = refunds.payment_id and o.customer_id = (select auth.uid())
    )
    or private.is_platform_admin()
  );

create policy refunds_admin_all on public.refunds
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

-- processed_webhook_events: no client policies at all (service role only).

create policy wallet_select_own on public.wallet
  for select to authenticated
  using (
    (owner_type = 'profile' and owner_id = (select auth.uid()))
    or (owner_type = 'operator' and private.is_operator_admin(owner_id))
    or private.is_platform_admin()
  );

create policy wallet_admin_all on public.wallet
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());

create policy wallet_transactions_select_own on public.wallet_transactions
  for select to authenticated
  using (
    exists (
      select 1 from public.wallet w
      where w.id = wallet_transactions.wallet_id
        and (
          (w.owner_type = 'profile' and w.owner_id = (select auth.uid()))
          or (w.owner_type = 'operator' and private.is_operator_admin(w.owner_id))
        )
    )
    or private.is_platform_admin()
  );

create policy wallet_transactions_admin_all on public.wallet_transactions
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
