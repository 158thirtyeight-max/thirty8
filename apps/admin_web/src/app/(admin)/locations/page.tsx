import { createClient } from "@/lib/supabase/server";
import { Badge, Button, EmptyState, PageTitle, SectionHeader } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { ColumnToggle, type ToggleColumn } from "./column-toggle";
import { createLocation, renumberOrders, saveRow, setLocationActive } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

type Search = { q?: string; type?: string; status?: string; sort?: string; error?: string; notice?: string };

const inputClass = "w-full rounded-md border border-border bg-background px-2 py-1 text-sm text-text-primary";

const COLUMNS: ToggleColumn[] = [
  { key: "code", label: "Code", defaultVisible: true },
  { key: "lat", label: "Latitude", defaultVisible: true },
  { key: "lng", label: "Longitude", defaultVisible: true },
  { key: "main", label: "Main route", defaultVisible: true },
  { key: "points", label: "Pickup & Drop", defaultVisible: true },
  { key: "status", label: "Status", defaultVisible: true },
  { key: "mainorder", label: "Main route order", defaultVisible: false },
  { key: "pointsorder", label: "Pickup & Drop order", defaultVisible: false },
];

const TYPES: Record<string, (l: any) => boolean> = {
  main: (l) => l.is_main_route_enabled,
  points: (l) => l.is_pickup_enabled || l.is_drop_enabled,
  both: (l) => l.is_main_route_enabled && (l.is_pickup_enabled || l.is_drop_enabled),
  main_only: (l) => l.is_main_route_enabled && !(l.is_pickup_enabled || l.is_drop_enabled),
  points_only: (l) => !l.is_main_route_enabled && (l.is_pickup_enabled || l.is_drop_enabled),
  none: (l) => !l.is_main_route_enabled && !l.is_pickup_enabled && !l.is_drop_enabled,
};

const SORTS: Record<string, string> = { list: "pickup_order", main: "main_route_order", name: "name", code: "location_code" };

/** How many routes use each location, shown in the disable confirmation. */
async function routeUsage(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data } = await supabase.from("route_stops").select("location_id");
  const usage = new Map<string, number>();
  for (const r of data ?? []) usage.set((r as any).location_id, (usage.get((r as any).location_id) ?? 0) + 1);
  return usage;
}

function disableMessage(l: any, used: number) {
  return `Disable ${l.name} (${l.location_code})?\n\nIt will disappear from new routes and customer selection. ${
    used ? `${used} existing route${used === 1 ? "" : "s"} use it and will keep running.` : "No route uses it yet."
  } Nothing is deleted and past bookings are unaffected.`;
}

const th = "px-3 py-2 text-left text-xs font-medium text-text-secondary";
const td = "px-3 py-2 align-middle";

