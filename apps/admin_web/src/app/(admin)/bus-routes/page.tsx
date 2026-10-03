import { fmtDate } from "@/lib/format-date";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

/* eslint-disable @typescript-eslint/no-explicit-any */

const STATUS_FILTERS = [
  { key: "all", label: "All" },
  { key: "active", label: "Active" },
  { key: "draft", label: "Draft" },
  { key: "pending", label: "Pending approval" },
  { key: "rejected", label: "Rejected" },
];

type Row = {
  bus: any;
  active: any;
  open: any;
  rejected: any;
  routeStatus: string;
  approval: string;
  outbound: any;
  hasReturn: boolean;
  stops: number | null;
  updated: string | null;
};

export default async function BusRoutesPage({ searchParams }: { searchParams: Promise<{ operator?: string; type?: string; status?: string; q?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const [{ data: buses }, { data: revisions }, { data: routes }, { data: operators }] = await Promise.all([
    supabase.from("buses").select("id, name, registration_number, lifecycle_status, operator_id, active_route_revision_id, operators(id, name)").order("registration_number"),
    supabase
      .from("route_revisions")
      .select("id, bus_id, revision_no, status, trip_type, name, origin, rejection_reason, reviewed_at, submitted_at, updated_at, route_revision_journeys(direction, source:locations!route_revision_journeys_source_city_id_fkey(name), destination:locations!route_revision_journeys_destination_city_id_fkey(name), route_revision_stops(count))"),
    supabase.from("bus_routes").select("id, bus_id, direction, active, created_at, source:locations!bus_routes_source_city_id_fkey(name), destination:locations!bus_routes_destination_city_id_fkey(name)").not("bus_id", "is", null),
    supabase.from("operators").select("id, name").order("name"),
  ]);

  const rows: Row[] = [];
  for (const bus of (buses as any[]) ?? []) {
    const revs = ((revisions as any[]) ?? []).filter((r) => r.bus_id === bus.id).sort((a, b) => b.revision_no - a.revision_no);
    const live = ((routes as any[]) ?? []).filter((r) => r.bus_id === bus.id && r.active);
    const outbound = live.find((r) => r.direction !== "return");
    const open = revs.find((r) => r.status === "draft" || r.status === "pending_approval") ?? null;
    const active = revs.find((r) => r.id === bus.active_route_revision_id) ?? null;
    const decided = revs.find((r) => !["draft", "pending_approval", "withdrawn"].includes(r.status));
    const rejected = !open && decided?.status === "rejected" ? decided : null;
    const j = active?.route_revision_journeys?.find((x: any) => x.direction === "outbound");
    const count = j?.route_revision_stops?.[0]?.count as number | undefined;
    rows.push({
      bus,
      active,
      open,
      rejected,
      outbound,
      hasReturn: live.some((r) => r.direction === "return"),
      stops: count == null ? null : Math.max(count - 2, 0),
      routeStatus: !outbound ? "no route" : bus.lifecycle_status === "active" ? "active" : "set up",
      approval: open ? (open.status === "pending_approval" ? "pending" : "draft") : rejected ? "rejected" : outbound ? "approved" : "none",
      updated: (active?.reviewed_at ?? active?.submitted_at ?? active?.updated_at ?? outbound?.created_at) ?? null,
    });
  }

  const q = (sp.q ?? "").trim().toLowerCase();
  const filtered = rows.filter((r) => {
    if (sp.operator && r.bus.operator_id !== sp.operator) return false;
    if (sp.type === "round_trip" && !r.hasReturn) return false;
    if (sp.type === "one_way" && r.hasReturn) return false;
    if (sp.status === "active" && r.routeStatus !== "active") return false;
    if (sp.status && ["draft", "pending", "rejected"].includes(sp.status) && r.approval !== sp.status) return false;
    if (q && !`${r.bus.registration_number} ${r.bus.name ?? ""}`.toLowerCase().includes(q)) return false;
    return true;
  });

  const link = (over: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries({ ...sp, ...over })) if (v) p.set(k, v);
    return `/bus-routes?${p.toString()}`;
  };

  return (
    <div>
      <PageTitle title="Routes" subtitle="Every vehicle's route across all operators. Open a route to edit it, copy it to another bus, review its history or publish changes." />

      <form className="mb-4 flex flex-wrap items-end gap-3 text-sm">
        <label className="text-text-secondary">
          Operator
          <select name="operator" defaultValue={sp.operator ?? ""} className="mt-1 block rounded-md border border-border bg-background px-3 py-2">
            <option value="">All operators</option>
            {((operators as any[]) ?? []).map((o) => (
              <option key={o.id} value={o.id}>{o.name}</option>
            ))}
          </select>
        </label>
        <label className="text-text-secondary">
          Vehicle
          <input name="q" defaultValue={sp.q ?? ""} placeholder="Registration or name" className="mt-1 block rounded-md border border-border bg-background px-3 py-2" />
        </label>
        <label className="text-text-secondary">
          Journey type
          <select name="type" defaultValue={sp.type ?? ""} className="mt-1 block rounded-md border border-border bg-background px-3 py-2">
            <option value="">Any</option>
            <option value="one_way">One way</option>
            <option value="round_trip">Round trip</option>
          </select>
        </label>
        {sp.status && <input type="hidden" name="status" value={sp.status} />}
        <button className="rounded-md border border-border px-4 py-2 hover:border-primary hover:text-primary">Filter</button>
      </form>
      <div className="mb-4 flex flex-wrap gap-2">
        {STATUS_FILTERS.map((f) => (
          <Link
            key={f.key}
            href={link({ status: f.key === "all" ? undefined : f.key })}
            className={`rounded-pill px-3 py-1 text-sm transition ${(sp.status ?? "all") === f.key ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}
          >
            {f.label}
          </Link>
        ))}
      </div>

      <Table>
        <thead>
          <tr>
            <Th>Vehicle</Th>
            <Th>Operator</Th>
            <Th>Route</Th>
            <Th>Origin → Destination</Th>
            <Th>Type</Th>
            <Th>Stops</Th>
            <Th>Route status</Th>
            <Th>Approval</Th>
            <Th>Updated</Th>
            <Th />
          </tr>
        </thead>
        <tbody>
          {filtered.map((r) => (
            <tr key={r.bus.id}>
              <Td>
                <Link href={`/bus-routes/${r.bus.id}`} className="font-medium text-primary hover:underline">{r.bus.registration_number}</Link>
                {r.bus.name && <div className="text-xs text-text-tertiary">{r.bus.name}</div>}
              </Td>
              <Td>{r.bus.operators?.name ?? "—"}</Td>
              <Td>{r.active?.name ?? r.open?.name ?? "—"}</Td>
              <Td>
                {r.outbound ? `${r.outbound.source?.name} → ${r.outbound.destination?.name}` : "—"}
              </Td>
              <Td>{r.hasReturn ? "Round trip" : "One way"}</Td>
              <Td>{r.stops ?? "—"}</Td>
              <Td><Badge status={r.routeStatus} /></Td>
              <Td>
                <Badge status={r.approval} />
                {r.rejected?.rejection_reason && <div className="mt-1 text-xs text-error">{r.rejected.rejection_reason}</div>}
              </Td>
              <Td>{r.updated ? fmtDate(r.updated) : "—"}</Td>
              <Td>
                <Link href={`/bus-routes/${r.bus.id}`} className="text-primary hover:underline">Manage</Link>
                {r.approval === "pending" && (
                  <Link href={`/route-approvals/${r.open.id}`} className="ml-3 text-primary hover:underline">Review</Link>
                )}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!filtered.length && <EmptyState message="No routes match these filters." />}
      <p className="mt-4 text-xs text-text-tertiary">Buses without a route are listed too: open one to create its route or copy another bus&apos;s route onto it.</p>
    </div>
  );
}
