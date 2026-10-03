import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { bpsToPct, inr } from "@/lib/money";
import { Badge, EmptyState, PageTitle, StatCard, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../finance/notice";
import { inputClass } from "../finance/_util";
import { approveRefundForm, executeRefund, overrideRefundForm, rejectRefund, retryRefund } from "./actions";
import ProcessButton from "./process-button";

/* eslint-disable @typescript-eslint/no-explicit-any */

const STATUSES = ["all", "requested", "approved", "submitted_to_provider", "processed", "failed", "rejected"];

export default async function RefundsPage({ searchParams }: { searchParams: Promise<{ status?: string; error?: string; ok?: string }> }) {
  const { status, error, ok } = await searchParams;
  const filter = STATUSES.includes(status ?? "") ? (status as string) : "all";
  const supabase = await createClient();

  const [{ data: dash }, { data: list, error: listError }, { data: policies }] = await Promise.all([
    supabase.rpc("admin_refund_dashboard"),
    supabase.rpc("admin_list_refunds", { p_status: filter === "all" ? undefined : filter, p_limit: 200 }),
    supabase.from("refund_policies").select("id, name, category, refund_bps").eq("status", "active").order("name"),
  ]);
  const d: any = dash ?? {};
  const refunds = (list as any[] | null) ?? [];

  // the calculation each pending request would get, shown BEFORE anything is approved
  const previews = new Map<string, any>();
  await Promise.all(
    refunds.filter((r) => r.status === "requested").slice(0, 40).map(async (r) => {
      const { data } = await supabase.rpc("admin_preview_refund", { p_refund_id: r.refund_id });
      previews.set(r.refund_id, data);
    }),
  );

  return (
    <div>
      <PageTitle title="Refund requests" subtitle="Cancellations only request a refund. You review the policy calculation, approve, then execute: nothing is refunded automatically, and a refund counts as done only when Razorpay confirms it." />
      <FinanceNav current="/refunds" />
      <Notice error={error ?? listError?.message} ok={ok} />

      <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Total requests" value={d.total_requests ?? 0} />
        <StatCard label="Awaiting approval" value={d.pending_approval ?? 0} />
        <StatCard label="Approved, not executed" value={d.approved_not_executed ?? 0} />
        <StatCard label="Processing with Razorpay" value={d.processing_with_razorpay ?? 0} />
        <StatCard label="Refunded" value={d.refunded ?? 0} />
        <StatCard label="Failed" value={d.failed ?? 0} />
        <StatCard label="Total refunded" value={inr(d.total_refunded_cents)} />
        <StatCard label="Cancellation deductions" value={inr(d.total_deductions_cents)} />
        <StatCard label="Outstanding operator recovery" value={inr(d.outstanding_recovery_cents)} />
      </div>

      <div className="mb-4 flex flex-wrap gap-2">
        {STATUSES.map((s) => (
          <Link key={s} href={s === "all" ? "/refunds" : `/refunds?status=${s}`}
            className={`rounded-pill px-3 py-1 text-sm ${filter === s ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}>
            {s.replace(/_/g, " ")}
          </Link>
        ))}
      </div>

      <Table>
        <thead>
          <tr><Th>Booking / ticket</Th><Th>Customer</Th><Th>Operator &amp; trip</Th><Th>Amounts</Th><Th>Policy</Th><Th>Status</Th><Th>Dates &amp; provider</Th><Th>Actions</Th></tr>
        </thead>
        <tbody>
          {refunds.map((r) => {
            const pv = previews.get(r.refund_id);
            return (
              <tr key={r.refund_id} className="align-top">
                <Td className="font-mono">{r.booking_reference ?? "—"}
                  <div className="font-sans text-xs text-text-tertiary">{r.ticket_count ?? 0} ticket(s){r.first_ticket_id ? ` · ${String(r.first_ticket_id).slice(0, 8)}` : ""}</div>
                  <div className="font-sans text-xs text-text-tertiary">{String(r.reason_category ?? "").replace(/_/g, " ")}</div>
                </Td>
                <Td>{r.customer_name ?? "—"}<div className="text-xs text-text-tertiary">{r.customer_email ?? ""} {r.customer_phone ?? ""}</div></Td>
                <Td>{r.operator_name ?? "—"}<div className="text-xs text-text-tertiary">{r.trip_label ?? ""} {r.departure_at ? `· ${fmtDateTime(r.departure_at)}` : ""}</div></Td>
                <Td>
                  <div>Ticket {inr(r.original_amount_cents)}</div>
                  <div className="text-xs text-text-secondary">Refund {inr(r.refund_cents)}{r.deduction_cents != null ? ` · deduction ${inr(r.deduction_cents)}` : ""}</div>
                  {r.operator_share_cents ? <div className="text-xs text-text-tertiary">operator share {inr(r.operator_share_cents)}</div> : null}
                </Td>
                <Td className="text-xs">
                  {r.policy_name ? <>{r.policy_name} v{r.policy_version}<div>{bpsToPct(r.policy_refund_bps)} refund · {String(r.calc_source).replace(/_/g, " ")}</div></> : "—"}
                  {r.overridden && <div className="text-warning">override authorized</div>}
                  {r.status === "requested" && pv && (
                    pv.error
                      ? <div className="mt-1 text-warning">No applicable policy: choose one or authorize an override.</div>
                      : <div className="mt-1 rounded bg-primary/5 p-2 text-text-secondary">
                          Calculation: {pv.policy_name} ({bpsToPct(pv.refund_bps)}) on {inr(pv.eligible_cents)}<br />
                          refund {inr(pv.refund_cents)} · deduction {inr(pv.deduction_cents)} · {Math.round(pv.hours_before_departure ?? 0)}h before departure
                        </div>
                  )}
                </Td>
                <Td>
                  <Badge status={r.status} />
                  {r.status === "failed" && r.failure_reason && <div className="mt-1 max-w-xs text-xs text-error">{r.failure_reason}</div>}
                  {r.status === "rejected" && r.rejection_reason && <div className="mt-1 max-w-xs text-xs text-text-tertiary">{r.rejection_reason}</div>}
                  {r.retry_count > 0 && <div className="text-xs text-text-tertiary">retries: {r.retry_count}</div>}
                </Td>
                <Td className="text-xs text-text-secondary">
                  <div>requested {fmtDateTime(r.requested_at)}</div>
                  <div>processed {r.processed_at ? fmtDateTime(r.processed_at) : "—"}</div>
                  <div>approved by {r.approved_by_name ?? "—"}</div>
                  <div className="font-mono">{r.razorpay_payment_id ?? ""}</div>
                  <div className="font-mono">{r.razorpay_refund_id ?? ""}</div>
                  <div>payment {String(r.payment_status).replace(/_/g, " ")}</div>
                </Td>
                <Td>
                  <div className="flex flex-col gap-2">
                    {r.status === "requested" && (
                      <>
                        <form action={approveRefundForm} className="flex flex-wrap items-center gap-1">
                          <input type="hidden" name="refund_id" value={r.refund_id} />
                          <select name="policy_id" defaultValue="" className={`${inputClass} w-44 py-1 text-xs`}>
                            <option value="">{pv && !pv.error ? "Use the booking's policy" : "Choose a policy…"}</option>
                            {(policies as any[] | null)?.map((p) => <option key={p.id} value={p.id}>{p.name} ({bpsToPct(p.refund_bps)})</option>)}
                          </select>
                          <ConfirmButton className="px-2 py-1 text-xs" message={`Approve this refund${pv && !pv.error ? ` of ${inr(pv.refund_cents)}` : ""}? The amount comes from the policy calculation; you will still have to execute it.`}>Approve</ConfirmButton>
                        </form>
                        <details>
                          <summary className="cursor-pointer text-xs text-primary">Authorize a different amount…</summary>
                          <form action={overrideRefundForm} className="mt-2 flex flex-col gap-1">
                            <input type="hidden" name="refund_id" value={r.refund_id} />
                            <input name="amount" required inputMode="decimal" placeholder="Amount in rupees" className={`${inputClass} py-1 text-xs`} />
                            <input name="reason" required placeholder="Reason (required, audited)" className={`${inputClass} py-1 text-xs`} />
                            <select name="policy_id" defaultValue="" className={`${inputClass} py-1 text-xs`}>
                              <option value="">Policy: the booking&apos;s</option>
                              {(policies as any[] | null)?.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                            </select>
                            <ConfirmButton variant="outline" className="px-2 py-1 text-xs" message="Record this override? It is only allowed where the policy permits fixed amounts, and is audited with your reason.">Record override</ConfirmButton>
                          </form>
                        </details>
                      </>
                    )}
                    {["requested", "approved"].includes(r.status) && (
                      <ProcessButton refundId={r.refund_id} action={(id, reason) => rejectRefund(id, reason ?? "")} label="Reject" variant="outline" askReason />
                    )}
                    {r.status === "approved" && (
                      <ProcessButton refundId={r.refund_id} action={executeRefund} label="Execute refund" pendingLabel="Refunding…"
                        confirmText={`Refund ${inr(r.refund_cents)} to the customer through Razorpay? This moves real money.`} />
                    )}
                    {r.status === "submitted_to_provider" && (
                      <ProcessButton refundId={r.refund_id} action={executeRefund} label="Check with Razorpay" pendingLabel="Checking…" variant="outline" />
                    )}
                    {r.status === "failed" && <ProcessButton refundId={r.refund_id} action={retryRefund} label="Approve retry" variant="outline" />}
                  </div>
                </Td>
              </tr>
            );
          })}
        </tbody>
      </Table>
      {!refunds.length && <EmptyState message="No refunds match." />}
    </div>
  );
}
