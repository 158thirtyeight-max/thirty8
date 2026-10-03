import type { NextRequest } from "next/server";
import { requirePlatformAdmin } from "@/lib/auth";
import { toCsv } from "@/lib/csv";
import { fetchAll } from "@/lib/fetch-all";

/* eslint-disable @typescript-eslint/no-explicit-any */

export async function GET(req: NextRequest) {
  const { supabase } = await requirePlatformAdmin();
  const status = req.nextUrl.searchParams.get("status");
  const rows = await fetchAll<any>((from, to) => {
    let q = supabase
      .from("payments")
      .select("id, razorpay_payment_id, status, amount_cents, currency_code, refunded_cents, method, captured_at, failure_reason, created_at, orders(order_reference, orderable_type, razorpay_order_id)")
      .order("created_at", { ascending: false })
      .range(from, to);
    if (status) q = q.eq("status", status);
    return q;
  });
  const csv = toCsv(
    ["payment_id", "razorpay_payment_id", "razorpay_order_id", "order_reference", "type", "status", "amount_paise", "currency", "refunded_paise", "method", "captured_at", "failure_reason"],
    rows.map((p) => [p.id, p.razorpay_payment_id, p.orders?.razorpay_order_id, p.orders?.order_reference, p.orders?.orderable_type, p.status, p.amount_cents, p.currency_code, p.refunded_cents, p.method, p.captured_at, p.failure_reason]),
  );
  return new Response(csv, { headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": `attachment; filename="payments-${new Date().toISOString().slice(0, 10)}.csv"` } });
}
