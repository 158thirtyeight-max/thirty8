import { fmtDateTime } from "@/lib/format-date";
import Link from "next/link";
import { Badge, EmptyState, Table, Td, Th } from "@/components/ui";

/* eslint-disable @typescript-eslint/no-explicit-any */

export const ORIGIN_LABEL: Record<string, string> = { operator: "Operator", admin: "Admin", route_copy: "Route copy" };

/** Rows come from get_route_history. showBus adds the vehicle / operator columns. */
export default function HistoryTable({ rows, showBus }: { rows: any[]; showBus?: boolean }) {
  return (
    <>
      <Table>
        <thead>
          <tr>
            {showBus && <Th>Vehicle</Th>}
            {showBus && <Th>Operator</Th>}
            <Th>Rev</Th>
            <Th>Route</Th>
            <Th>Origin</Th>
            <Th>Status</Th>
            <Th>Created by</Th>
            <Th>Replaced</Th>
            <Th>Reason</Th>
            <Th>When</Th>
            <Th />
          </tr>
        </thead>
        <tbody>
          {rows.map((h) => (
            <tr key={h.id}>
              {showBus && (
                <Td>
                  <Link href={`/bus-routes/${h.bus_id}`} className="text-primary hover:underline">{h.registration_number}</Link>
                </Td>
              )}
              {showBus && <Td>{h.operator_name}</Td>}
              <Td>{h.revision_no}</Td>
              <Td>
                {h.name ?? "Route"} <span className="text-xs text-text-tertiary">· {String(h.trip_type).replace(/_/g, " ")}</span>
                {h.is_active && <span className="ml-2 text-xs text-success">live</span>}
              </Td>
              <Td>
                {ORIGIN_LABEL[h.origin] ?? h.origin}
                {h.origin === "route_copy" && h.source_registration_number && <div className="text-xs text-text-tertiary">from {h.source_registration_number}</div>}
              </Td>
              <Td>
                <Badge status={h.status} />
                {h.is_published && <div className="mt-1 text-xs text-text-tertiary">published by admin</div>}
              </Td>
              <Td>
                {h.created_by_name ?? "—"}
                {h.reviewed_by_name && <div className="text-xs text-text-tertiary">reviewed: {h.reviewed_by_name}</div>}
              </Td>
              <Td>{h.previous_revision_no != null ? `rev ${h.previous_revision_no}` : "—"}</Td>
              <Td className="max-w-xs">
                <span className="line-clamp-2">{h.change_reason ?? "—"}</span>
                {h.rejection_reason && <div className="text-xs text-error">Rejected: {h.rejection_reason}</div>}
              </Td>
              <Td>{fmtDateTime(h.published_at ?? h.reviewed_at ?? h.submitted_at ?? h.created_at)}</Td>
              <Td>
                <Link href={`/route-approvals/${h.id}`} className="text-xs text-primary hover:underline">View</Link>
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!rows.length && <EmptyState message="No route revisions yet." />}
    </>
  );
}
