-- =========================================================================
-- pg_cron jobs: sweep expired seat holds, close stale booking windows,
-- roll trip status forward.
-- =========================================================================

create or replace function private.expire_stale_seat_holds()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.trip_seats ts
  set status = 'available', hold_id = null
  from public.seat_holds sh
  where ts.hold_id = sh.id
    and ts.status = 'held'
    and sh.status = 'active'
    and sh.expires_at < now();

  update public.seat_holds
  set status = 'expired'
  where status = 'active'
    and expires_at < now();

  update public.bus_trips t
  set available_seats = (select count(*) from public.trip_seats where trip_id = t.id and status = 'available')
  where t.id in (
    select distinct trip_id from public.trip_seats
    where updated_at > now() - interval '2 minutes'
  );
end;
$$;

-- Bookings stuck in payment_pending long past a seat hold's TTL are dead —
-- the customer abandoned checkout. Fail them so the order/booking state is
-- consistent (their seats were already freed by expire_stale_seat_holds).
create or replace function private.expire_stale_pending_bookings()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.bookings
  set status = 'expired'
  where status = 'payment_pending'
    and created_at < now() - interval '30 minutes';

  update public.booking_items
  set status = 'expired'
  where booking_id in (
    select id from public.bookings where status = 'expired'
  ) and status = 'payment_pending';

  update public.orders
  set status = 'cancelled'
  where orderable_type = 'booking'
    and status = 'created'
    and orderable_id in (select id from public.bookings where status = 'expired');
end;
$$;

-- Roll a trip from 'scheduled' to 'departed' once its departure time has
-- passed (operators can still transition through 'boarding' manually before
-- that). This is a coarse fallback, not the primary UX for trip status.
create or replace function private.roll_trip_status()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.bus_trips
  set status = 'departed'
  where status in ('scheduled', 'boarding')
    and departure_at < now()
    and departure_at > now() - interval '1 day';

  update public.bus_trips
  set status = 'arrived'
  where status = 'departed'
    and arrival_at is not null
    and arrival_at < now();
end;
$$;

select cron.schedule('expire-stale-seat-holds', '* * * * *', $$select private.expire_stale_seat_holds();$$);
select cron.schedule('expire-stale-pending-bookings', '*/5 * * * *', $$select private.expire_stale_pending_bookings();$$);
select cron.schedule('roll-trip-status', '0 * * * *', $$select private.roll_trip_status();$$);
