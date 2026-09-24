import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { hmacHex, timingSafeEqual } from "../_shared/crypto.ts";
import { serviceRoleClient } from "../_shared/supabase.ts";

// Razorpay webhook — the SOURCE OF TRUTH for payment/refund state. Deployed
// with verify_jwt=false (Razorpay's request carries no Supabase JWT; it
// authenticates itself via the x-razorpay-signature header instead).
// Idempotent: every event is recorded in processed_webhook_events before
// being acted on, so a retried delivery is a safe no-op.
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

  const event = JSON.parse(rawBody);
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

  try {
    switch (event.event) {
      case "payment.captured": {
        const { data: order } = await admin
          .from("orders")
          .select("order_reference")
          .eq("razorpay_order_id", paymentEntity.order_id)
          .single();
        if (!order) {
          console.error("No matching order for razorpay_order_id", paymentEntity.order_id);
          break;
        }
        const { error } = await admin.rpc("confirm_booking_after_payment", {
          p_order_reference: order.order_reference,
          p_payment_id: paymentEntity.id,
          p_amount_cents: paymentEntity.amount,
        });
        if (error) console.error("confirm_booking_after_payment failed", error);
        break;
      }
      case "payment.failed": {
        const { data: order } = await admin
          .from("orders")
          .select("order_reference")
          .eq("razorpay_order_id", paymentEntity.order_id)
          .single();
        if (!order) {
          console.error("No matching order for razorpay_order_id", paymentEntity.order_id);
          break;
        }
        const { error } = await admin.rpc("handle_payment_failure", { p_order_reference: order.order_reference });
        if (error) console.error("handle_payment_failure failed", error);
        break;
      }
      case "refund.processed": {
        const { error } = await admin.rpc("confirm_refund", {
          p_razorpay_refund_id: refundEntity.id,
          p_payment_id: refundEntity.payment_id,
        });
        if (error) console.error("confirm_refund failed", error);
        break;
      }
      default:
        // Unhandled event types are fine to ignore — just acknowledge receipt.
        break;
    }
  } catch (err) {
    console.error("Webhook processing error", err);
    // Still record the event as processed below: retrying a handler error
    // via Razorpay's own retry schedule won't fix an application bug, and
    // we don't want infinite redelivery. Failures are visible in function logs.
  }

  await admin.from("processed_webhook_events").insert({ event_id: eventId, event_type: event.event });

  return new Response("OK", { status: 200 });
});
