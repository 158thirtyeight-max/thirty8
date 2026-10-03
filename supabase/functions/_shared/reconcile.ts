// Pure comparison of Razorpay's records with ours (no Deno APIs): unit-tested under Node in
// supabase/tests/edge/reconcile.test.mjs. The edge function fetches both sides and only REPORTS findings as
// reconciliation exceptions; it never edits a payment, refund or ledger record to make them agree.

export type ProviderPayment = { id: string; order_id: string | null; amount: number; currency: string; status: string };
export type DbPayment = { razorpay_payment_id: string; status: string; amount_cents: number; currency_code: string };
export type ProviderRefund = { id: string; payment_id: string; amount: number; status: string };
export type DbRefund = { razorpay_refund_id: string | null; status: string; amount_cents: number };

export type Finding = { kind: string; entity_type: "payment" | "refund"; entity_id: string; details: Record<string, unknown> };

const DB_MONEY_IN = new Set(["captured", "refunded", "duplicate_captured"]);

export function comparePayments(provider: ProviderPayment[], db: DbPayment[]): Finding[] {
  const out: Finding[] = [];
  const dbById = new Map(db.map((p) => [p.razorpay_payment_id, p]));
  const provById = new Map(provider.map((p) => [p.id, p]));

  for (const p of provider) {
    // authorized-but-not-captured payments are not money in; "captured" and later "refunded" are
    if (p.status !== "captured" && p.status !== "refunded") continue;
    const ours = dbById.get(p.id);
    if (!ours) {
      out.push({ kind: "provider_payment_missing_in_db", entity_type: "payment", entity_id: p.id, details: { amount: p.amount, order_id: p.order_id } });
      continue;
    }
    if (!DB_MONEY_IN.has(ours.status)) {
      out.push({ kind: "provider_captured_db_not", entity_type: "payment", entity_id: p.id, details: { db_status: ours.status, provider_status: p.status } });
    }
    if (ours.amount_cents !== p.amount || ours.currency_code.toUpperCase() !== p.currency.toUpperCase()) {
      out.push({
        kind: "payment_amount_mismatch", entity_type: "payment", entity_id: p.id,
        details: { db_amount: ours.amount_cents, provider_amount: p.amount, db_currency: ours.currency_code, provider_currency: p.currency },
      });
    }
  }

  for (const ours of db) {
    if (!DB_MONEY_IN.has(ours.status)) continue;
    const p = provById.get(ours.razorpay_payment_id);
    // absent from the provider's window is not proof of a problem (the windows can differ); only a payment the provider
    // returned in a non-captured state is a definite disagreement
    if (p && p.status !== "captured" && p.status !== "refunded") {
      out.push({ kind: "db_paid_provider_not_captured", entity_type: "payment", entity_id: ours.razorpay_payment_id, details: { provider_status: p.status, db_status: ours.status } });
    }
  }
  return out;
}

export function compareRefunds(provider: ProviderRefund[], db: DbRefund[]): Finding[] {
  const out: Finding[] = [];
  const dbById = new Map(db.filter((r) => r.razorpay_refund_id).map((r) => [r.razorpay_refund_id as string, r]));
  const provById = new Map(provider.map((r) => [r.id, r]));

  for (const r of provider) {
    if (r.status !== "processed") continue;
    const ours = dbById.get(r.id);
    if (!ours) {
      out.push({ kind: "provider_refund_missing_in_db", entity_type: "refund", entity_id: r.id, details: { payment_id: r.payment_id, amount: r.amount } });
      continue;
    }
    if (ours.status !== "processed") {
      out.push({ kind: "refund_not_processed_in_db", entity_type: "refund", entity_id: r.id, details: { db_status: ours.status } });
    }
    if (ours.amount_cents !== r.amount) {
      out.push({ kind: "refund_amount_mismatch", entity_type: "refund", entity_id: r.id, details: { db_amount: ours.amount_cents, provider_amount: r.amount } });
    }
  }
  for (const ours of db) {
    if (ours.status !== "processed" || !ours.razorpay_refund_id) continue;
    const r = provById.get(ours.razorpay_refund_id);
    if (r && r.status !== "processed") {
      out.push({ kind: "db_refund_not_processed_at_provider", entity_type: "refund", entity_id: ours.razorpay_refund_id, details: { provider_status: r.status } });
    }
  }
  return out;
}
