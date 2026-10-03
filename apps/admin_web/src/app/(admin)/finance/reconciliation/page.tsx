import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { resolveException, runReconciliation } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const STATUSES = ["open", "resolved", "ignored", "all"];
const HELP: Record<string, string> = {
  captured_not_applied: "A payment was captured but could not be applied to the booking; a refund was requested.",
  captured_without_confirmed_booking: "A captured payment has no confirmed booking and no refund.",
  duplicate_capture: "The customer was charged twice for one order; the duplicate needs a refund.",
  unmatched_refund_event: "Razorpay reported a refund we did not issue.",
  refund_state_conflict: "Razorpay reported a refund in a state our records do not allow.",
  refund_processed_after_failure: "A refund we recorded as failed was in fact processed by Razorpay.",
  webhook_unmatched_order: "A Razorpay webhook referred to an order we do not have.",
  settlement_awaiting_bank_result: "An exported payment file has no bank result after 3 days.",
  ledger_unbalanced: "A ledger journal does not balance. This should be impossible: investigate immediately.",
  export_hash_mismatch: "An exported file no longer matches its recorded SHA-256.",
  operator_payable_mismatch: "What the ledger says we owe an operator differs from their earnings records.",
  settlement_payment_mismatch: "A batch is marked paid without a matching bank payment record.",
};

export default async function ReconciliationPage({ searchParams }: { searchParams: Promise<{ status?: string; error?: string; ok?: string }> }) {
  const { status, error, ok } = await searchParams;
  const filter = STATUSES.includes(status ?? "") ? (status as string) : "open";
  const supabase = await createClient();
  let q = supabase.from("reconciliation_exceptions").select("*").order("detected_at", { ascending: false }).limit(200);
  if (filter !== "all") q = q.eq("status", filter);
  const [{ data: exceptions }, { data: runs }] = await Promise.all([
    q,
    supabase.from("reconciliation_runs").select("id, started_at, finished_at, found_count, summary").order("started_at", { ascending: false }).limit(10),
  ]);

  return (
    <div>
      <PageTitle title="Reconciliation" subtitle="Differences between payments, the ledger, earnings and the bank. The system reports them; it never changes a financial record to force a match." />
      <FinanceNav current="/finance/reconciliation" />
      <Notice error={error} ok={ok} />

      <form action={runReconciliation} className="mb-6">
        <ConfirmButton message="Run the reconciliation checks now? They only report; nothing is edited.">Run checks now</ConfirmButton>
        <span className="ml-3 text-xs text-text-tertiary">Also runs automatically every night. Razorpay-side comparison (orders, payments, refunds, settlement report) is a separate integration.</span>
      </form>

      <div className="mb-4 flex gap-2">
        {STATUSES.map((s) => (
          <Link key={s} href={`/finance/reconciliation?status=${s}`}
            className={`rounded-pill px-3 py-1 text-sm ${filter === s ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}>{s}</Link>
        ))}
      </div>

      <Table>
        <thead><tr><Th>Exception</Th><Th>Severity</Th><Th>Entity</Th><Th>Details</Th><Th>Detected</Th><Th>Status</Th><Th>Resolve (full admin)</Th></tr></thead>
        <tbody>
          {(exceptions as any[] | null)?.map((e) => (
            <tr key={e.id}>
              <Td><span className="font-mono text-xs">{e.kind}</span>{HELP[e.kind] && <div className="max-w-xs text-xs text-text-secondary">{HELP[e.kind]}</div>}</Td>
              <Td><Badge status={e.severity === "critical" ? "failed" : e.severity === "warning" ? "pending" : "verified"} /> <span className="text-xs">{e.severity}</span></Td>
              <Td className="font-mono text-xs">{e.entity_type}<div className="max-w-[14rem] truncate">{e.entity_id}</div></Td>
              <Td className="max-w-xs truncate font-mono text-xs text-text-tertiary">{JSON.stringify(e.details)}</Td>
              <Td>{fmtDateTime(e.detected_at)}</Td>
              <Td><Badge status={e.status === "open" ? "pending" : "verified"} /> <span className="text-xs">{e.status}</span>{e.resolution_note && <div className="max-w-xs text-xs text-text-secondary">{e.resolution_note}</div>}</Td>
              <Td>
                {e.status === "open" && (
                  <form action={resolveException} className="flex flex-col gap-1">
                    <input type="hidden" name="id" value={e.id} />
                    <input name="note" required placeholder="What was checked / done" className={`${inputClass} py-1 text-xs`} />
                    <div className="flex gap-1">
                      <select name="status" className={`${inputClass} py-1 text-xs`} defaultValue="resolved"><option value="resolved">Resolved</option><option value="ignored">Ignore</option></select>
                      <ConfirmButton variant="outline" className="px-2 py-1 text-xs" message="Close this exception? The underlying records are not changed.">Close</ConfirmButton>
                    </div>
                  </form>
                )}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!exceptions?.length && <EmptyState message={filter === "open" ? "No open exceptions." : "Nothing here."} />}

      <div className="mt-8">
        <SectionHeader title="Recent runs" />
        <Table>
          <thead><tr><Th>Started</Th><Th>Findings</Th><Th>Breakdown</Th></tr></thead>
          <tbody>
            {(runs as any[] | null)?.map((r) => (
              <tr key={r.id}><Td>{fmtDateTime(r.started_at)}</Td><Td>{r.found_count}</Td><Td className="text-xs text-text-secondary">{Object.entries(r.summary ?? {}).filter(([, v]) => Number(v) > 0).map(([k, v]) => `${k.replace(/_/g, " ")}: ${v}`).join(" · ") || "clean"}</Td></tr>
            ))}
          </tbody>
        </Table>
      </div>
    </div>
  );
}
