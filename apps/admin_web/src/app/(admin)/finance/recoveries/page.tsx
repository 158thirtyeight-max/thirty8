import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { inr } from "@/lib/money";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { updateRecovery } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function RecoveriesPage({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const [{ data: recoveries }, { data: adjustments }] = await Promise.all([
    supabase.from("operator_recovery").select("id, amount_cents, recovered_cents, status, reason, created_at, operators(name)").order("created_at", { ascending: false }).limit(200),
    supabase.from("operator_adjustments").select("id, kind, amount_cents, status, created_at, operators(name), settlements(reference)").order("created_at", { ascending: false }).limit(100),
  ]);

  return (
    <div>
      <PageTitle title="Operator recoveries & adjustments" subtitle="Money an operator owes after a refund on an already-paid ticket is netted from their next payouts (up to the configured cap). You can also record a direct repayment or write a debt off. Operators can only view this." />
      <FinanceNav current="/finance/recoveries" />
      <Notice error={error} ok={ok} />

      <SectionHeader title="Recoveries" />
      <div className="mb-8">
        <Table>
          <thead><tr><Th>Operator</Th><Th>Owed</Th><Th>Recovered</Th><Th>Outstanding</Th><Th>Status</Th><Th>Reason</Th><Th>Actions (full admin)</Th></tr></thead>
          <tbody>
            {(recoveries as any[] | null)?.map((r) => (
              <tr key={r.id}>
                <Td>{r.operators?.name}<div className="text-xs text-text-tertiary">{fmtDateTime(r.created_at)}</div></Td>
                <Td>{inr(r.amount_cents)}</Td>
                <Td>{inr(r.recovered_cents)}</Td>
                <Td className="font-medium">{inr(r.amount_cents - r.recovered_cents)}</Td>
                <Td><Badge status={r.status} /></Td>
                <Td className="max-w-xs text-xs">{r.reason}</Td>
                <Td>
                  {["open", "partially_recovered"].includes(r.status) && (
                    <div className="flex flex-col gap-2">
                      <form action={updateRecovery} className="flex flex-wrap gap-1">
                        <input type="hidden" name="id" value={r.id} /><input type="hidden" name="action" value="record_recovery" />
                        <input name="amount" required inputMode="decimal" placeholder="₹ received" className={`${inputClass} w-24 py-1 text-xs`} />
                        <input name="reason" required placeholder="Reference / reason" className={`${inputClass} w-36 py-1 text-xs`} />
                        <ConfirmButton variant="outline" className="px-2 py-1 text-xs" message="Record this repayment from the operator?">Record</ConfirmButton>
                      </form>
                      <form action={updateRecovery} className="flex gap-1">
                        <input type="hidden" name="id" value={r.id} /><input type="hidden" name="action" value="write_off" />
                        <input name="reason" required placeholder="Write-off reason" className={`${inputClass} w-36 py-1 text-xs`} />
                        <ConfirmButton variant="destructive" className="px-2 py-1 text-xs" message="Write off the outstanding amount? This is booked as a loss and cannot be undone.">Write off</ConfirmButton>
                      </form>
                    </div>
                  )}
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!recoveries?.length && <EmptyState message="No operator owes thirty8 anything." />}
      </div>

      <SectionHeader title="Operator adjustments (cancellation share owed to operators)" />
      <Table>
        <thead><tr><Th>Operator</Th><Th>Type</Th><Th>Amount</Th><Th>Status</Th><Th>Batch</Th><Th>Created</Th></tr></thead>
        <tbody>
          {(adjustments as any[] | null)?.map((a) => (
            <tr key={a.id}>
              <Td>{a.operators?.name}</Td>
              <Td className="capitalize">{String(a.kind).replace(/_/g, " ")}</Td>
              <Td>{inr(a.amount_cents)}</Td>
              <Td><Badge status={a.status === "settled" ? "verified" : a.status === "in_batch" ? "processing" : "pending"} /> <span className="text-xs text-text-tertiary">{a.status.replace(/_/g, " ")}</span></Td>
              <Td className="font-mono text-xs">{a.settlements?.reference ?? "—"}</Td>
              <Td>{fmtDateTime(a.created_at)}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!adjustments?.length && <EmptyState message="No adjustments." />}
    </div>
  );
}
