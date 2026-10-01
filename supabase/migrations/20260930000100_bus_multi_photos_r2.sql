-- =========================================================================
-- Bus photographs: multiple angles per side, stored in Cloudflare R2.
--
-- Objects live in R2 (uploaded through the r2-presign edge function); the
-- database only stores their object keys. Each side (exterior / interior)
-- needs at least 2 photos and allows at most 4. The old single-photo columns
-- (Supabase Storage paths) are kept for legacy display only.
-- =========================================================================

alter table public.buses
  add column exterior_photo_keys text[] not null default '{}',
  add column interior_photo_keys text[] not null default '{}',
  add constraint buses_exterior_photo_keys_max_chk check (cardinality(exterior_photo_keys) <= 4),
  add constraint buses_interior_photo_keys_max_chk check (cardinality(interior_photo_keys) <= 4);

create or replace function private.bus_checklist(p_bus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bus public.buses;
  v_items jsonb := '[]'::jsonb;
  v_details jsonb := '{}'::jsonb;
  v_doc record;
  v_layout jsonb;
  v_route jsonb;
  v_fare jsonb;
  v_sched jsonb;
begin
  select * into v_bus from public.buses where id = p_bus_id;
  if v_bus.id is null then raise exception 'Bus not found'; end if;

  -- A: basic information and photographs
  v_items := private.completeness_item(v_items, 'name', 'Bus name', 'basic', coalesce(btrim(v_bus.name), '') <> '');
  v_items := private.completeness_item(v_items, 'manufacturer', 'Manufacturer', 'basic', coalesce(btrim(v_bus.manufacturer), '') <> '');
  v_items := private.completeness_item(v_items, 'model', 'Model', 'basic', coalesce(btrim(v_bus.model), '') <> '');
  v_items := private.completeness_item(v_items, 'mfg_year', 'Manufacturing year', 'basic', v_bus.manufacturing_year is not null);
  v_items := private.completeness_item(v_items, 'reg_year', 'Registration year', 'basic', v_bus.registration_year is not null);
  v_items := private.completeness_item(v_items, 'exterior', 'Exterior photographs (at least 2)', 'basic', cardinality(v_bus.exterior_photo_keys) >= 2);
  v_items := private.completeness_item(v_items, 'interior', 'Interior photographs (at least 2)', 'basic', cardinality(v_bus.interior_photo_keys) >= 2);

  -- B: required documents (present, not expired, not rejected)
  for v_doc in select * from private.bus_document_checks(p_bus_id) where required loop
    v_items := private.completeness_item(
      v_items, 'doc:' || v_doc.doc_type, v_doc.label, 'documents',
      v_doc.present and not v_doc.expired and coalesce(v_doc.status, '') <> 'rejected'
    );
  end loop;

  -- C-F: seat layout, route, fares, schedule
  v_layout := public.validate_bus_layout(p_bus_id);
  v_route := public.validate_bus_route(p_bus_id);
  v_fare := public.validate_bus_fares(p_bus_id);
  v_sched := public.validate_bus_schedule(p_bus_id);

  v_items := private.completeness_item(v_items, 'layout', 'Seat layout', 'seats', (v_layout ->> 'valid')::boolean);
  v_items := private.completeness_item(v_items, 'route', 'Route', 'route', (v_route ->> 'valid')::boolean);
  v_items := private.completeness_item(v_items, 'fare', 'Fare', 'fare', (v_fare ->> 'valid')::boolean);
  v_items := private.completeness_item(v_items, 'schedule', 'Schedule', 'schedule', (v_sched ->> 'valid')::boolean);

  v_details := jsonb_build_object(
    'seats', coalesce(v_layout -> 'errors', '[]'::jsonb),
    'route', coalesce(v_route -> 'errors', '[]'::jsonb),
    'fare', coalesce(v_fare -> 'errors', '[]'::jsonb),
    'schedule', coalesce(v_sched -> 'errors', '[]'::jsonb)
  );

  return private.summarize_completeness(v_items) || jsonb_build_object('details', v_details);
end;
$$;

revoke execute on function private.bus_checklist(uuid) from public, anon;
grant execute on function private.bus_checklist(uuid) to authenticated;
