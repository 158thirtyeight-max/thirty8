import { fmtDateTime, fmtDate } from "@/lib/format-date";
import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Badge, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { reviewRouteRevision } from "../actions";
import { DirectionCompare } from "../route-compare";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function RouteApprovalDetail({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ error?: string; notice?: string }>;
}) {
  const { id } = await params;
  const { error, notice } = await searchParams;
  const supabase = await createClient();

  const { data: rev } = await supabase
    .from("route_revisions")
    .select(
      "id, bus_id, revision_no, status, trip_type, name, change_reason, rejection_reason, submitted_at, reviewed_at, " +
        "submitter:profiles!route_revisions_submitted_by_fkey(full_name, email), reviewer:profiles!route_revisions_reviewed_by_fkey(full_name, email), " +
        "buses!route_revisions_bus_id_fkey(id, name, registration_number, active_route_revision_id), operators(id, name)",
    )
    .eq("id", id)
    .maybeSingle();
  if (!rev) notFound();
  const r: any = rev;

  const [{ data: diff }, { data: history }, { data: events }] = await Promise.all([
    supabase.rpc("get_route_revision_diff", { p_revision_id: id }),
    supabase
      .from("route_revisions")
      .select("id, revision_no, status, trip_type, name, change_reason, submitted_at, reviewed_at, rejection_reason")
      .eq("bus_id", r.bus_id)
      .order("revision_no", { ascending: false }),
    supabase
      .from("route_revision_events")
      .select("id, event, reason, created_at, actor:profiles(full_name, email)")
      .eq("revision_id", id)
      .order("created_at"),
  ]);
  const d: any = diff ?? {};
  const pending = r.status === "pending_approval";
  const person = (p: any) => (p ? p.full_name || p.email || "—" : "—");

  return (
    <div>
      <Link href="/route-approvals" className="text-sm text-text-secondary hover:text-primary">
        ← Route approval requests
      </Link>
      <div className="mt-2">
        <PageTitle
          title={`${r.name ?? "Route"} · revision ${r.revision_no}`}
          subtitle={`${r.operators?.name ?? "Operator"} · bus ${r.buses?.registration_number ?? ""}`}
        />
      </div>

      {error && <p className="mb-4 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}
      {notice && (
        <p className="mb-4 rounded-md border border-success/40 bg-success/10 px-4 py-3 text-sm text-success">
          {notice === "approved" ? "Route change approved. The new route is now live." : "Route change rejected. The current route stays live."}
        </p>
      )}

      <div className="mb-6 grid gap-4 rounded-lg border border-border bg-surface p-4 text-sm md:grid-cols-4">
        <div>
          <p className="text-text-tertiary">Status</p>
          <Badge status={r.status} />
        </div>
        <div>
          <p className="text-text-tertiary">Trip type</p>
          <p className="capitalize">
            {d.trip_type ? `${String(d.trip_type.current).replace(/_/g, " ")} → ${String(d.trip_type.proposed).replace(/_/g, " ")}` : String(r.trip_type).replace(/_/g, " ")}
          </p>
        </div>
        <div>
          <p className="text-text-tertiary">Submitted by</p>
          <p>{person(r.submitter)}</p>
          <p className="text-xs text-text-tertiary">{r.submitted_at ? fmtDateTime(r.submitted_at) : "—"}</p>
        </div>
        <div>
          <p className="text-text-tertiary">Reviewed by</p>
          <p>{person(r.reviewer)}</p>
          <p className="text-xs text-text-tertiary">{r.reviewed_at ? fmtDateTime(r.reviewed_at) : "—"}</p>
        </div>
        <div className="md:col-span-4">
          <p className="text-text-tertiary">Change reason</p>
          <p>{r.change_reason ?? "—"}</p>
        </div>
        {r.rejection_reason && (
          <div className="md:col-span-4">
            <p className="text-text-tertiary">Rejection reason</p>
            <p className="text-error">{r.rejection_reason}</p>
          </div>
        )}
      </div>

      {r.status === "draft" ? (
        <p className="text-sm text-text-tertiary">This revision is still a draft and has not been submitted.</p>
      ) : (
        <>
          <DirectionCompare title="Outbound journey" block={d.outbound} />
          <DirectionCompare title="Return journey" block={d.return} />
        </>
      )}

      {pending && (
        <section className="mb-8 rounded-lg border border-border bg-surface p-4">
          <SectionHeader title="Decision" />
          <p className="mb-3 text-sm text-text-secondary">
            Approving makes the proposed route live for new trips and keeps the previous revision in the history. Existing bookings are not changed;
            any booking affected by a removed stop is flagged for review.
          </p>
          <div className="flex flex-wrap items-start gap-6">
            <form action={reviewRouteRevision.bind(null, id, "approve")}>
              <ConfirmButton message="Approve this route change and make it live?">Approve route</ConfirmButton>
            </form>
            <form action={reviewRouteRevision.bind(null, id, "reject")} className="flex flex-1 flex-wrap items-start gap-2">
              <textarea
                name="reason"
                required
                rows={2}
                placeholder="Reason for rejection (shown to the operator)"
                className="min-w-64 flex-1 rounded-md border border-border bg-background px-3 py-2 text-sm"
              />
              <ConfirmButton variant="destructive" message="Reject this route change? The current route stays live.">
                Reject route
              </ConfirmButton>
            </form>
          </div>
        </section>
      )}

      <section className="mb-8">
        <SectionHeader title="Approval history" />
        <Table>
          <thead>
            <tr>
              <Th>When</Th>
              <Th>Event</Th>
              <Th>By</Th>
              <Th>Reason</Th>
            </tr>
          </thead>
          <tbody>
            {((events as any[]) ?? []).map((e) => (
              <tr key={e.id}>
                <Td>{fmtDateTime(e.created_at)}</Td>
                <Td>
                  <Badge status={e.event === "submitted" ? "pending" : e.event} />
                </Td>
                <Td>{person(e.actor)}</Td>
                <Td>{e.reason ?? "—"}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </section>

      <section>
        <SectionHeader title="Previous revisions of this bus" />
        <Table>
          <thead>
            <tr>
              <Th>Rev</Th>
              <Th>Route</Th>
              <Th>Type</Th>
              <Th>Status</Th>
              <Th>Submitted</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody>
            {((history as any[]) ?? []).map((h) => (
              <tr key={h.id} className={h.id === id ? "bg-primary/5" : ""}>
                <Td>{h.revision_no}</Td>
                <Td>
                  {h.name ?? "Route"}
                  {h.id === r.buses?.active_route_revision_id && <span className="ml-2 text-xs text-success">live</span>}
                </Td>
                <Td className="capitalize">{String(h.trip_type).replace(/_/g, " ")}</Td>
                <Td>
                  <Badge status={h.status} />
                </Td>
                <Td>{h.submitted_at ? fmtDate(h.submitted_at) : "—"}</Td>
                <Td>
                  {h.id !== id && (
                    <Link href={`/route-approvals/${h.id}`} className="text-xs text-primary hover:underline">
                      View
                    </Link>
                  )}
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </section>
    </div>
  );
}
