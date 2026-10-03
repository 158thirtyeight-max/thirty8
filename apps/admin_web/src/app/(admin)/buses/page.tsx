import { fmtDate } from "@/lib/format-date";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

/* eslint-disable @typescript-eslint/no-explicit-any */

const FILTERS: { key: string; label: string }[] = [
  { key: "review", label: "Awaiting review" },
  { key: "legacy", label: "Legacy / unmigrated" },
  { key: "changes_requested", label: "Changes requested" },
  { key: "approved", label: "Approved" },
  { key: "active", label: "Active" },
  { key: "suspended", label: "Suspended" },
  { key: "draft", label: "Draft" },
  { key: "all", label: "All" },
];

export default async function BusesPage({ searchParams }: { searchParams: Promise<{ f?: string }> }) {
  const { f } = await searchParams;
  const filter = FILTERS.some((x) => x.key === f) ? (f as string) : "review";

  const supabase = await createClient();
  let query = supabase
    .from("buses")
    .select(
      "id, name, registration_number, bus_type, total_seats, lifecycle_status, status, is_legacy, legacy_migration_status, submitted_at, approved_at, operators(id, name), bus_documents(status)",
    )
    .order("submitted_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false });

  if (filter === "review") {
    // New buses in the queue plus legacy buses whose owner asked for a migration review.
    query = query.or("lifecycle_status.in.(submitted,under_review),legacy_migration_status.in.(submitted,under_review)");
  } else if (filter === "legacy") {
    query = query.eq("is_legacy", true);
  } else if (filter !== "all") {
    query = query.eq("lifecycle_status", filter).eq("is_legacy", false);
  }
  const { data: buses } = await query;

  return (
    <div>
      <PageTitle title="Buses" subtitle="Review buses, migrate legacy buses, and manage their availability" />
      <p className="-mt-3 mb-4 text-sm">
        <Link href="/route-approvals" className="text-primary hover:underline">
          Route approval requests →
        </Link>
      </p>

      <div className="mb-4 flex flex-wrap gap-2">
        {FILTERS.map((x) => (
          <Link
            key={x.key}
            href={`/buses?f=${x.key}`}
            className={`rounded-pill px-3 py-1 text-sm transition ${
              filter === x.key ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"
            }`}
          >
            {x.label}
          </Link>
        ))}
      </div>

      {filter === "legacy" && (
        <p className="mb-4 max-w-2xl text-sm text-text-secondary">
          Legacy buses existed before the approval workflow. They keep running for customers but have never been reviewed. Open one, check its
          documents, layout, route, fares and schedule, then approve it to migrate it — or request changes / suspend it.
        </p>
      )}

      <Table>
        <thead>
          <tr>
            <Th>Bus</Th>
            <Th>Operator</Th>
            <Th>Type</Th>
            <Th>State</Th>
            <Th>Documents</Th>
            <Th>Submitted</Th>
            <Th></Th>
          </tr>
        </thead>
        <tbody>
          {buses?.map((b: any) => (
            <tr key={b.id}>
              <Td>
                <Link href={`/buses/${b.id}`} className="font-medium text-primary hover:underline">
                  {b.name || b.registration_number}
                </Link>
                {b.name && <div className="text-xs text-text-tertiary">{b.registration_number}</div>}
              </Td>
              <Td>
                {b.operators ? (
                  <Link href={`/operators/${b.operators.id}`} className="hover:underline">
                    {b.operators.name}
                  </Link>
                ) : (
                  "—"
                )}
              </Td>
              <Td>
                {String(b.bus_type).replace(/_/g, " ")} · {b.total_seats} seats
              </Td>
              <Td>
                <div className="flex flex-wrap gap-1">
                  <Badge status={b.lifecycle_status} />
                  {b.is_legacy && <Badge status="legacy" />}
                  {b.legacy_migration_status && <Badge status={b.legacy_migration_status} />}
                </div>
              </Td>
              <Td>
                {(() => {
                  const docs: { status: string }[] = b.bus_documents ?? [];
                  const verified = docs.filter((d) => d.status === "verified").length;
                  return docs.length ? `${verified}/${docs.length} verified` : "None uploaded";
                })()}
              </Td>
              <Td>{b.submitted_at ? fmtDate(b.submitted_at) : "—"}</Td>
              <Td>
                <Link href={`/buses/${b.id}`} className="rounded-md border border-border px-2 py-1 text-xs text-primary hover:border-primary">
                  Review →
                </Link>
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!buses?.length && <EmptyState message="No buses match this filter." />}
    </div>
  );
}
