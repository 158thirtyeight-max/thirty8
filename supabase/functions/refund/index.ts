import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { findRefundByOurId, isDefinitiveRefusal, type RazorpayRefund } from "../_shared/razorpay.ts";
import { callerClient, getRazorpayCredentials, razorpayAuthHeader, serviceRoleClient } from "../_shared/supabase.ts";

// Executes an ADMIN-APPROVED refund at Razorpay. Money movement is full-admin only:
// cancellations merely create a `requested` row, an admin approves it
// (admin_approve_refund) and only then does this function run.
//
// Safety:
//  * the refund is claimed under a row lock by admin_begin_refund_execution (runs with the
//    admin's JWT, so it also enforces full-admin inside the database) — two clicks or two
//    tabs can never both reach Razorpay;
//  * before creating a refund we ask Razorpay whether one already exists for this refund
//    row (we put our refund id in `notes`), so a retry after a timeout cannot refund twice;
//  * "accepted" is not "completed": the refund only completes when Razorpay reports it
//    `processed` (in this response, or later through the refund.processed webhook);
//  * a definitive 4xx refusal marks the refund failed (admin can retry); a timeout or 5xx
//    leaves it submitted_to_provider so the state is reconciled, never guessed.
const RAZORPAY = "https://api.razorpay.com/v1";

async function rp(path: string, auth: string, init: RequestInit = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 20000);
  try {
    return await fetch(`${RAZORPAY}${path}`, {
      ...init,
      signal: ctrl.signal,
      headers: { "Content-Type": "application/json", Authorization: auth, ...(init.headers ?? {}) },
    });
  } finally {
    clearTimeout(timer);
  }
}

Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const caller = callerClient(req);
    const { data: isFullAdmin, error: authError } = await caller.rpc("am_i_full_admin");
    if (authError || !isFullAdmin) {
      return jsonResponse({ error: "Only full platform admins can execute refunds" }, 403);
    }

    const { refund_id } = await req.json();
    if (!refund_id) return jsonResponse({ error: "refund_id is required" }, 400);

    // claim under lock (state must be `approved`, or a stale `submitted_to_provider` resume)
    const { data: claim, error: claimError } = await caller.rpc("admin_begin_refund_execution", { p_refund_id: refund_id });
    if (claimError) {
      const code = claimError.message.startsWith("refund_in_flight") ? 409 : 400;
      return jsonResponse({ error: claimError.message }, code);
    }

    const { keyId, keySecret } = await getRazorpayCredentials();
    const auth = razorpayAuthHeader(keyId, keySecret);
    const admin = serviceRoleClient();
    const paymentId: string = claim.razorpay_payment_id;

    // Did a previous attempt already create the refund at Razorpay?
    let existing: RazorpayRefund | undefined;
    try {
      if (claim.razorpay_refund_id) {
        const r = await rp(`/refunds/${claim.razorpay_refund_id}`, auth);
        if (r.ok) existing = (await r.json()) as RazorpayRefund;
      } else {
        const r = await rp(`/payments/${paymentId}/refunds?count=100`, auth);
        if (r.ok) existing = findRefundByOurId(((await r.json()).items ?? []) as RazorpayRefund[], refund_id);
      }
    } catch (err) {
      console.error("Provider refund lookup failed", err);
      return jsonResponse({ ok: false, code: "provider_state_unknown", error: "Could not check Razorpay. The refund stays submitted; retry in a few minutes." }, 502);
    }

    let providerRefund = existing;
    if (!providerRefund) {
      let res: Response;
      try {
        res = await rp(`/payments/${paymentId}/refund`, auth, {
          method: "POST",
          body: JSON.stringify({ amount: claim.amount_cents, notes: { refund_id }, receipt: refund_id }),
        });
      } catch (err) {
        console.error("Razorpay refund call did not complete", err);
        // state unknown: do NOT mark failed; a later run looks the refund up by notes first
        return jsonResponse({ ok: false, code: "provider_state_unknown", error: "Razorpay did not answer. The refund stays submitted; retry in a few minutes." }, 502);
      }
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        console.error("Razorpay refund refused", res.status, body);
        if (isDefinitiveRefusal(res.status)) {
          await admin.rpc("record_refund_provider_result", {
            p_refund_id: refund_id,
            p_razorpay_refund_id: null,
            p_provider_status: "failed",
            p_failure: body?.error?.description ?? `Razorpay refused the refund (HTTP ${res.status})`,
            p_definitive_failure: true,
          });
          return jsonResponse({ ok: false, code: "refund_failed", error: body?.error?.description ?? "Razorpay refused the refund" }, 502);
        }
        return jsonResponse({ ok: false, code: "provider_state_unknown", error: "Razorpay had a temporary problem. The refund stays submitted; retry in a few minutes." }, 502);
      }
      providerRefund = body as RazorpayRefund;
    }

    const { data: status, error: recordError } = await admin.rpc("record_refund_provider_result", {
      p_refund_id: refund_id,
      p_razorpay_refund_id: providerRefund.id,
      p_provider_status: providerRefund.status,
      p_failure: null,
      p_definitive_failure: false,
    });
    if (recordError) {
      console.error("record_refund_provider_result failed", recordError);
      return jsonResponse({ error: "Refund exists at Razorpay but could not be recorded locally", razorpay_refund_id: providerRefund.id }, 500);
    }

    return jsonResponse({ ok: true, status, razorpay_refund_id: providerRefund.id, provider_status: providerRefund.status });
  } catch (err) {
    console.error(err);
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
