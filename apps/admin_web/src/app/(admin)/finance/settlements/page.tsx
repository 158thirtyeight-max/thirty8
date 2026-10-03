import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDate, fmtDateTime } from "@/lib/format-date";
import { inr } from "@/lib/money";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { approveSettlement, buildSettlements, exportSettlements } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const STATUSES = ["all", "draft", "approved", "exported", "paid", "failed", "on_hold", "cancelled"];

export default async function SettlementsPage({ searchParams }: { searchParams: Promise<{ status?: string; error?: string; ok?: string }> }) {
  const { status, error, ok } = await searchParams;
  const filter = STATUSES.includes(status ?? "") ? (status as string) : "all";
  const supabase = await createClient();

  let q = supabase
    .from("settlements")
    .select("id, reference, status, period_start, period_end, gross_cents, commission_cents, adjustment_credits_cents, recovery_netted_cents, net_payable_cents, paid_cents, generated_at, approved_at, exported_at, bank_paid_at, txn_reference, operators(name)")
    .order("generated_at", { ascending: false })
    .limit(200);
  if (filter !== "all") q = q.eq("status", filter);
  const [{ data: settlements }, { data: operators }, { data: cfg }] = await Promise.all([
    q,
    supabase.from("operators").select("id, name").eq("status", "approved").order("name"),
    supabase.from("platform_settings").select("key, value").in("key", ["settlement_timezone", "settlement_week_start_dow", "settlement_run_dow", "settlement_run_hour", "settlement_maker_checker"]),
  ]);
  const setting = (k: string) => (cfg as any[] | null)?.find((c) => c.key === k)?.value;
  const days = ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

  return (
    <div>
      <PageTitle title="Weekly settlements" subtitle="Operator payouts, one batch per operator and period. The scheduler only creates drafts; a full admin approves, exports the SBI file and confirms the bank result." />
      <FinanceNav current="/finance/settlements" />
      <Notice error={error} ok={ok} />

      <section className="mb-6 max-w-3xl rounded-lg border border-border bg-surface p-4">
        <SectionHeader title="Build drafts now" />
        <p className="mb-3 text-sm text-text-secondary">
          Schedule: periods start on {days[Number(setting("settlement_week_start_dow") ?? 1)]}, drafts are built on {days[Number(setting("settlement_run_dow") ?? 1)]} at {String(setting("settlement_run_hour") ?? 12).padStart(2, "0")}:00 ({String(setting("settlement_timezone") ?? "Asia/Kolkata")}).
          Maker-checker is {setting("settlement_maker_checker") === false ? "OFF" : "on"}: the admin who approves a batch cannot confirm its payment.
          Includes everything eligible up to the end of the chosen day; building the same period twice never duplicates.
        </p>
        <form action={buildSettlements} className="flex flex-wrap items-end gap-2">
          <label className="text-sm text-text-secondary">Period ends<br /><input type="date" name="period_end" className={inputClass} /></label>
          <label className="text-sm text-text-secondary">Operator<br />
            <select name="operator_id" className={inputClass} defaultValue="">
              <option value="">All operators</option>
              {(operators as any[] | null)?.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
            </select>
          </label>
          <ConfirmButton message="Create draft settlement batches for the chosen period? Drafts can be reviewed, held or cancelled; nothing is paid.">Build drafts</ConfirmButton>
        </form>
      </section>

      <div className="mb-4 flex flex-wrap gap-2">
        {STATUSES.map((s) => (
          <Link key={s} href={s === "all" ? "/finance/settlements" : `/finance/settlements?status=${s}`}
            className={`rounded-pill px-3 py-1 text-sm ${filter === s ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}>
            {s.replace(/_/g, " ")}
          </Link>
        ))}
      </div>

      <form action={exportSettlements}>
        <input type="hidden" name="return" value="/finance/settlements" />
        <Table>
          <thead>
            <tr><Th></Th><Th>Batch</Th><Th>Operator</Th><Th>Period</Th><Th>Amounts</Th><Th>Status</Th><Th>Dates</Th><Th></Th></tr>
          </thead>
          <tbody>
            {(settlements as any[] | null)?.map((s) => (
              <tr key={s.id}>
                <Td>{s.status === "approved" && s.net_payable_cents > 0 && <input type="checkbox" name="ids" value={s.id} aria-label={`Export ${s.reference}`} />}</Td>
                <Td className="font-mono"><Link className="text-primary hover:underline" href={`/finance/settlements/${s.id}`}>{s.reference}</Link></Td>
                <Td>{s.operators?.name}</Td>
                <Td>{fmtDate(s.period_start)} – {fmtDate(s.period_end)}</Td>
                <Td>
                  <div className="font-medium">{inr(s.net_payable_cents)} <span className="font-normal text-text-tertiary">payable</span></div>
                  <div className="text-xs text-text-tertiary">gross {inr(s.gross_cents)} · commission {inr(s.commission_cents)}
                    {s.adjustment_credits_cents ? ` · credits ${inr(s.adjustment_credits_cents)}` : ""}{s.recovery_netted_cents ? ` · recovery netted ${inr(s.recovery_netted_cents)}` : ""}</div>
                </Td>
                <Td><Badge status={s.status} />{s.txn_reference && <div className="mt-1 font-mono text-xs text-text-tertiary">UTR {s.txn_reference}</div>}</Td>
                <Td className="text-xs text-text-secondary">
                  <div>generated {fmtDateTime(s.generated_at)}</div>
                  <div>approved {s.approved_at ? fmtDateTime(s.approved_at) : "—"}</div>
                  <div>exported {s.exported_at ? fmtDateTime(s.exported_at) : "—"}</div>
                  <div>bank paid {s.bank_paid_at ? fmtDateTime(s.bank_paid_at) : "—"}</div>
                </Td>
                <Td>
                  {s.status === "draft" && (
                    <ConfirmButton formAction={approveSettlement} name="id" value={s.id} variant="outline" className="px-2 py-1 text-xs"
                      message={`Approve ${s.reference} for ${inr(s.net_payable_cents)}? The operator's bank details are frozen at approval.`}>
                      Approve
                    </ConfirmButton>
                  )}
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!settlements?.length && <EmptyState message="No settlement batches yet." />}
        <div className="mt-4">
          <ConfirmButton message="Create the immutable SBI payment file for the ticked batches? They become 'exported' and can no longer be cancelled here.">
            Export selected to SBI file
          </ConfirmButton>
          <p className="mt-2 max-w-2xl text-xs text-text-tertiary">
            You upload the file to SBI Corporate Internet Banking yourself. The column layout is a configurable template and must be checked against SBI&apos;s bulk-upload format before live use.
          </p>
        </div>
      </form>
    </div>
  );
}
