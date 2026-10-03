import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { fmtDate, fmtDateTime } from "@/lib/format-date";
import { inr } from "@/lib/money";
import { Badge, EmptyState, PageTitle, SectionHeader, StatCard, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../../notice";
import { inputClass } from "../../_util";
import { approveSettlement, cancelSettlement, holdSettlement, releaseSettlementHold, settleZeroBatch } from "../actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const KIND: Record<string, string> = { sale: "Ticket earning", refund_adjustment: "Refund adjustment", operator_adjustment: "Cancellation share (credit)", recovery_netting: "Recovery netted (deduction)" };

export default async function SettlementDetail({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ error?: string; ok?: string }> }) {
  const { id } = await params;
  const { error, ok } = await searchParams;
  const supabase = await createClient();
  const { data: s } = await supabase
    .from("settlements")
    .select("*, operators(name)")
    .eq("id", id)
    .maybeSingle();
  if (!s) notFound();
  const b: any = s;

  const [{ data: items }, { data: payments }, { data: audit }, { data: beneficiary }, { data: exportRow }] = await Promise.all([
    supabase.from("settlement_items").select("id, kind, fare_cents, commission_cents, net_cents, booking_items(bookings(booking_reference))").eq("settlement_id", id).order("kind"),
    supabase.from("settlement_payments").select("id, provider, status, amount_cents, utr, bank_paid_on, failure_reason, confirmed_at").eq("settlement_id", id).order("confirmed_at"),
    supabase.from("audit_logs").select("id, action, created_at, after, profiles:actor_profile_id(full_name, email)").eq("entity_type", "settlement").eq("entity_id", id).order("created_at", { ascending: false }).limit(50),
    supabase.rpc("admin_get_settlement_beneficiary", { p_settlement_id: id }),
    b.export_id ? supabase.from("settlement_export_rows").select("export_id, line_no").eq("settlement_id", id).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  const ben: any = beneficiary;
  const here = `/finance/settlements/${id}`;

  return (
    <div>
      <PageTitle title={`Settlement ${b.reference}`} subtitle={`${b.operators?.name ?? ""} · ${fmtDate(b.period_start)} – ${fmtDate(b.period_end)}`} />
      <FinanceNav current="/finance/settlements" />
      <Notice error={error} ok={ok} />
      <p className="mb-4"><Link href="/finance/settlements" className="text-sm text-primary hover:underline">← All settlements</Link></p>

      <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard label="Gross ticket earnings" value={inr(b.gross_cents)} />
        <StatCard label="Commission deducted" value={inr(b.commission_cents)} />
        <StatCard label="Cancellation share credited" value={inr(b.adjustment_credits_cents)} />
        <StatCard label="Recovery netted" value={inr(b.recovery_netted_cents)} />
        <StatCard label="Net payable" value={inr(b.net_payable_cents)} />
        <StatCard label="Paid by the bank" value={inr(b.paid_cents)} />
      </div>

      <div className="mb-8 grid gap-6 lg:grid-cols-2">
        <section className="rounded-lg border border-border bg-surface p-4 text-sm">
          <SectionHeader title="Status and dates" />
          <p className="mb-3"><Badge status={b.status} /> {b.hold_reason && <span className="ml-2 text-text-secondary">hold: {b.hold_reason}</span>}</p>
          <dl className="grid grid-cols-[10rem_1fr] gap-y-1">
            <dt className="text-text-tertiary">Period</dt><dd>{fmtDate(b.period_start)} – {fmtDate(b.period_end)}</dd>
            <dt className="text-text-tertiary">Generated</dt><dd>{fmtDateTime(b.generated_at)}</dd>
            <dt className="text-text-tertiary">Approved</dt><dd>{b.approved_at ? fmtDateTime(b.approved_at) : "—"}</dd>
            <dt className="text-text-tertiary">Exported</dt><dd>{b.exported_at ? fmtDateTime(b.exported_at) : "—"}</dd>
            <dt className="text-text-tertiary">Bank paid</dt><dd>{b.bank_paid_at ? fmtDateTime(b.bank_paid_at) : "—"}</dd>
            <dt className="text-text-tertiary">UTR</dt><dd className="font-mono">{b.txn_reference ?? "—"}</dd>
            {b.failure_reason && (<><dt className="text-text-tertiary">Failure</dt><dd className="text-error">{b.failure_reason}</dd></>)}
            {b.cancel_reason && (<><dt className="text-text-tertiary">Cancelled</dt><dd>{b.cancel_reason}</dd></>)}
          </dl>
          {exportRow && (
            <p className="mt-3"><a className="text-primary hover:underline" href={`/finance/settlements/export/${(exportRow as any).export_id}`}>Download the SBI file (audited)</a></p>
          )}
        </section>

        <section className="rounded-lg border border-border bg-surface p-4 text-sm">
          <SectionHeader title="Beneficiary (frozen at approval)" />
          {ben ? (
            <dl className="grid grid-cols-[10rem_1fr] gap-y-1">
              <dt className="text-text-tertiary">Account holder</dt><dd>{ben.account_holder_name}</dd>
              <dt className="text-text-tertiary">Bank</dt><dd>{ben.bank_name ?? "—"}{ben.branch_name ? `, ${ben.branch_name}` : ""}</dd>
              <dt className="text-text-tertiary">Account</dt><dd className="font-mono">{ben.account_masked}</dd>
              <dt className="text-text-tertiary">IFSC</dt><dd className="font-mono">{ben.ifsc}</dd>
              <dt className="text-text-tertiary">Frozen</dt><dd>{fmtDateTime(ben.frozen_at)}</dd>
            </dl>
          ) : (
            <p className="text-text-secondary">Not frozen yet. Approval freezes the operator&apos;s verified bank details for this batch; later bank changes never redirect an approved batch.</p>
          )}
        </section>
      </div>

      <section className="mb-8 rounded-lg border border-border bg-surface p-4">
        <SectionHeader title="Actions" />
        <div className="flex flex-wrap items-end gap-4">
          {b.status === "draft" && (
            <form action={approveSettlement}>
              <input type="hidden" name="id" value={id} /><input type="hidden" name="return" value={here} />
              <ConfirmButton message={`Approve ${b.reference} for ${inr(b.net_payable_cents)}? The bank details are frozen at approval.`}>Approve</ConfirmButton>
            </form>
          )}
          {["draft", "approved"].includes(b.status) && (
            <form action={holdSettlement} className="flex items-end gap-2">
              <input type="hidden" name="id" value={id} /><input type="hidden" name="return" value={here} />
              <input name="reason" required placeholder="Hold reason" className={inputClass} />
              <ConfirmButton variant="outline" message="Put this batch on hold?">Hold</ConfirmButton>
            </form>
          )}
          {b.status === "on_hold" && (
            <form action={releaseSettlementHold}>
              <input type="hidden" name="id" value={id} /><input type="hidden" name="return" value={here} />
              <ConfirmButton variant="outline" message="Release the hold? The batch returns to draft and must be approved again.">Release hold</ConfirmButton>
            </form>
          )}
          {["draft", "approved", "on_hold", "failed"].includes(b.status) && (
            <form action={cancelSettlement} className="flex items-end gap-2">
              <input type="hidden" name="id" value={id} /><input type="hidden" name="return" value={here} />
              <input name="reason" required placeholder={b.status === "failed" ? "Release reason" : "Cancel reason"} className={inputClass} />
              <ConfirmButton variant="destructive" message="Cancel this batch? Its earnings, credits and recovery reservations return to the pool.">{b.status === "failed" ? "Release failed batch" : "Cancel batch"}</ConfirmButton>
            </form>
          )}
          {b.status === "approved" && b.net_payable_cents === 0 && (
            <form action={settleZeroBatch} className="flex items-end gap-2">
              <input type="hidden" name="id" value={id} /><input type="hidden" name="return" value={here} />
              <input name="reason" required placeholder="Reason" className={inputClass} />
              <ConfirmButton message="Record this zero-payment batch as settled? Only the recovery netting is booked; no bank transfer is needed.">Settle (netting only)</ConfirmButton>
            </form>
          )}
        </div>
      </section>

      <SectionHeader title={`Batch contents (${items?.length ?? 0})`} />
      <div className="mb-8">
        <Table>
          <thead><tr><Th>Type</Th><Th>Ticket</Th><Th>Gross</Th><Th>Commission</Th><Th>Amount to operator</Th></tr></thead>
          <tbody>
            {(items as any[] | null)?.map((i) => (
              <tr key={i.id}>
                <Td>{KIND[i.kind] ?? i.kind}</Td>
                <Td className="font-mono">{i.booking_items?.bookings?.booking_reference ?? "—"}</Td>
                <Td>{i.fare_cents ? inr(i.fare_cents) : "—"}</Td>
                <Td>{i.commission_cents ? inr(i.commission_cents) : "—"}</Td>
                <Td className={i.net_cents < 0 ? "text-error" : ""}>{inr(i.net_cents)}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!items?.length && <EmptyState message="This batch has no items (cancelled batches release their items)." />}
      </div>

      <SectionHeader title="Bank payments" />
      <div className="mb-8">
        <Table>
          <thead><tr><Th>Result</Th><Th>Amount</Th><Th>UTR</Th><Th>Bank date</Th><Th>Confirmed</Th></tr></thead>
          <tbody>
            {(payments as any[] | null)?.map((p) => (
              <tr key={p.id}>
                <Td><Badge status={p.status} />{p.failure_reason && <div className="mt-1 text-xs text-error">{p.failure_reason}</div>}</Td>
                <Td>{inr(p.amount_cents)}</Td>
                <Td className="font-mono">{p.utr ?? "—"}</Td>
                <Td>{p.bank_paid_on ? fmtDate(p.bank_paid_on) : "—"}</Td>
                <Td>{fmtDateTime(p.confirmed_at)}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!payments?.length && <EmptyState message="No bank result has been recorded for this batch." />}
      </div>

      <SectionHeader title="Audit trail" />
      <Table>
        <thead><tr><Th>When</Th><Th>Who</Th><Th>Action</Th><Th>Details</Th></tr></thead>
        <tbody>
          {(audit as any[] | null)?.map((a) => (
            <tr key={a.id}>
              <Td>{fmtDateTime(a.created_at)}</Td>
              <Td>{a.profiles?.full_name ?? a.profiles?.email ?? "system"}</Td>
              <Td className="font-mono text-xs">{a.action}</Td>
              <Td className="max-w-md truncate font-mono text-xs text-text-tertiary">{a.after ? JSON.stringify(a.after) : ""}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
    </div>
  );
}
