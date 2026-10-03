import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Badge, Button, PageTitle, SectionHeader } from "@/components/ui";
import { DirectionCompare } from "../../route-approvals/route-compare";
import CopyRouteForm from "../copy-route-form";
import HistoryTable from "../history-table";
import { startRevision } from "../actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function BusRoutePage({ params, searchParams }: { params: Promise<{ busId: string }>; searchParams: Promise<{ error?: string; notice?: string }> }) {
  const { busId } = await params;
  const { error, notice } = await searchParams;
  const supabase = await createClient();

  const { data: bus } = await supabase
    .from("buses")
    .select("id, name, registration_number, lifecycle_status, operator_id, active_route_revision_id, operators(id, name)")
    .eq("id", busId)
    .maybeSingle();
  if (!bus) notFound();
  const b: any = bus;

  const [{ data: history }, { data: siblings }] = await Promise.all([
    supabase.rpc("get_route_history", { p_bus_id: busId }),
    supabase.from("buses").select("id, name, registration_number, operators(name)").neq("id", busId).in("lifecycle_status", ["draft", "changes_requested", "approved", "active"]).order("registration_number"),
  ]);
  const rows: any[] = (history as any[]) ?? [];
  const open = rows.find((r) => r.status === "draft" || r.status === "pending_approval");
  const active = rows.find((r) => r.id === b.active_route_revision_id);

  // The live route shown as a "compare to itself" so the timeline component is reused.
  const { data: activeDiff } = active ? await supabase.rpc("get_route_revision_diff", { p_revision_id: active.id }) : { data: null };
  const live: any = activeDiff as any;
  const asView = (block: any) => (block?.proposed ? { current: block.proposed, proposed: block.proposed, changes: null } : null);

  return (
    <div>
      <Link href="/bus-routes" className="text-sm text-text-secondary hover:text-primary">← Routes</Link>
      <div className="mt-2">
        <PageTitle title={`${b.registration_number}${b.name ? ` · ${b.name}` : ""}`} subtitle={`${b.operators?.name ?? "Operator"} · bus is ${String(b.lifecycle_status).replace(/_/g, " ")}`} />
      </div>
      {error && <p className="mb-4 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}
      {notice === "published" && <p className="mb-4 rounded-md border border-success/40 bg-success/10 px-4 py-3 text-sm text-success">Route published. It is now live for customer search.</p>}

      <section className="mb-8 rounded-lg border border-border bg-surface p-4">
        <SectionHeader title="Route" />
        <div className="flex flex-wrap items-center gap-3 text-sm">
          {active ? (
            <>
              <span className="font-medium">{active.name ?? "Route"}</span>
              <span className="capitalize text-text-secondary">{String(active.trip_type).replace(/_/g, " ")}</span>
              <span className="text-text-tertiary">revision {active.revision_no}</span>
              <Badge status="active" />
            </>
          ) : (
            <span className="text-text-tertiary">No approved route yet.</span>
          )}
        </div>
        <div className="mt-4 flex flex-wrap items-center gap-3">
          {open ? (
            open.status === "draft" ? (
              <Link href={`/bus-routes/edit/${open.id}`} className="rounded-md bg-primary px-4 py-2 text-sm font-medium text-white hover:bg-primary-dark">
                {open.origin === "operator" ? "View" : "Continue editing"} draft (rev {open.revision_no})
              </Link>
            ) : (
              <Link href={`/route-approvals/${open.id}`} className="rounded-md bg-primary px-4 py-2 text-sm font-medium text-white hover:bg-primary-dark">
                Review pending change (rev {open.revision_no})
              </Link>
            )
          ) : (
            <form action={startRevision.bind(null, busId)}>
              <Button type="submit">{active ? "Edit route" : "Create route"}</Button>
            </form>
          )}
        </div>
        {open?.status === "draft" && open.origin === "operator" && (
          <p className="mt-2 text-xs text-text-tertiary">The operator has an unsubmitted draft. Only the operator can edit it; you can open it to view or discard it.</p>
        )}
      </section>

      {active && live && (
        <section className="mb-8">
          <SectionHeader title="Live route" />
          <DirectionCompare title="Outbound journey" block={asView(live.outbound)} />
          <DirectionCompare title="Return journey" block={asView(live.return)} />
        </section>
      )}

      {active && (
        <section className="mb-8 rounded-lg border border-border bg-surface p-4">
          <SectionHeader title="Copy this route to another bus" />
          <CopyRouteForm
            sourceBusId={busId}
            targets={((siblings as any[]) ?? []).map((s) => ({ id: s.id, label: `${s.registration_number}${s.name ? ` · ${s.name}` : ""} (${s.operators?.name ?? "operator"})` }))}
          />
        </section>
      )}

      {!active && (
        <section className="mb-8 rounded-lg border border-border bg-surface p-4">
          <SectionHeader title="Copy a route onto this bus" />
          <p className="text-sm text-text-secondary">
            Open the bus whose route you want to reuse under <Link href="/bus-routes" className="text-primary hover:underline">Routes</Link> and use <i>Copy this route to another bus</i>, choosing {b.registration_number}.
          </p>
        </section>
      )}

      <section>
        <SectionHeader title="Route history" />
        <HistoryTable rows={rows} />
      </section>
    </div>
  );
}
