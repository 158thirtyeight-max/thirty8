import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { PageTitle, SectionHeader, StatCard } from "@/components/ui";
import { inr } from "@/lib/money";
import { FinanceNav, Notice } from "./notice";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function FinanceDashboard({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const { data, error: rpcError } = await supabase.rpc("admin_finance_dashboard");
  const d: any = data ?? {};

  const todo: [string, number, string][] = [
    ["Refund requests awaiting approval", d.refunds_pending_approval ?? 0, "/refunds"],
    ["Settlement batches awaiting approval", d.batches_awaiting_approval ?? 0, "/finance/settlements?status=draft"],
    ["Approved batches awaiting export", d.batches_awaiting_export ?? 0, "/finance/settlements?status=approved"],
    ["Exported batches awaiting the bank result", d.batches_awaiting_bank_result ?? 0, "/finance/settlements?status=exported"],
    ["Failed settlement batches", d.failed_batches ?? 0, "/finance/settlements?status=failed"],
    ["Failed refunds", d.failed_refunds ?? 0, "/refunds"],
    ["Open reconciliation exceptions", d.open_exceptions ?? 0, "/finance/reconciliation"],
  ];

  return (
    <div>
      <PageTitle title="Finance & Settlements" subtitle="Collections, operator earnings, weekly settlements and refunds. Figures are calculated in the database." />
      <FinanceNav current="/finance" />
      <Notice error={error ?? rpcError?.message} ok={ok} />

      <SectionHeader title="Money in" />
      <div className="mb-8 grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Total collected (payments)" value={inr(d.collected_cents)} />
        <StatCard label="Gross ticket revenue (earned)" value={inr(d.gross_revenue_cents)} />
        <StatCard label="Platform commission" value={inr(d.commission_cents)} />
        <StatCard label="Cancellation income" value={inr(d.cancellation_income_cents)} />
      </div>

      <SectionHeader title="Operators" />
      <div className="mb-8 grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Operator net earnings" value={inr(d.operator_net_cents)} />
        <StatCard label="Operator payable (ledger)" value={inr(d.operator_payable_cents)} />
        <StatCard label="Pending boarding" value={inr(d.pending_boarding_cents)} />
        <StatCard label="Eligible (not yet in a batch)" value={inr(d.eligible_cents)} />
        <StatCard label="On hold" value={inr(d.on_hold_cents)} />
        <StatCard label="In settlement (not yet paid)" value={inr(d.pending_settlement_cents)} />
        <StatCard label="Settled (paid by bank)" value={inr(d.settled_cents)} />
        <StatCard label="Outstanding operator recovery" value={inr(d.outstanding_recovery_cents)} />
      </div>

      <SectionHeader title="Refunds" />
      <div className="mb-8 grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Refunded to customers" value={inr(d.refunded_cents)} />
        <StatCard label="Awaiting your approval" value={d.refunds_pending_approval ?? 0} />
        <StatCard label="Failed refunds" value={d.failed_refunds ?? 0} />
      </div>

      <SectionHeader title="Needs attention" />
      <ul className="max-w-xl divide-y divide-divider rounded-lg border border-border bg-surface">
        {todo.map(([label, n, href]) => (
          <li key={label}>
            <Link href={href} className="flex items-center justify-between px-4 py-3 text-sm hover:bg-primary/5">
              <span className="text-text-secondary">{label}</span>
              <span className={`rounded-pill px-2.5 py-0.5 text-xs font-medium ${n > 0 ? "bg-warning/15 text-warning" : "bg-success/15 text-success"}`}>{n}</span>
            </Link>
          </li>
        ))}
      </ul>
      {(d.critical_exceptions ?? 0) > 0 && (
        <p className="mt-4 text-sm text-error">{d.critical_exceptions} critical reconciliation exception(s) are open.</p>
      )}
    </div>
  );
}
