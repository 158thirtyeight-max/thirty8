import { createClient } from "@/lib/supabase/server";
import { fmtDate } from "@/lib/format-date";
import { bpsToPct } from "@/lib/money";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { deactivateCommission, setCommission } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function CommissionPage({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const [{ data: rates }, { data: operators }] = await Promise.all([
    supabase.from("operator_commission_config").select("id, operator_id, rate_bps, effective_from, effective_to, is_active, created_at, operators(name)").order("created_at", { ascending: false }).limit(100),
    supabase.from("operators").select("id, name").order("name"),
  ]);
  const today = new Date().toISOString().slice(0, 10);

  return (
    <div>
      <PageTitle title="Commission settings" subtitle="thirty8's percentage on each ticket. There is no built-in rate: until one is set, boarded tickets are held and cannot be settled." />
      <FinanceNav current="/finance/commission" />
      <Notice error={error} ok={ok} />

      <section className="mb-8 max-w-3xl rounded-lg border border-border bg-surface p-4">
        <SectionHeader title="Set a rate" />
        <p className="mb-3 text-sm text-text-secondary">
          A new rate closes the previous open-ended one the day before it starts. It applies to tickets confirmed from then on; each ticket keeps the rate it was created with, so history never changes.
          Leave the operator empty for the platform default. Only full administrators can change commission.
        </p>
        <form action={setCommission} className="flex flex-wrap items-end gap-3">
          <label className="text-sm text-text-secondary">Operator<br />
            <select name="operator_id" className={inputClass} defaultValue="">
              <option value="">All operators (platform default)</option>
              {(operators as any[] | null)?.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select>
          </label>
          <label className="text-sm text-text-secondary">Commission %<br /><input name="percent" required inputMode="decimal" placeholder="e.g. 10 or 7.5" className={`${inputClass} w-32`} /></label>
          <label className="text-sm text-text-secondary">Effective from<br /><input type="date" name="effective_from" defaultValue={today} className={inputClass} /></label>
          <ConfirmButton message="Save this commission rate? It applies to new tickets from the effective date.">Save rate</ConfirmButton>
        </form>
      </section>

      <SectionHeader title="History" />
      <Table>
        <thead><tr><Th>Applies to</Th><Th>Rate</Th><Th>From</Th><Th>Until</Th><Th>Status</Th><Th></Th></tr></thead>
        <tbody>
          {(rates as any[] | null)?.map((r) => (
            <tr key={r.id}>
              <Td>{r.operators?.name ?? "Platform default"}</Td>
              <Td>{bpsToPct(r.rate_bps)}</Td>
              <Td>{fmtDate(r.effective_from)}</Td>
              <Td>{r.effective_to ? fmtDate(r.effective_to) : "open"}</Td>
              <Td><Badge status={r.is_active ? "active" : "cancelled"} /></Td>
              <Td>
                {r.is_active && (
                  <form action={deactivateCommission}>
                    <input type="hidden" name="id" value={r.id} />
                    <ConfirmButton variant="outline" className="px-2 py-1 text-xs" message="Deactivate this commission setting? Tickets without a rate are held until another rate applies.">Deactivate</ConfirmButton>
                  </form>
                )}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!rates?.length && <EmptyState message="No commission has been configured. Boarded tickets are held until you set one." />}
    </div>
  );
}
