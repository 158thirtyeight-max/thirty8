import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { hmacHex, timingSafeEqual } from "../_shared/crypto.ts";
import { decidePayment, type RazorpayPayment } from "../_shared/razorpay.ts";
import { callerClient, getRazorpayCredentials, razorpayAuthHeader, serviceRoleClient } from "../_shared/supabase.ts";

const NOT_APPLIED = {
  ok: false,
  code: "payment_not_applied",
  error: "Your payment was received but the booking could not be confirmed. A refund has been requested.",
};

// Verifies the signature Razorpay Checkout returns to the client, then asks
// RAZORPAY (not the client, not our own order row) what was actually paid, and only
// then fulfils the order. This is a fast path, not the source of truth: the
// razorpay-webhook function applies the same (idempotent) fulfilment, so a payment
// is never stranded if the app dies right after paying, and calling this again is
// the safe way to recover a booking without charging the customer twice.
Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { order_reference, razorpay_order_id, razorpay_payment_id, razorpay_signature } = await req.json();
    if (!order_reference || !razorpay_order_id || !razorpay_payment_id || !razorpay_signature) {
      return jsonResponse({ error: "order_reference, razorpay_order_id, razorpay_payment_id and razorpay_signature are required" }, 400);
    }

    // RLS-scoped: caller can only verify payment for their OWN order.
    const caller = callerClient(req);
    const { data: order, error } = await caller
      .from("orders")
      .select("id, amount_cents, currency_code, razorpay_order_id, status, orderable_type, orderable_id")
      .eq("order_reference", order_reference)
      .single();

    if (error || !order) {
      return jsonResponse({ error: "Order not found" }, 404);
    }
    if (order.razorpay_order_id !== razorpay_order_id) {
      return jsonResponse({ error: "razorpay_order_id does not match this order" }, 400);
    }

    const { keyId, keySecret } = await getRazorpayCredentials();
    const expectedSig = await hmacHex(keySecret, `${razorpay_order_id}|${razorpay_payment_id}`);
    if (!timingSafeEqual(expectedSig, razorpay_signature)) {
      return jsonResponse({ ok: false, error: "Invalid payment signature" }, 400);
    }

    const auth = razorpayAuthHeader(keyId, keySecret);
    const admin = serviceRoleClient();

    // What did Razorpay actually receive?
    const fetchRes = await fetch(`https://api.razorpay.com/v1/payments/${razorpay_payment_id}`, {
      headers: { Authorization: auth },
    });
    if (!fetchRes.ok) {
      console.error("Razorpay payment fetch failed", fetchRes.status);
      return jsonResponse({ ok: false, code: "provider_unavailable", error: "Could not verify the payment right now. Please retry." }, 502);
    }
    let payment = (await fetchRes.json()) as RazorpayPayment;

    const expected = {
      paymentId: razorpay_payment_id as string,
      razorpayOrderId: razorpay_order_id as string,
      amountCents: order.amount_cents as number,
      currency: order.currency_code as string,
    };
    let decision = decidePayment(payment, expected);

    if (decision.action === "capture") {
      const capRes = await fetch(`https://api.razorpay.com/v1/payments/${razorpay_payment_id}/capture`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: auth },
        body: JSON.stringify({ amount: order.amount_cents, currency: order.currency_code }),
      });
      if (!capRes.ok) {
        console.error("Razorpay capture failed", capRes.status, await capRes.text());
        return jsonResponse({ ok: false, code: "payment_pending", error: "Payment is being processed. Please check again shortly." }, 202);
      }
      payment = (await capRes.json()) as RazorpayPayment;
      decision = decidePayment(payment, expected);
    }

    if (decision.action === "reject") {
      console.error("Payment rejected", decision.reason, razorpay_payment_id);
      return jsonResponse({ ok: false, code: "payment_rejected", error: "This payment does not match the order." }, 400);
    }
    if (decision.action === "failed") {
      await admin.rpc("handle_payment_failure", {
        p_order_reference: order_reference,
        p_razorpay_payment_id: razorpay_payment_id,
        p_reason: decision.reason,
      });
      return jsonResponse({ ok: false, code: "payment_failed", error: "The payment failed. You can try again." }, 402);
    }
    if (decision.action === "wait") {
      return jsonResponse({ ok: false, code: "payment_pending", error: "Payment is still being processed. Please check again shortly." }, 202);
    }

    // captured: the provider's own amount and currency go to the database, which validates them
    const { data: result, error: rpcError } = await admin.rpc("confirm_booking_after_payment", {
      p_order_reference: order_reference,
      p_payment_id: razorpay_payment_id,
      p_amount_cents: payment.amount,
      p_currency: payment.currency,
      p_method: payment.method ?? null,
    });
    if (rpcError) {
      console.error("confirm_booking_after_payment failed", rpcError);
      return jsonResponse({ error: "Failed to confirm booking" }, 500);
    }

    if (result?.status === "refund_pending" || result?.status === "duplicate_refund_pending") {
      return jsonResponse({ ...NOT_APPLIED, reason: result.reason }, 409);
    }

    if (result?.already_processed && order.orderable_type === "booking") {
      // "Paid" does not mean confirmed: a payment that could not be applied is paid + refund requested.
      const { data: booking } = await caller.from("bookings").select("status").eq("id", order.orderable_id).maybeSingle();
      if (booking?.status !== "confirmed") return jsonResponse(NOT_APPLIED, 409);
    }

    return jsonResponse({ ok: true, ...result });
  } catch (err) {
    console.error(err);
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
