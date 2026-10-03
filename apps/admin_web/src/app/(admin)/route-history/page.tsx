import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageTitle } from "@/components/ui";
import HistoryTable from "../bus-routes/history-table";

/* eslint-disable @typescript-eslint/no-explicit-any */

const FILTERS = [
  { key: "all", label: "All" },
  { key: "operator", label: "Operator" },
  { key: "admin", label: "Admin" },
  { key: "route_copy", label: "Route copy" },
];

export default async function RouteHistoryPage({ searchParams }: { searchParams: Promise<{ origin?: string }> }) {
  const { origin } = await searchParams;
  const supabase = await createClient();
  const { data } = await supabase.rpc("get_route_history", { p_bus_id: null });
  const rows = ((data as any[]) ?? []).filter((r) => !origin || origin === "all" || r.origin === origin);
  return (
    <div>
      <PageTitle title="Route history" subtitle="Every route revision across all buses: where it came from, who changed it, what it replaced and whether it was published." />
      <div className="mb-4 flex flex-wrap gap-2">
        {FILTERS.map((f) => (
          <Link
            key={f.key}
            href={f.key === "all" ? "/route-history" : `/route-history?origin=${f.key}`}
            className={`rounded-pill px-3 py-1 text-sm transition ${(origin ?? "all") === f.key ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}
          >
            {f.label}
          </Link>
        ))}
      </div>
      <HistoryTable rows={rows} showBus />
    </div>
  );
}
