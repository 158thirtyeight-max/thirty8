-- =========================================================================
-- Storage buckets and access policies.
--
-- Convention: every object path starts with the id of the entity it belongs
-- to (operator_id, user_id, booking_id, order_id, shipment_id), e.g.
-- 'bus-photos/<operator_id>/<bus_id>/front.jpg'. Policies below parse that
-- first path segment with storage.foldername() to scope access.
-- =========================================================================

insert into storage.buckets (id, name, public)
values
  ('bus-photos', 'bus-photos', true),
  ('operator-logos', 'operator-logos', true),
  ('user-avatars', 'user-avatars', true),
  ('ticket-pdfs', 'ticket-pdfs', false),
  ('receipts', 'receipts', false),
  ('insurance-documents', 'insurance-documents', false),
  ('cargo-proofs', 'cargo-proofs', false)
on conflict (id) do nothing;

-- Public, operator-owned media: anyone can view, only the owning operator's
-- staff (or platform admin) can upload/modify/delete.
create policy "bus-photos read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'bus-photos');

create policy "bus-photos operator write" on storage.objects
  for all to authenticated
  using (bucket_id = 'bus-photos' and private.is_operator_staff(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'bus-photos' and private.is_operator_staff(((storage.foldername(name))[1])::uuid));

create policy "operator-logos read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'operator-logos');

create policy "operator-logos operator write" on storage.objects
  for all to authenticated
  using (bucket_id = 'operator-logos' and private.is_operator_staff(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'operator-logos' and private.is_operator_staff(((storage.foldername(name))[1])::uuid));

-- Public avatars: anyone can view, only the owning user can upload/modify.
create policy "user-avatars read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'user-avatars');

create policy "user-avatars owner write" on storage.objects
  for all to authenticated
  using (bucket_id = 'user-avatars' and ((storage.foldername(name))[1])::uuid = (select auth.uid()))
  with check (bucket_id = 'user-avatars' and ((storage.foldername(name))[1])::uuid = (select auth.uid()));

-- Private: ticket PDFs, scoped by booking_id, readable by the booking's
-- customer or the trip's operator staff. Generated server-side only.
create policy "ticket-pdfs read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'ticket-pdfs'
    and exists (
      select 1 from public.bookings b
      where b.id = ((storage.foldername(name))[1])::uuid
        and (
          b.customer_id = (select auth.uid())
          or exists (
            select 1 from public.booking_items bi
            join public.bus_trips t on t.id = bi.trip_id
            where bi.booking_id = b.id and private.is_operator_staff(t.operator_id)
          )
        )
    )
  );

-- Private: payment receipts, scoped by order_id, readable by the order's customer.
create policy "receipts read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'receipts'
    and exists (
      select 1 from public.orders o
      where o.id = ((storage.foldername(name))[1])::uuid
        and o.customer_id = (select auth.uid())
    )
  );

-- Private: operator insurance documents, scoped by operator_id.
create policy "insurance-documents operator all" on storage.objects
  for all to authenticated
  using (bucket_id = 'insurance-documents' and private.is_operator_staff(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'insurance-documents' and private.is_operator_staff(((storage.foldername(name))[1])::uuid));

-- Private: cargo pickup/delivery proof photos, scoped by shipment_id.
create policy "cargo-proofs read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'cargo-proofs'
    and exists (
      select 1 from public.cargo_shipments s
      where s.id = ((storage.foldername(name))[1])::uuid
        and (
          s.sender_user_id = (select auth.uid())
          or (s.operator_id is not null and private.is_operator_staff(s.operator_id))
        )
    )
  );

create policy "cargo-proofs operator write" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'cargo-proofs'
    and exists (
      select 1 from public.cargo_shipments s
      where s.id = ((storage.foldername(name))[1])::uuid
        and s.operator_id is not null
        and private.is_operator_staff(s.operator_id)
    )
  );

-- Platform admins can manage every bucket, for support/moderation.
create policy "storage admin all" on storage.objects
  for all to authenticated
  using (private.is_platform_admin())
  with check (private.is_platform_admin());
