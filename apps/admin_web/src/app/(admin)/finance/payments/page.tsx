import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fmtDateTime } from "@/lib/format-date";
import { inr } from "@/lib/money";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";
import { FinanceNav, Notice } from "../notice";

/* eslint-disable @typescript-eslint/no-explicit-any */

const STATUSES = ["all", "captured", "failed", "refunded", "duplicate_captured", "pending"];

export default async function PaymentsPage({ searchParams }: { searchParams: Promise<{ status?: string; error?: string }> }) {
  const { status, error } = await searchParams;
  const filter = STATUSES.includes(status ?? "") ? (status as string) : "all";
  const supabase = await createClient();
  let q = supabase
    .from("payments")
    .select("id, razorpay_payment_id, status, amount_cents, currency_code, refunded_cents, method, captured_at, failure_reason, created_at, orders(order_reference, orderable_type, razorpay_order_id, profiles(full_name, email))")
    .order("created_at", { ascending: false })
    .limit(200);
  if (filter !== "all") q = q.eq("status", filter);
  const { data: payments } = await q;

  return (
    <div>
      <PageTitle title="Payment transactions" subtitle="Razorpay payments as recorded by the backend. A payment is trusted only after Razorpay confirms it." />
      <FinanceNav current="/finance/payments" />
      <Notice error={error} />
      <div className="mb-4 flex flex-wrap items-center gap-2">
        {STATUSES.map((s) => (
          <Link
            key={s}
            href={s === "all" ? "/finance/payments" : `/finance/payments?status=${s}`}
            className={`rounded-pill px-3 py-1 text-sm ${filter === s ? "bg-primary text-white" : "border border-border text-text-secondary hover:border-primary hover:text-primary"}`}
          >
            {s.replace(/_/g, " ")}
          </Link>
        ))}
        <a href={`/finance/payments/export${filter === "all" ? "" : `?status=${filter}`}`} className="ml-auto text-sm text-primary hover:underline">Export CSV</a>
      </div>
      <Table>
        <thead>
          <tr><Th>Order</Th><Th>Customer</Th><Th>Amount</Th><Th>Refunded</Th><Th>Status</Th><Th>Method</Th><Th>Razorpay IDs</Th><Th>Captured</Th></tr>
        </thead>
        <tbody>
          {(payments as any[] | null)?.map((p) => (
            <tr key={p.id}>
              <Td className="font-mono">{p.orders?.order_reference}<div className="font-sans text-text-tertiary capitalize">{p.orders?.orderable_type?.replace(/_/g, " ")}</div></Td>
              <Td>{p.orders?.profiles?.full_name ?? p.orders?.profiles?.email ?? "—"}</Td>
              <Td>{inr(p.amount_cents)}</Td>
              <Td>{p.refunded_cents ? inr(p.refunded_cents) : "—"}</Td>
              <Td><Badge status={p.status} />{p.failure_reason && <div className="mt-1 max-w-xs text-xs text-error">{p.failure_reason}</div>}</Td>
              <Td className="capitalize">{p.method ?? "—"}</Td>
              <Td className="font-mono text-xs">{p.razorpay_payment_id ?? "—"}<div className="text-text-tertiary">{p.orders?.razorpay_order_id ?? ""}</div></Td>
              <Td>{p.captured_at ? fmtDateTime(p.captured_at) : "—"}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!payments?.length && <EmptyState message="No payments match." />}
    </div>
  );
}
