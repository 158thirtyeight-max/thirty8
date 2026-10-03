import { fmtDateTime } from "@/lib/format-date";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

/* eslint-disable @typescript-eslint/no-explicit-any */

const FILTERS: { key: string; label: string }[] = [
  { key: "pending_approval", label: "Pending" },
  { key: "approved", label: "Approved" },
  { key: "rejected", label: "Rejected" },
  { key: "all", label: "All" },
];

export default async function RouteApprovalsPage({ searchParams }: { searchParams: Promise<{ f?: string }> }) {
  const { f } = await searchParams;
  const filter = FILTERS.some((x) => x.key === f) ? (f as string) : "pending_approval";

  const supabase = await createClient();
  let query = supabase
    .from("route_revisions")
    .select(
      "id, revision_no, status, trip_type, name, change_reason, submitted_at, reviewed_at, rejection_reason, " +
        "buses!route_revisions_bus_id_fkey(id, name, registration_number, active_route_revision_id), operators(id, name)",
    )
    .neq("status", "draft")
    .order("submitted_at", { ascending: false, nullsFirst: false })
    .limit(200);
  if (filter !== "all") query = query.eq("status", filter);
  const { data } = await query;
  const rows: any[] = (data as any[]) ?? [];

  // Name of the route currently live for each bus (its active revision).
  const activeIds = [...new Set(rows.map((r) => r.buses?.active_route_revision_id).filter(Boolean))] as string[];
  const activeNames = new Map<string, any>();
  if (activeIds.length) {
    const { data: act } = await supabase.from("route_revisions").select("id, name, trip_type, revision_no").in("id", activeIds);
    for (const a of (act as any[]) ?? []) activeNames.set(a.id, a);
  }

  return (
    <div>
      <PageTitle title="Route approval requests" subtitle="Operator route changes wait here. The current route stays live until a change is approved." />

      <div className="mb-4 flex flex-wrap gap-2">
        {FILTERS.map((x) => (
          <Link
            key={x.key}
            href={`/route-approvals?f=${x.key}`}
            className={`rounded-pill px-3 py-1 text-sm transition ${
              filter === x.key ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"
            }`}
          >
            {x.label}
          </Link>
        ))}
      </div>

      <Table>
        <thead>
          <tr>
            <Th>Operator</Th>
            <Th>Bus</Th>
            <Th>Current approved route</Th>
            <Th>Proposed route</Th>
            <Th>Change reason</Th>
            <Th>Submitted</Th>
            <Th>Status</Th>
            <Th></Th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const active = r.buses?.active_route_revision_id ? activeNames.get(r.buses.active_route_revision_id) : null;
            return (
              <tr key={r.id}>
                <Td>{r.operators?.name ?? "—"}</Td>
                <Td>
                  <Link href={`/buses/${r.buses?.id}`} className="font-medium text-primary hover:underline">
                    {r.buses?.registration_number}
                  </Link>
                  {r.buses?.name && <div className="text-xs text-text-tertiary">{r.buses.name}</div>}
                </Td>
                <Td>
                  {active ? (
                    <>
                      {active.name ?? "Route"} <span className="text-xs text-text-tertiary">· {String(active.trip_type).replace(/_/g, " ")}</span>
                    </>
                  ) : (
                    <span className="text-text-tertiary">None yet</span>
                  )}
                </Td>
                <Td>
                  {r.name ?? "Route"} <span className="text-xs text-text-tertiary">· {String(r.trip_type).replace(/_/g, " ")} · rev {r.revision_no}</span>
                </Td>
                <Td className="max-w-xs">
                  <span className="line-clamp-2">{r.change_reason ?? "—"}</span>
                  {r.status === "rejected" && r.rejection_reason && (
                    <div className="mt-1 text-xs text-error">Rejected: {r.rejection_reason}</div>
                  )}
                </Td>
                <Td>{r.submitted_at ? fmtDateTime(r.submitted_at) : "—"}</Td>
                <Td>
                  <Badge status={r.status} />
                </Td>
                <Td>
                  <Link href={`/route-approvals/${r.id}`} className="rounded-md border border-border px-2 py-1 text-xs text-primary hover:border-primary">
                    {r.status === "pending_approval" ? "Review →" : "View →"}
                  </Link>
                </Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
      {!rows.length && <EmptyState message="No route requests match this filter." />}
    </div>
  );
}
