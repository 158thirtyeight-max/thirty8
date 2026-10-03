import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDate, fmtDateTime } from "@/lib/format-date";
import { bpsToPct } from "@/lib/money";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { ConfirmButton } from "@/components/confirm-button";
import { FinanceNav, Notice } from "../notice";
import { inputClass } from "../_util";
import { savePolicy, setPolicyStatus } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function RefundPoliciesPage({ searchParams }: { searchParams: Promise<{ edit?: string; error?: string; ok?: string }> }) {
  const { edit, error, ok } = await searchParams;
  const supabase = await createClient();
  const { data: policies } = await supabase
    .from("refund_policies")
    .select("id, name, category, status, refund_bps, deduction_bps, deduction_operator_share_bps, min_hours_before_departure, max_hours_before_departure, effective_from, effective_until, description, allow_fixed_override, version, updated_at")
    .order("category")
    .order("min_hours_before_departure", { nullsFirst: true });
  const list = (policies as any[] | null) ?? [];
  const editing = edit ? list.find((p) => p.id === edit) : undefined;
  const today = new Date().toISOString().slice(0, 10);
  const window = (p: any) =>
    p.min_hours_before_departure === null && p.max_hours_before_departure === null ? "any time"
      : `${p.min_hours_before_departure ?? 0}h – ${p.max_hours_before_departure ?? "∞"}h before departure`;

  return (
    <div>
      <PageTitle title="Cancellation & refund policies" subtitle="The refund percentage for each cancellation situation. Changing a policy never alters bookings already made: each booking keeps the policy it was booked under." />
      <FinanceNav current="/finance/refund-policies" />
      <Notice error={error} ok={ok} />

      <section className="mb-8 max-w-4xl rounded-lg border border-border bg-surface p-4">
        <SectionHeader title={editing ? `Edit “${editing.name}” (creates version ${editing.version + 1})` : "New policy"} />
        <p className="mb-3 text-sm text-text-secondary">
          Pick a <b>category</b> (for example <code>passenger_cancellation</code>, <code>operator_cancelled</code>, <code>system_failure</code>, <code>admin_discretion</code>) and optionally a window of hours before departure.
          The category <code>default</code> is used when nothing more specific applies. There are no built-in percentages: the examples are yours to define. Only full administrators can change policies.
        </p>
        <form key={editing?.id ?? "new"} action={savePolicy} className="grid gap-3 md:grid-cols-3">
          {editing && <input type="hidden" name="id" value={editing.id} />}
          <label className="text-sm text-text-secondary">Policy name<br /><input name="name" required defaultValue={editing?.name} className={`${inputClass} w-full`} /></label>
          <label className="text-sm text-text-secondary">Category<br /><input name="category" required defaultValue={editing?.category ?? "passenger_cancellation"} pattern="[a-z][a-z0-9_]{1,40}" className={`${inputClass} w-full`} /></label>
          <label className="text-sm text-text-secondary">Status<br />
            <select name="status" defaultValue={editing?.status ?? "active"} className={`${inputClass} w-full`}><option value="active">Active</option><option value="inactive">Inactive</option></select>
          </label>
          <label className="text-sm text-text-secondary">Refund %<br /><input name="refund_pct" required inputMode="decimal" defaultValue={editing ? editing.refund_bps / 100 : ""} placeholder="0 – 100" className={`${inputClass} w-full`} /></label>
          <label className="text-sm text-text-secondary">Share of the deduction paid to the operator %<br /><input name="operator_share_pct" required inputMode="decimal" defaultValue={editing ? editing.deduction_operator_share_bps / 100 : ""} placeholder="0 – 100" className={`${inputClass} w-full`} /></label>
          <label className="flex items-end gap-2 pb-2 text-sm text-text-secondary"><input type="checkbox" name="allow_fixed_override" defaultChecked={editing?.allow_fixed_override} /> Allow a fixed-amount override by an admin</label>
          <label className="text-sm text-text-secondary">From (hours before departure)<br /><input name="min_hours" inputMode="decimal" defaultValue={editing?.min_hours_before_departure ?? ""} placeholder="blank = no minimum" className={`${inputClass} w-full`} /></label>
          <label className="text-sm text-text-secondary">Up to (hours before departure)<br /><input name="max_hours" inputMode="decimal" defaultValue={editing?.max_hours_before_departure ?? ""} placeholder="blank = no maximum" className={`${inputClass} w-full`} /></label>
          <span />
          <label className="text-sm text-text-secondary">Effective from<br /><input type="date" name="effective_from" defaultValue={editing?.effective_from ?? today} className={`${inputClass} w-full`} /></label>
          <label className="text-sm text-text-secondary">Effective until (optional)<br /><input type="date" name="effective_until" defaultValue={editing?.effective_until ?? ""} className={`${inputClass} w-full`} /></label>
          <span />
          <label className="text-sm text-text-secondary md:col-span-3">Description<br /><input name="description" defaultValue={editing?.description ?? ""} className={`${inputClass} w-full`} /></label>
          <div className="flex gap-2 md:col-span-3">
            <ConfirmButton message="Save this policy? It applies to bookings made from now on; existing bookings keep their own policy.">{editing ? "Save as new version" : "Create policy"}</ConfirmButton>
            {editing && <Link href="/finance/refund-policies" className="rounded-md border border-border px-4 py-2 text-sm text-text-secondary">Cancel edit</Link>}
          </div>
        </form>
      </section>

      <Table>
        <thead><tr><Th>Policy</Th><Th>Category &amp; window</Th><Th>Refund</Th><Th>Deduction</Th><Th>Effective</Th><Th>Status</Th><Th></Th></tr></thead>
        <tbody>
          {list.map((p) => (
            <tr key={p.id}>
              <Td>{p.name}<div className="text-xs text-text-tertiary">v{p.version} · updated {fmtDateTime(p.updated_at)}</div>{p.description && <div className="max-w-xs text-xs text-text-secondary">{p.description}</div>}</Td>
              <Td><span className="font-mono text-xs">{p.category}</span><div className="text-xs text-text-tertiary">{window(p)}</div></Td>
              <Td>{bpsToPct(p.refund_bps)}</Td>
              <Td>{bpsToPct(p.deduction_bps)}<div className="text-xs text-text-tertiary">operator gets {bpsToPct(p.deduction_operator_share_bps)} of it{p.allow_fixed_override ? " · override allowed" : ""}</div></Td>
              <Td>{fmtDate(p.effective_from)}{p.effective_until ? ` – ${fmtDate(p.effective_until)}` : " onwards"}</Td>
              <Td><Badge status={p.status} /></Td>
              <Td>
                <div className="flex flex-col gap-1 text-xs">
                  <Link href={`/finance/refund-policies?edit=${p.id}`} className="text-primary hover:underline">Edit</Link>
                  <Link href={`/finance/refund-policies/${p.id}`} className="text-primary hover:underline">History &amp; usage</Link>
                  <form action={setPolicyStatus}>
                    <input type="hidden" name="id" value={p.id} />
                    <input type="hidden" name="status" value={p.status === "active" ? "inactive" : "active"} />
                    <ConfirmButton variant="outline" className="px-2 py-1 text-xs" message={p.status === "active" ? "Deactivate this policy? New bookings stop receiving it." : "Activate this policy?"}>
                      {p.status === "active" ? "Deactivate" : "Activate"}
                    </ConfirmButton>
                  </form>
                </div>
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!list.length && <EmptyState message="No refund policy exists yet. Until you create one, refund requests cannot be approved without choosing an override." />}
    </div>
  );
}
