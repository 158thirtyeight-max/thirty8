import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { hmacHex, timingSafeEqual } from "../_shared/crypto.ts";
import { callerClient, getRazorpayCredentials, serviceRoleClient } from "../_shared/supabase.ts";

// Verifies the signature Razorpay Checkout returns to the client on
// success, then optimistically fulfills the order for a fast UI response.
// This is an OPTIMIZATION, not the source of truth: the razorpay-webhook
// function does the same fulfillment (idempotently) and is what actually
// guarantees consistency if the client never calls this (app killed, no
// network, etc. right after paying).
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
      .select("id, amount_cents, razorpay_order_id, status")
      .eq("order_reference", order_reference)
      .single();

    if (error || !order) {
      return jsonResponse({ error: "Order not found" }, 404);
    }
    if (order.razorpay_order_id !== razorpay_order_id) {
      return jsonResponse({ error: "razorpay_order_id does not match this order" }, 400);
    }

    const { keySecret } = await getRazorpayCredentials();
    const expected = await hmacHex(keySecret, `${razorpay_order_id}|${razorpay_payment_id}`);

    if (!timingSafeEqual(expected, razorpay_signature)) {
      return jsonResponse({ ok: false, error: "Invalid payment signature" }, 400);
    }

    if (order.status === "paid") {
      return jsonResponse({ ok: true, already_processed: true });
    }

    const admin = serviceRoleClient();
    const { data: result, error: rpcError } = await admin.rpc("confirm_booking_after_payment", {
      p_order_reference: order_reference,
      p_payment_id: razorpay_payment_id,
      p_amount_cents: order.amount_cents,
    });

    if (rpcError) {
      console.error("confirm_booking_after_payment failed", rpcError);
      return jsonResponse({ error: "Failed to confirm booking" }, 500);
    }

    return jsonResponse({ ok: true, ...result });
  } catch (err) {
    console.error(err);
    const message = err instanceof Error ? err.message : "Unexpected error";
    return jsonResponse({ error: message }, 500);
  }
});