export default async function LocationsPage({ searchParams }: { searchParams: Promise<Search> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const sortKey = sp.sort && SORTS[sp.sort] ? sp.sort : "list";
  const { data: all } = await supabase.from("locations").select("*").order(SORTS[sortKey]).order("name");
  const usage = await routeUsage(supabase);

  const q = (sp.q ?? "").trim().toLowerCase();
  const typeFilter = sp.type ? TYPES[sp.type] : undefined;
  const rows = (all ?? []).filter(
    (l: any) =>
      (!q || l.name.toLowerCase().includes(q) || l.location_code.toLowerCase().includes(q)) &&
      (!typeFilter || typeFilter(l)) &&
      (!sp.status || (sp.status === "active") === l.is_active),
  );

  return (
    <div className="space-y-6">
      <PageTitle
        title="Location Management"
        subtitle="One location list for the whole platform. Tick Main route and/or Pickup & Drop on a location to assign it; every app reads this same list. Only admins can change it."
      />
      {sp.error && <p className="rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{sp.error}</p>}
      {sp.notice && <p className="rounded-md border border-success/40 bg-success/10 px-4 py-3 text-sm text-success">{sp.notice}</p>}

      <form className="grid grid-cols-1 gap-3 md:grid-cols-6" method="get">
        <input name="q" defaultValue={sp.q ?? ""} placeholder="Search by name or code" className={`${inputClass} md:col-span-2`} />
        <select name="type" defaultValue={sp.type ?? ""} className={inputClass} aria-label="Location type">
          <option value="">All location types</option>
          <option value="main">Main route (any)</option>
          <option value="points">Pickup &amp; Drop (any)</option>
          <option value="both">Both</option>
          <option value="main_only">Main route only</option>
          <option value="points_only">Pickup &amp; Drop only</option>
          <option value="none">Not assigned</option>
        </select>
        <select name="status" defaultValue={sp.status ?? ""} className={inputClass} aria-label="Status">
          <option value="">All statuses</option>
          <option value="active">Active</option>
          <option value="inactive">Disabled</option>
        </select>
        <select name="sort" defaultValue={sortKey} className={inputClass} aria-label="Sort by">
          <option value="list">Sort: List order</option>
          <option value="main">Sort: Main route order</option>
          <option value="name">Sort: Name</option>
          <option value="code">Sort: Code</option>
        </select>
        <Button type="submit" variant="outline">
          Filter
        </Button>
      </form>

      <p className="text-xs text-text-tertiary">
        Showing {rows.length} of {all?.length ?? 0} locations.
      </p>

      <form action={renumberOrders} className="flex justify-end">
        <Button type="submit" variant="outline">
          Renumber order
        </Button>
      </form>

      <ColumnToggle columns={COLUMNS}>
        <div className="overflow-x-auto rounded-lg border border-border bg-surface">
          <table className="w-full min-w-max border-collapse text-sm">
            <thead className="border-b border-border">
              <tr>
                <th className={`${th} col-code`}>Code</th>
                <th className={th}>Location name</th>
                <th className={`${th} col-lat`}>Latitude</th>
                <th className={`${th} col-lng`}>Longitude</th>
                <th className={`${th} col-main text-center`}>Main route</th>
                <th className={`${th} col-points text-center`}>Pickup &amp; Drop</th>
                <th className={`${th} col-mainorder`}>Main order</th>
                <th className={`${th} col-pointsorder`}>P&amp;D order</th>
                <th className={`${th} col-status`}>Status</th>
                <th className={th}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((l: any) => {
                const fid = `loc-${l.id}`;
                const points = l.is_pickup_enabled && l.is_drop_enabled;
                return (
                  <tr key={l.id} className={`border-b border-border last:border-0 ${l.is_active ? "" : "opacity-60"}`}>
                    <td className={`${td} col-code`}>
                      <span className="rounded bg-primary/10 px-2 py-0.5 font-mono text-xs font-medium text-primary">{l.location_code}</span>
                    </td>
                    <td className={td}>
                      <input form={fid} name="name" defaultValue={l.name} className={`${inputClass} w-52`} aria-label="Location name" />
                    </td>
                    <td className={`${td} col-lat`}>
                      <input form={fid} name="latitude" defaultValue={l.latitude ?? ""} inputMode="decimal" placeholder="—" className={`${inputClass} w-28`} aria-label="Latitude" />
                    </td>
                    <td className={`${td} col-lng`}>
                      <input form={fid} name="longitude" defaultValue={l.longitude ?? ""} inputMode="decimal" placeholder="—" className={`${inputClass} w-28`} aria-label="Longitude" />
                    </td>
                    <td className={`${td} col-main text-center`}>
                      <input form={fid} type="checkbox" name="is_main_route_enabled" defaultChecked={l.is_main_route_enabled} aria-label="Main route" />
                    </td>
                    <td className={`${td} col-points text-center`}>
                      <input form={fid} type="checkbox" name="is_points_enabled" defaultChecked={points} aria-label="Pickup and drop" />
                    </td>
                    <td className={`${td} col-mainorder`}>
                      <input form={fid} name="main_route_order" type="number" defaultValue={l.main_route_order} className={`${inputClass} w-20`} aria-label="Main route order" />
                    </td>
                    <td className={`${td} col-pointsorder`}>
                      <input form={fid} name="points_order" type="number" defaultValue={l.pickup_order} className={`${inputClass} w-20`} aria-label="Pickup and drop order" />
                    </td>
                    <td className={`${td} col-status`}>
                      <label className="flex items-center gap-2 text-xs">
                        <input form={fid} type="checkbox" name="is_active" defaultChecked={l.is_active} />
                        <Badge status={l.is_active ? "active" : "inactive"} />
                      </label>
                    </td>
                    <td className={td}>
                      <div className="flex items-center gap-2">
                        <Button form={fid} type="submit" variant="outline">
                          Save
                        </Button>
                        {l.is_active ? (
                          <ConfirmButton form={fid} variant="destructive" formAction={setLocationActive.bind(null, l.id, false)} message={disableMessage(l, usage.get(l.id) ?? 0)}>
                            Disable
                          </ConfirmButton>
                        ) : (
                          <Button form={fid} type="submit" variant="secondary" formAction={setLocationActive.bind(null, l.id, true)}>
                            Enable
                          </Button>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {!rows.length && <EmptyState message="No locations match." />}
        </div>
        {rows.map((l: any) => (
          <form key={l.id} id={`loc-${l.id}`} action={saveRow.bind(null, l.id)} />
        ))}
      </ColumnToggle>

      <section>
        <SectionHeader title="Create a new location" />
        <form action={createLocation} className="grid grid-cols-1 gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-12">
          <input name="name" placeholder="Location name" className={`${inputClass} md:col-span-5`} />
          <input name="latitude" placeholder="Latitude (optional)" inputMode="decimal" className={`${inputClass} md:col-span-2`} />
          <input name="longitude" placeholder="Longitude (optional)" inputMode="decimal" className={`${inputClass} md:col-span-2`} />
          <div className="flex flex-wrap items-center gap-4 text-sm md:col-span-3">
            <label className="flex items-center gap-1">
              <input type="checkbox" name="is_main_route_enabled" defaultChecked /> Main route
            </label>
            <label className="flex items-center gap-1">
              <input type="checkbox" name="is_points_enabled" defaultChecked /> Pickup &amp; Drop
            </label>
          </div>
          <Button type="submit" className="md:col-span-12 md:w-48">
            Add location
          </Button>
        </form>
        <p className="mt-2 text-xs text-text-tertiary">The permanent code (T8 + three letters + three digits) is generated automatically. New locations go to the end of each list.</p>
      </section>
    </div>
  );
}
