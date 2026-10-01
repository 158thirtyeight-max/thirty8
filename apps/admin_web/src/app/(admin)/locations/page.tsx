import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, Button, EmptyState, PageTitle, SectionHeader } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { saveLocation, savePoint, setLocationActive, setPointActive } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

type Search = { tab?: string; q?: string; status?: string; loc?: string; error?: string; notice?: string };

const inputClass = "w-full rounded-md border border-border bg-background px-2 py-1 text-sm text-text-primary";

function Tabs({ tab }: { tab: "main" | "points" }) {
  const base = "rounded-t-md border-b-2 px-4 py-2 text-sm font-medium transition";
  const on = "border-primary text-primary";
  const off = "border-transparent text-text-secondary hover:text-primary";
  return (
    <div className="mb-6 flex gap-2 border-b border-border">
      <Link href="/locations?tab=main" className={`${base} ${tab === "main" ? on : off}`}>
        Main Route Locations
      </Link>
      <Link href="/locations?tab=points" className={`${base} ${tab === "points" ? on : off}`}>
        Pickup &amp; Drop Points
      </Link>
    </div>
  );
}

function StatusFilter({ value }: { value?: string }) {
  return (
    <select name="status" defaultValue={value ?? ""} className={inputClass} aria-label="Status">
      <option value="">All statuses</option>
      <option value="active">Active</option>
      <option value="inactive">Disabled</option>
    </select>
  );
}

async function MainTab({ sp }: { sp: Search }) {
  const supabase = await createClient();
  const [{ data: locations }, { data: pointRows }] = await Promise.all([
    supabase.from("main_locations").select("*").order("display_order").order("name"),
    supabase.from("pickup_drop_points").select("main_location_id"),
  ]);
  const counts = new Map<string, number>();
  for (const p of pointRows ?? []) counts.set((p as any).main_location_id, (counts.get((p as any).main_location_id) ?? 0) + 1);

  const q = (sp.q ?? "").trim().toLowerCase();
  const rows = (locations ?? []).filter(
    (l: any) => (!q || l.name.toLowerCase().includes(q)) && (!sp.status || (sp.status === "active") === l.is_active),
  );

  return (
    <div className="space-y-6">
      <form className="grid grid-cols-1 gap-3 md:grid-cols-4" method="get">
        <input type="hidden" name="tab" value="main" />
        <input name="q" defaultValue={sp.q ?? ""} placeholder="Search locations" className={`${inputClass} md:col-span-2`} />
        <StatusFilter value={sp.status} />
        <Button type="submit" variant="outline">
          Filter
        </Button>
      </form>

      <div className="space-y-2">
        <div className="hidden grid-cols-12 gap-3 px-4 text-xs font-medium text-text-secondary md:grid">
          <span className="col-span-4">Location</span>
          <span className="col-span-1">Order</span>
          <span className="col-span-1">Status</span>
          <span className="col-span-2">Created</span>
          <span className="col-span-4">Actions</span>
        </div>
        {rows.map((l: any) => (
          <form key={l.id} action={saveLocation.bind(null, l.id)} className="grid grid-cols-1 items-center gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-12">
            <input name="name" defaultValue={l.name} className={`${inputClass} md:col-span-4`} aria-label="Location name" />
            <input name="display_order" type="number" defaultValue={l.display_order} className={`${inputClass} md:col-span-1`} aria-label="Display order" />
            <div className="md:col-span-1">
              <Badge status={l.is_active ? "active" : "inactive"} />
            </div>
            <span className="text-xs text-text-tertiary md:col-span-2">{new Date(l.created_at).toLocaleDateString()}</span>
            <div className="flex flex-wrap items-center gap-2 md:col-span-4">
              <Button type="submit" variant="outline">
                Save
              </Button>
              {l.is_active ? (
                <ConfirmButton
                  variant="destructive"
                  formAction={setLocationActive.bind(null, l.id, false)}
                  message={`Disable ${l.name}?\n\nIt will no longer appear in new routes or customer search. Existing routes, services and bookings keep working.`}
                >
                  Disable
                </ConfirmButton>
              ) : (
                <Button type="submit" variant="secondary" formAction={setLocationActive.bind(null, l.id, true)}>
                  Enable
                </Button>
              )}
              <Link href={`/locations?tab=points&loc=${l.id}`} className="text-xs text-primary hover:underline">
                {counts.get(l.id) ?? 0} points
              </Link>
            </div>
          </form>
        ))}
        {!rows.length && <EmptyState message="No locations match." />}
      </div>

      <section>
        <SectionHeader title="Add main location" />
        <form action={saveLocation.bind(null, null)} className="grid grid-cols-1 gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-6">
          <input name="name" placeholder="Location name" className={`${inputClass} md:col-span-3`} />
          <input name="display_order" type="number" placeholder="Order (blank = last)" className={`${inputClass} md:col-span-2`} />
          <Button type="submit">Add location</Button>
        </form>
        <p className="mt-2 text-xs text-text-tertiary">
          Main locations are the major places a bus route can start, pass through or end. Add detailed bus stands and landmarks on the Pickup &amp; Drop Points tab.
        </p>
      </section>
    </div>
  );
}

