import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { hmacHex, timingSafeEqual } from "../_shared/crypto.ts";
import { serviceRoleClient } from "../_shared/supabase.ts";

// Razorpay webhook — the SOURCE OF TRUTH for payment/refund state. Deployed
// with verify_jwt=false (Razorpay's request carries no Supabase JWT; it
// authenticates itself via the x-razorpay-signature header instead, verified
// against the RAW request body).
//
// Idempotency: every verified event is claimed in processed_webhook_events
// (webhook_begin). A duplicate of a processed event is acknowledged and ignored; an
// event another worker is still processing answers 409 so Razorpay redelivers it
// later; a failed event is retried on redelivery (attempts are counted). The database
// functions it calls are idempotent as well, so redelivery is always safe.
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

  const { data: claim, error: claimError } = await admin.rpc("webhook_begin", {
    p_event_id: eventId,
    p_event_type: event.event,
    p_payload: event,
  });
  if (claimError) {
    console.error("webhook_begin failed", claimError);
    return new Response("Processing failed", { status: 500 });
  }
  if (claim === "duplicate") return new Response("OK", { status: 200 });
  if (claim === "in_progress") return new Response("Event is being processed", { status: 409 });

  const orderFor = async (razorpayOrderId: string | undefined) => {
    const { data: order } = await admin
      .from("orders")
      .select("order_reference")
      .eq("razorpay_order_id", razorpayOrderId ?? "")
      .maybeSingle();
    if (!order) {
      console.error("No matching order for razorpay_order_id", razorpayOrderId);
      // retrying can never succeed: queue it for an admin instead
      await admin.rpc("record_exception", {
        p_kind: "webhook_unmatched_order",
        p_severity: "critical",
        p_entity_type: "payment",
        p_entity_id: paymentEntity?.id ?? String(razorpayOrderId),
        p_details: { event: event.event, razorpay_order_id: razorpayOrderId },
      });
    }
    return order;
  };

  try {
    switch (event.event) {
      case "payment.captured": {
        const order = await orderFor(paymentEntity?.order_id);
        if (!order) break;
        const { data: result, error } = await admin.rpc("confirm_booking_after_payment", {
          p_order_reference: order.order_reference,
          p_payment_id: paymentEntity.id,
          p_amount_cents: paymentEntity.amount,
          p_currency: paymentEntity.currency ?? "INR",
          p_method: paymentEntity.method ?? null,
        });
        if (error) throw new Error(`confirm_booking_after_payment failed: ${error.message}`);
        if (result?.status === "refund_pending" || result?.status === "duplicate_refund_pending") {
          console.warn("Payment captured but not applied; refund requested", order.order_reference, result.reason);
        }
        break;
      }
      case "payment.failed": {
        const order = await orderFor(paymentEntity?.order_id);
        if (!order) break;
        const { error } = await admin.rpc("handle_payment_failure", {
          p_order_reference: order.order_reference,
          p_razorpay_payment_id: paymentEntity?.id ?? null,
          p_reason: paymentEntity?.error_description ?? null,
        });
        if (error) throw new Error(`handle_payment_failure failed: ${error.message}`);
        break;
      }
      case "refund.processed": {
        const { error } = await admin.rpc("confirm_refund", {
          p_razorpay_refund_id: refundEntity.id,
          p_payment_id: refundEntity.payment_id,
          p_refund_id: refundEntity.notes?.refund_id ?? null,
        });
        if (error) throw new Error(`confirm_refund failed: ${error.message}`);
        break;
      }
      case "refund.failed": {
        const { error } = await admin.rpc("fail_refund", {
          p_razorpay_refund_id: refundEntity.id,
          p_refund_id: refundEntity.notes?.refund_id ?? null,
          p_reason: "Refund failed at Razorpay",
        });
        if (error) throw new Error(`fail_refund failed: ${error.message}`);
        break;
      }
      default:
        // Unhandled event types are fine to ignore — just acknowledge receipt.
        break;
    }
  } catch (err) {
    console.error("Webhook processing error", err);
    await admin.rpc("webhook_finish", {
      p_event_id: eventId,
      p_ok: false,
      p_error: err instanceof Error ? err.message : String(err),
    });
    return new Response("Processing failed", { status: 500 });
  }

  const { error: finishError } = await admin.rpc("webhook_finish", { p_event_id: eventId, p_ok: true });
  if (finishError) {
    console.error("webhook_finish failed", finishError);
    return new Response("Processing failed", { status: 500 });
  }
  return new Response("OK", { status: 200 });
});
