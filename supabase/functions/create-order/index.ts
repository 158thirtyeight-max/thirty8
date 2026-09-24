import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleOptions, jsonResponse } from "../_shared/cors.ts";
import { callerClient, getRazorpayCredentials, razorpayAuthHeader, serviceRoleClient } from "../_shared/supabase.ts";

// Creates a Razorpay order for an existing Thirty8 order row. The amount is
// ALWAYS read from our own `orders` table (set server-side by create_booking
// / create_shipment) — never trusted from the request body.
Deno.serve(async (req) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;

  try {
    const { order_reference } = await req.json();
    if (!order_reference || typeof order_reference !== "string") {
      return jsonResponse({ error: "order_reference is required" }, 400);
    }

    // Caller-scoped client: RLS (orders_select_own) ensures a user can only
    // ever create a Razorpay order for their OWN Thirty8 order.
    const caller = callerClient(req);
    const { data: order, error } = await caller
      .from("orders")
      .select("id, order_reference, amount_cents, currency_code, status, razorpay_order_id")
      .eq("order_reference", order_reference)
      .single();

    if (error || !order) {
      return jsonResponse({ error: "Order not found" }, 404);
    }
    if (order.status !== "created") {
      return jsonResponse({ error: `Order is not payable (status: ${order.status})` }, 400);
    }
    if (order.razorpay_order_id) {
      // Already has a Razorpay order (e.g. client retried) — return the existing one.
      return jsonResponse({
        razorpay_order_id: order.razorpay_order_id,
        amount: order.amount_cents,
        currency: order.currency_code,
      });
    }

    const { keyId, keySecret } = await getRazorpayCredentials();

    const rpRes = await fetch("https://api.razorpay.com/v1/orders", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: razorpayAuthHeader(keyId, keySecret),
      },
      body: JSON.stringify({
        amount: order.amount_cents,
        currency: order.currency_code,
        receipt: order.order_reference,
        notes: { source: "thirty8" },
      }),
    });

    const rpOrder = await rpRes.json();
    if (!rpRes.ok) {
      console.error("Razorpay create order failed", rpOrder);
      return jsonResponse({ error: "Failed to create payment order" }, 502);
    }

    // Only the service-role client may write razorpay_order_id back onto
    // the order (there is no client UPDATE policy on `orders`).
    const admin = serviceRoleClient();
    const { error: updateError } = await admin
      .from("orders")
      .update({ razorpay_order_id: rpOrder.id })
      .eq("id", order.id);

    if (updateError) {
      console.error("Failed to persist razorpay_order_id", updateError);
      return jsonResponse({ error: "Failed to record payment order" }, 500);
    }

    return jsonResponse({
      razorpay_order_id: rpOrder.id,
      amount: rpOrder.amount,
      currency: rpOrder.currency,
      key_id: keyId,
    });
  } catch (err) {
    console.error(err);
    return jsonResponse({ error: "Unexpected error" }, 500);
  }
});