async function PointsTab({ sp }: { sp: Search }) {
  const supabase = await createClient();
  const [{ data: locations }, { data: points }] = await Promise.all([
    supabase.from("main_locations").select("id, name, is_active").order("display_order"),
    supabase.from("pickup_drop_points").select("*").order("display_order").order("name"),
  ]);
  const locName = new Map((locations ?? []).map((l: any) => [l.id, l.name as string]));
  const order = new Map((locations ?? []).map((l: any, i: number) => [l.id, i]));

  const q = (sp.q ?? "").trim().toLowerCase();
  const rows = (points ?? [])
    .filter((p: any) => (!q || p.name.toLowerCase().includes(q)) && (!sp.loc || p.main_location_id === sp.loc) && (!sp.status || (sp.status === "active") === p.is_active))
    .sort((a: any, b: any) => (order.get(a.main_location_id) ?? 99) - (order.get(b.main_location_id) ?? 99) || a.display_order - b.display_order || a.name.localeCompare(b.name));

  const locationSelect = (name: string, value?: string, withAll = false) => (
    <select name={name} defaultValue={value ?? ""} className={inputClass} aria-label="Main location">
      {withAll ? <option value="">All main locations</option> : <option value="">Select main location…</option>}
      {(locations ?? []).map((l: any) => (
        <option key={l.id} value={l.id}>
          {l.name}
          {l.is_active ? "" : " (disabled)"}
        </option>
      ))}
    </select>
  );

  return (
    <div className="space-y-6">
      <form className="grid grid-cols-1 gap-3 md:grid-cols-5" method="get">
        <input type="hidden" name="tab" value="points" />
        <input name="q" defaultValue={sp.q ?? ""} placeholder="Search by point name" className={`${inputClass} md:col-span-2`} />
        {locationSelect("loc", sp.loc, true)}
        <StatusFilter value={sp.status} />
        <Button type="submit" variant="outline">
          Filter
        </Button>
      </form>

      <div className="space-y-2">
        {rows.map((p: any) => (
          <form key={p.id} action={savePoint.bind(null, p.id)} className="grid grid-cols-1 gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-12">
            <label className="text-xs md:col-span-3">
              Point name
              <input name="name" defaultValue={p.name} className={inputClass} />
            </label>
            <label className="text-xs md:col-span-3">
              Parent main location
              {locationSelect("main_location_id", p.main_location_id)}
            </label>
            <label className="text-xs md:col-span-3">
              Landmark
              <input name="landmark" defaultValue={p.landmark ?? ""} className={inputClass} />
            </label>
            <label className="text-xs md:col-span-3">
              Address
              <input name="address" defaultValue={p.address ?? ""} className={inputClass} />
            </label>
            <label className="text-xs md:col-span-2">
              Latitude
              <input name="latitude" defaultValue={p.latitude ?? ""} inputMode="decimal" className={inputClass} />
            </label>
            <label className="text-xs md:col-span-2">
              Longitude
              <input name="longitude" defaultValue={p.longitude ?? ""} inputMode="decimal" className={inputClass} />
            </label>
            <label className="text-xs md:col-span-1">
              Order
              <input name="display_order" type="number" defaultValue={p.display_order} className={inputClass} />
            </label>
            <div className="flex flex-wrap items-end gap-3 text-xs md:col-span-4">
              <label className="flex items-center gap-1">
                <input type="checkbox" name="is_pickup_allowed" defaultChecked={p.is_pickup_allowed} /> Pickup
              </label>
              <label className="flex items-center gap-1">
                <input type="checkbox" name="is_drop_allowed" defaultChecked={p.is_drop_allowed} /> Drop
              </label>
              <label className="flex items-center gap-1">
                <input type="checkbox" name="is_active" defaultChecked={p.is_active} /> Active
              </label>
            </div>
            <div className="flex items-end gap-2 md:col-span-3">
              <Badge status={p.is_active ? "active" : "inactive"} />
              <span className="text-xs text-text-tertiary">{locName.get(p.main_location_id)}</span>
            </div>
            <div className="flex flex-wrap items-end gap-2 md:col-span-12">
              <Button type="submit" variant="outline">
                Save
              </Button>
              {p.is_active ? (
                <ConfirmButton
                  variant="destructive"
                  formAction={setPointActive.bind(null, p.id, false)}
                  message={`Disable ${p.name}?\n\nIt will no longer be offered when operators configure routes or customers pick a stop. Buses already using it keep their stop and past bookings are unaffected.`}
                >
                  Disable point
                </ConfirmButton>
              ) : (
                <Button type="submit" variant="secondary" formAction={setPointActive.bind(null, p.id, true)}>
                  Enable point
                </Button>
              )}
            </div>
          </form>
        ))}
        {!rows.length && <EmptyState message="No points match. Add the first one below." />}
      </div>

      <section>
        <SectionHeader title="Add pickup / drop point" />
        <form action={savePoint.bind(null, null)} className="grid grid-cols-1 gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-12">
          <div className="md:col-span-4">{locationSelect("main_location_id", sp.loc)}</div>
          <input name="name" placeholder="Point name (e.g. Bus Stand)" className={`${inputClass} md:col-span-4`} />
          <input name="landmark" placeholder="Landmark (optional)" className={`${inputClass} md:col-span-4`} />
          <input name="address" placeholder="Address (optional)" className={`${inputClass} md:col-span-4`} />
          <input name="latitude" placeholder="Latitude (optional)" inputMode="decimal" className={`${inputClass} md:col-span-2`} />
          <input name="longitude" placeholder="Longitude (optional)" inputMode="decimal" className={`${inputClass} md:col-span-2`} />
          <input name="display_order" type="number" placeholder="Order" className={`${inputClass} md:col-span-1`} />
          <div className="flex items-center gap-3 text-sm md:col-span-3">
            <label className="flex items-center gap-1">
              <input type="checkbox" name="is_pickup_allowed" defaultChecked /> Pickup
            </label>
            <label className="flex items-center gap-1">
              <input type="checkbox" name="is_drop_allowed" defaultChecked /> Drop
            </label>
          </div>
          <Button type="submit" className="md:col-span-3">
            Add point
          </Button>
        </form>
        <p className="mt-2 text-xs text-text-tertiary">
          Only add verified points. Coordinates are optional and can be filled in later. A point is offered to customers only for buses whose route uses it.
        </p>
      </section>
    </div>
  );
}

export default async function LocationsPage({ searchParams }: { searchParams: Promise<Search> }) {
  const sp = await searchParams;
  const tab = sp.tab === "points" ? "points" : "main";

  return (
    <div>
      <PageTitle title="Location Management" subtitle="The shared location database used by the admin panel, operator app and customer app. Only admins can change it." />
      {sp.error && <p className="mb-4 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{sp.error}</p>}
      {sp.notice && <p className="mb-4 rounded-md border border-success/40 bg-success/10 px-4 py-3 text-sm text-success">{sp.notice}</p>}
      <Tabs tab={tab} />
      {tab === "main" ? <MainTab sp={sp} /> : <PointsTab sp={sp} />}
    </div>
  );
}
