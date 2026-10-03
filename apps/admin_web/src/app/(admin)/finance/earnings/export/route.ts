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
      .from("operator_earnings")
      .select("id, status, hold_reason, gross_cents, commission_bps, commission_cents, operator_net_cents, commission_basis, rounding_policy, eligible_at, refund_adjustment_cents, bookings(booking_reference), operators(name), settlements(reference)")
      .order("created_at", { ascending: false })
      .range(from, to);
    if (status) q = q.eq("status", status);
    return q;
  });
  const csv = toCsv(
    ["earning_id", "ticket_reference", "operator", "status", "hold_reason", "gross_paise", "commission_bps", "commission_paise", "operator_net_paise", "basis", "rounding", "eligible_at", "refund_adjustment_paise", "settlement"],
    rows.map((e) => [e.id, e.bookings?.booking_reference, e.operators?.name, e.status, e.hold_reason, e.gross_cents, e.commission_bps, e.commission_cents, e.operator_net_cents, e.commission_basis, e.rounding_policy, e.eligible_at, e.refund_adjustment_cents, e.settlements?.reference]),
  );
  return new Response(csv, { headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": `attachment; filename="operator-earnings-${new Date().toISOString().slice(0, 10)}.csv"` } });
}
