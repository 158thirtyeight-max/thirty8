import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { compareRefunds, comparePayments, type Finding, type ProviderPayment, type ProviderRefund } from "../_shared/reconcile.ts";
import { callerClient, getRazorpayCredentials, razorpayAuthHeader, serviceRoleClient } from "../_shared/supabase.ts";

// Compares Razorpay's recent payments and refunds with ours and records every disagreement as a reconciliation
// exception. It only REPORTS: no payment, refund or ledger record is ever edited to make them agree.
// Runs nightly (pg_cron -> pg_net with the internal secret) or on demand by a full admin.
const PAGE = 100;
const MAX_PAGES = 30;

async function fetchAll<T>(path: string, auth: string, from: number, to: number): Promise<T[]> {
  const out: T[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await fetch(`https://api.razorpay.com/v1/${path}?from=${from}&to=${to}&count=${PAGE}&skip=${page * PAGE}`, { headers: { Authorization: auth } });
    if (!res.ok) throw new Error(`Razorpay ${path} returned HTTP ${res.status}`);
    const body = await res.json();
    const items = (body.items ?? []) as T[];
    out.push(...items);
    if (items.length < PAGE) break;
  }
  return out;
}

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  const admin = serviceRoleClient();

  // authorised either by the internal secret (the nightly job) or by a full admin
  const { data: secret } = await admin.rpc("get_app_secret", { p_key: "internal_dispatch_secret" });
  const internal = !!secret && req.headers.get("x-internal-secret") === secret;
  if (!internal) {
    const { data: isFullAdmin } = await callerClient(req).rpc("am_i_full_admin");
    if (!isFullAdmin) return jsonResponse({ error: "Not authorized" }, 403);
  }

  try {
    const body = await req.json().catch(() => ({}));
    const days = Math.min(Math.max(Number(body?.days) || 3, 1), 31);
    const to = Math.floor(Date.now() / 1000);
    const from = to - days * 86400;

    let keys;
    try {
      keys = await getRazorpayCredentials();
    } catch {
      return jsonResponse({ ok: true, skipped: "Razorpay is not configured" });
    }
    const auth = razorpayAuthHeader(keys.keyId, keys.keySecret);
    const [rpPayments, rpRefunds] = await Promise.all([
      fetchAll<ProviderPayment>("payments", auth, from, to),
      fetchAll<ProviderRefund>("refunds", auth, from, to),
    ]);

    const since = new Date(from * 1000).toISOString();
    const [{ data: dbPayments }, { data: dbRefunds }] = await Promise.all([
      admin.from("payments").select("razorpay_payment_id, status, amount_cents, currency_code").gte("created_at", since).not("razorpay_payment_id", "is", null),
      admin.from("refunds").select("razorpay_refund_id, status, amount_cents").gte("created_at", since),
    ]);

    const findings: Finding[] = [
      ...comparePayments(rpPayments, dbPayments ?? []),
      ...compareRefunds(rpRefunds, dbRefunds ?? []),
    ];
    for (const f of findings) {
      await admin.rpc("record_exception", {
        p_kind: f.kind, p_severity: "critical", p_entity_type: f.entity_type, p_entity_id: f.entity_id, p_details: f.details,
      });
    }
    return jsonResponse({ ok: true, window_days: days, provider_payments: rpPayments.length, provider_refunds: rpRefunds.length, findings: findings.length });
  } catch (err) {
    console.error(err);
    return jsonResponse({ ok: false, error: err instanceof Error ? err.message : "Unexpected error" }, 502);
  }
});
