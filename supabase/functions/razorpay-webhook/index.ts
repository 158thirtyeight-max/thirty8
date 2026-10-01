import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { hmacHex, timingSafeEqual } from "../_shared/crypto.ts";
import { serviceRoleClient } from "../_shared/supabase.ts";

// Razorpay webhook — the SOURCE OF TRUTH for payment/refund state. Deployed
// with verify_jwt=false (Razorpay's request carries no Supabase JWT; it
// authenticates itself via the x-razorpay-signature header instead).
// Idempotent: an event is recorded in processed_webhook_events once its handler has
// succeeded; a failed handler returns 500 so Razorpay redelivers it, and the database
// functions it calls are idempotent, so redelivery is safe.
Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();
  const signature = req.headers.get("x-razorpay-signature") ?? "";

  const admin = serviceRoleClient();
  const { data: webhookSecret } = await admin.rpc("get_app_secret", { p_key: "razorpay_webhook_secret" });

  if (!webhookSecret) {
    console.error("razorpay_webhook_secret is not configured");
    return new Response("Webhook not configured", { status: 500 });
  }

  const expected = await hmacHex(webhookSecret as string, rawBody);
  if (!timingSafeEqual(expected, signature)) {
    return new Response("Invalid signature", { status: 400 });
  }

  let event;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }
  const paymentEntity = event?.payload?.payment?.entity;
  const refundEntity = event?.payload?.refund?.entity;
  const eventId: string = event.id ?? `${event.event}:${paymentEntity?.id ?? refundEntity?.id ?? crypto.randomUUID()}`;

  const { data: existing } = await admin
    .from("processed_webhook_events")
    .select("id")
    .eq("event_id", eventId)
    .maybeSingle();

  if (existing) {
    return new Response("OK", { status: 200 });
  }

  // An event is recorded as processed ONLY after its handler succeeded. If a handler
  // fails, we answer 500 and do not record the event, so Razorpay redelivers it.
  // The database functions are idempotent, so a redelivery (or a concurrent
  // duplicate delivery) is safe. Events that cannot be matched to an order are
  // logged and acknowledged: retrying them can never succeed.
  try {
    switch (event.event) {
      case "payment.captured": {
        const { data: order } = await admin
          .from("orders")
          .select("order_reference")
          .eq("razorpay_order_id", paymentEntity?.order_id)
          .maybeSingle();
        if (!order) {
          console.error("No matching order for razorpay_order_id", paymentEntity?.order_id);
          break;
        }
        const { data: result, error } = await admin.rpc("confirm_booking_after_payment", {
          p_order_reference: order.order_reference,
          p_payment_id: paymentEntity.id,
          p_amount_cents: paymentEntity.amount,
        });
        if (error) throw new Error(`confirm_booking_after_payment failed: ${error.message}`);
        if (result?.status === "refund_pending") {
          console.warn("Payment captured but not applied; refund queued", order.order_reference, result.reason);
        }
        break;
      }
      case "payment.failed": {
        const { data: order } = await admin
          .from("orders")
          .select("order_reference")
          .eq("razorpay_order_id", paymentEntity?.order_id)
          .maybeSingle();
        if (!order) {
          console.error("No matching order for razorpay_order_id", paymentEntity?.order_id);
          break;
        }
        const { error } = await admin.rpc("handle_payment_failure", { p_order_reference: order.order_reference });
        if (error) throw new Error(`handle_payment_failure failed: ${error.message}`);
        break;
      }
      case "refund.processed": {
        const { error } = await admin.rpc("confirm_refund", {
          p_razorpay_refund_id: refundEntity.id,
          p_payment_id: refundEntity.payment_id,
        });
        if (error) throw new Error(`confirm_refund failed: ${error.message}`);
        break;
      }
      default:
        // Unhandled event types are fine to ignore — just acknowledge receipt.
        break;
    }
  } catch (err) {
    console.error("Webhook processing error", err);
    return new Response("Processing failed", { status: 500 });
  }

  const { error: recordError } = await admin
    .from("processed_webhook_events")
    .insert({ event_id: eventId, event_type: event.event });
  // 23505 = a concurrent delivery of the same event recorded it first; that is fine.
  if (recordError && recordError.code !== "23505") {
    console.error("Failed to record processed webhook event", recordError);
    return new Response("Processing failed", { status: 500 });
  }

  return new Response("OK", { status: 200 });
});
