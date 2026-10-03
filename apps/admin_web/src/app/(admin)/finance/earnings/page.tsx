import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { bpsToPct, inr } from "@/lib/money";
import { Badge, Button, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { holdEarning, releaseEarning } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const STATUSES = ["all", "pending_boarding", "eligible", "on_hold", "in_batch", "settled", "void", "clawed_back"];

export default async function EarningsPage({ searchParams }: { searchParams: Promise<{ status?: string; error?: string; ok?: string }> }) {
  const { status, error, ok } = await searchParams;
  const filter = STATUSES.includes(status ?? "") ? (status as string) : "all";
  const supabase = await createClient();
  let q = supabase
    .from("operator_earnings")
    .select("id, status, hold_reason, gross_cents, commission_bps, commission_cents, operator_net_cents, commission_basis, rounding_policy, eligible_at, eligible_cycle, refund_adjustment_cents, settlement_id, bookings(booking_reference), operators(name), settlements(reference)")
    .order("created_at", { ascending: false })
    .limit(200);
  if (filter !== "all") q = q.eq("status", filter);
  const { data: earnings } = await q;

  return (
    <div>
      <PageTitle title="Operator earnings" subtitle="One row per ticket. Boarding makes it eligible; the weekly settlement pays it. The commission rate is frozen on each row." />
      <FinanceNav current="/finance/earnings" />
      <Notice error={error} ok={ok} />
      <div className="mb-4 flex flex-wrap items-center gap-2">
        {STATUSES.map((s) => (
          <Link key={s} href={s === "all" ? "/finance/earnings" : `/finance/earnings?status=${s}`}
            className={`rounded-pill px-3 py-1 text-sm ${filter === s ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}>
            {s.replace(/_/g, " ")}
          </Link>
        ))}
        <a href={`/finance/earnings/export${filter === "all" ? "" : `?status=${filter}`}`} className="ml-auto text-sm text-primary hover:underline">Export CSV</a>
      </div>
      <Table>
        <thead>
          <tr><Th>Ticket</Th><Th>Operator</Th><Th>Gross</Th><Th>Commission calculation</Th><Th>Operator net</Th><Th>Status</Th><Th>Batch</Th><Th></Th></tr>
        </thead>
        <tbody>
          {(earnings as any[] | null)?.map((e) => (
            <tr key={e.id}>
              <Td className="font-mono">{e.bookings?.booking_reference}</Td>
              <Td>{e.operators?.name}</Td>
              <Td>{inr(e.gross_cents)}</Td>
              <Td>
                {e.commission_bps === null ? <span className="text-text-tertiary">not configured yet</span> : (
                  <>
                    {inr(e.commission_cents)}
                    <div className="text-xs text-text-tertiary">{bpsToPct(e.commission_bps)} of {inr(e.gross_cents)}, {e.rounding_policy} rounding, remainder to operator</div>
                  </>
                )}
              </Td>
              <Td>{inr(e.operator_net_cents)}</Td>
              <Td>
                <Badge status={e.status} />
                {e.hold_reason && <div className="mt-1 text-xs text-text-tertiary">{String(e.hold_reason).replace(/_/g, " ")}</div>}
                {e.eligible_at && <div className="mt-1 text-xs text-text-tertiary">eligible {fmtDateTime(e.eligible_at)}</div>}
              </Td>
              <Td className="font-mono text-xs">{e.settlements?.reference ?? "—"}</Td>
              <Td>
                {["pending_boarding", "eligible"].includes(e.status) && (
                  <form action={holdEarning} className="flex gap-1">
                    <input type="hidden" name="id" value={e.id} />
                    <input name="reason" required placeholder="Hold reason" className={`${inputClass} w-32`} />
                    <Button type="submit" variant="outline" className="px-2 py-1 text-xs">Hold</Button>
                  </form>
                )}
                {e.status === "on_hold" && e.hold_reason === "admin_hold" && (
                  <form action={releaseEarning}>
                    <input type="hidden" name="id" value={e.id} />
                    <Button type="submit" variant="outline" className="px-2 py-1 text-xs">Release hold</Button>
                  </form>
                )}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!earnings?.length && <EmptyState message="No earnings yet." />}
    </div>
  );
}
