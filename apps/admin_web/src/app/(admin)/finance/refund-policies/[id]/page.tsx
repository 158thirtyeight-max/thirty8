import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { bpsToPct, inr } from "@/lib/money";
import { Badge, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { FinanceNav } from "../../notice";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function PolicyHistory({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: policy } = await supabase.from("refund_policies").select("id, name, category, version").eq("id", id).maybeSingle();
  if (!policy) notFound();
  const [{ data: versions }, { data: used }] = await Promise.all([
    supabase.from("refund_policy_versions").select("version, snapshot, changed_at, profiles:changed_by(full_name, email)").eq("policy_id", id).order("version", { ascending: false }),
    supabase.from("refunds").select("id, status, amount_cents, calc_deduction_cents, policy_version, created_at, calc_source, payments(razorpay_payment_id, orders(order_reference))").eq("policy_id", id).order("created_at", { ascending: false }).limit(100),
  ]);
  const p: any = policy;

  return (
    <div>
      <PageTitle title={`Policy history: ${p.name}`} subtitle={`${p.category} · current version ${p.version}. Every version is kept and cannot be edited.`} />
      <FinanceNav current="/finance/refund-policies" />
      <p className="mb-4"><Link href="/finance/refund-policies" className="text-sm text-primary hover:underline">← Policies</Link></p>

      <SectionHeader title="Versions" />
      <div className="mb-8">
        <Table>
          <thead><tr><Th>Version</Th><Th>Refund</Th><Th>Operator share of deduction</Th><Th>Window (hours)</Th><Th>Status</Th><Th>Changed</Th><Th>By</Th></tr></thead>
          <tbody>
            {(versions as any[] | null)?.map((v) => (
              <tr key={v.version}>
                <Td>v{v.version}</Td>
                <Td>{bpsToPct(v.snapshot.refund_bps)}</Td>
                <Td>{bpsToPct(v.snapshot.deduction_operator_share_bps)}</Td>
                <Td>{v.snapshot.min_hours_before_departure ?? "—"} to {v.snapshot.max_hours_before_departure ?? "—"}</Td>
                <Td><Badge status={v.snapshot.status} /></Td>
                <Td>{fmtDateTime(v.changed_at)}</Td>
                <Td>{v.profiles?.full_name ?? v.profiles?.email ?? "system"}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </div>

      <SectionHeader title="Refunds processed under this policy" />
      <Table>
        <thead><tr><Th>Order</Th><Th>Refund</Th><Th>Deduction</Th><Th>Version used</Th><Th>How chosen</Th><Th>Status</Th><Th>When</Th></tr></thead>
        <tbody>
          {(used as any[] | null)?.map((r) => (
            <tr key={r.id}>
              <Td className="font-mono">{r.payments?.orders?.order_reference ?? "—"}<div className="font-sans text-xs text-text-tertiary">{r.payments?.razorpay_payment_id}</div></Td>
              <Td>{inr(r.amount_cents)}</Td>
              <Td>{inr(r.calc_deduction_cents)}</Td>
              <Td>v{r.policy_version}</Td>
              <Td className="text-xs capitalize">{String(r.calc_source).replace(/_/g, " ")}</Td>
              <Td><Badge status={r.status} /></Td>
              <Td>{fmtDateTime(r.created_at)}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!used?.length && <EmptyState message="No refund has been calculated under this policy yet." />}
    </div>
  );
}
