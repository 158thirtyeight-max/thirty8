"use client";

import { useMemo, useState, useTransition } from "react";
import { Badge, Button, EmptyState, Table, Td, Th } from "@/components/ui";
import { clearRouteWindow, saveRouteWindow } from "../actions";

export type RouteWindowRow = {
  route_id: string;
  operator_name: string;
  source_city: string;
  destination_city: string;
  override_enabled: boolean | null;
  override_days: number | null;
  effective_days: number;
  effective_source: "route" | "operator" | "global";
  horizon_date: string;
  updated_at: string | null;
};

const SOURCE_LABEL = { route: "Route override", operator: "Operator override", global: "Global default" } as const;

function Row({ row }: { row: RouteWindowRow }) {
  const [days, setDays] = useState(String(row.override_days ?? row.effective_days));
  const [enabled, setEnabled] = useState(row.override_enabled ?? false);
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const dirty = Number(days) !== (row.override_days ?? row.effective_days) || enabled !== (row.override_enabled ?? false);

  const run = (fn: () => Promise<void>) =>
    startTransition(async () => {
      setError(null);
      try {
        await fn();
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed");
      }
    });

  return (
    <tr>
      <Td>
        {row.source_city} → {row.destination_city}
        <div className="text-xs text-text-tertiary">{row.operator_name}</div>
      </Td>
      <Td>
        <input
          type="number"
          min={1}
          value={days}
          onChange={(e) => setDays(e.target.value)}
          className="w-20 rounded-md border border-border bg-background px-2 py-1"
          aria-label={`Advance booking days for ${row.source_city} to ${row.destination_city}`}
        />{" "}
        days
      </Td>
      <Td>
        <label className="flex items-center gap-2 text-xs">
          <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
          Override on
        </label>
      </Td>
      <Td>
        <strong>{row.effective_days} days</strong>
        <div className="text-xs text-text-tertiary">
          {SOURCE_LABEL[row.effective_source]} · through {new Date(row.horizon_date).toLocaleDateString("en-IN", { day: "numeric", month: "short" })}
        </div>
      </Td>
      <Td className="text-xs text-text-tertiary">{row.updated_at ? new Date(row.updated_at).toLocaleString() : "—"}</Td>
      <Td>
        <div className="flex gap-2">
          <Button
            disabled={isPending || !dirty}
            onClick={() => run(() => saveRouteWindow(row.route_id, Number(days), enabled))}
            className="!px-3 !py-1.5 text-xs"
          >
            {isPending ? "…" : "Save"}
          </Button>
          {row.override_days !== null && (
            <Button variant="outline" disabled={isPending} onClick={() => run(() => clearRouteWindow(row.route_id))} className="!px-3 !py-1.5 text-xs">
              Reset
            </Button>
          )}
        </div>
        {error && <p className="mt-1 max-w-xs text-xs text-error">{error}</p>}
      </Td>
    </tr>
  );
}

export default function RouteWindowTable({ rows }: { rows: RouteWindowRow[] }) {
  const [query, setQuery] = useState("");
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => `${r.source_city} ${r.destination_city} ${r.operator_name}`.toLowerCase().includes(q));
  }, [rows, query]);

  return (
    <div>
      <input
        type="search"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search routes or operators…"
        className="mb-3 w-full max-w-sm rounded-md border border-border bg-background px-3 py-2 text-sm"
      />
      <Table>
        <thead>
          <tr>
            <Th>Route</Th>
            <Th>Advance booking</Th>
            <Th>Route override</Th>
            <Th>Effective window</Th>
            <Th>Last updated</Th>
            <Th></Th>
          </tr>
        </thead>
        <tbody>
          {filtered.map((r) => (
            <Row key={`${r.route_id}:${r.override_days}:${r.override_enabled}`} row={r} />
          ))}
        </tbody>
      </Table>
      {!filtered.length && <EmptyState message="No routes match." />}
      <p className="mt-2 text-xs text-text-tertiary">
        <Badge status="active" /> Changes apply immediately: a longer window generates the extra departures, a shorter one hides departures beyond it
        (nothing is deleted and existing bookings are kept).
      </p>
    </div>
  );
}
