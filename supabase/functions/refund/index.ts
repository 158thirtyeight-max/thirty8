import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callerClient, getRazorpayCredentials, razorpayAuthHeader, serviceRoleClient } from "../_shared/supabase.ts";

// Executes an actual Razorpay refund for a pending refund row (created by
// cancel_booking / cancel_shipment / reject_cargo_shipment). Per the RBAC
// matrix, real refund execution is platform-admin/finance only — operators
// and customers can only trigger the CANCELLATION that creates the pending
// refund record, never the money movement itself.
Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const caller = callerClient(req);
    const { data: isAdmin, error: authError } = await caller.rpc("am_i_platform_admin");
    if (authError || !isAdmin) {
      return jsonResponse({ error: "Only platform admins can process refunds" }, 403);
    }

    const { refund_id } = await req.json();
    if (!refund_id) {
      return jsonResponse({ error: "refund_id is required" }, 400);
    }

    const admin = serviceRoleClient();
    const { data: refund, error } = await admin
      .from("refunds")
      .select("id, amount_cents, status, payment_id, payments(razorpay_payment_id, status)")
      .eq("id", refund_id)
      .single();

    if (error || !refund) {
      return jsonResponse({ error: "Refund not found" }, 404);
    }
    if (refund.status !== "pending") {
      return jsonResponse({ error: `Refund is not pending (status: ${refund.status})` }, 400);
    }
    const razorpayPaymentId = (refund as { payments?: { razorpay_payment_id?: string } }).payments?.razorpay_payment_id;
    if (!razorpayPaymentId) {
      return jsonResponse({ error: "Underlying payment has no Razorpay payment id" }, 400);
    }

    const { keyId, keySecret } = await getRazorpayCredentials();

    const rpRes = await fetch(`https://api.razorpay.com/v1/payments/${razorpayPaymentId}/refund`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: razorpayAuthHeader(keyId, keySecret),
      },
      body: JSON.stringify({ amount: refund.amount_cents }),
    });

    const rpRefund = await rpRes.json();
    if (!rpRes.ok) {
      console.error("Razorpay refund failed", rpRefund);
      return jsonResponse({ error: "Razorpay refund request failed", details: rpRefund }, 502);
    }

    // Optimistic confirmation; refund.processed webhook will safely no-op
    // if it arrives afterwards (confirm_refund is idempotent).
    const { error: confirmError } = await admin.rpc("confirm_refund", {
      p_razorpay_refund_id: rpRefund.id,
      p_payment_id: razorpayPaymentId,
    });
    if (confirmError) {
      console.error("confirm_refund failed", confirmError);
      return jsonResponse({ error: "Refund issued at Razorpay but failed to record locally", razorpay_refund_id: rpRefund.id }, 500);
    }

    return jsonResponse({ ok: true, razorpay_refund_id: rpRefund.id, status: rpRefund.status });
  } catch (err) {
    console.error(err);
    return jsonResponse({ error: "Unexpected error" }, 500);
  }
});
