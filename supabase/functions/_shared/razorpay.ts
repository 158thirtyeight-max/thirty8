// Razorpay helpers. The decision functions are pure (no Deno APIs) so they are
// unit-tested under Node: supabase/tests/edge/razorpay.test.mjs.

export type RazorpayPayment = {
  id: string;
  order_id: string | null;
  amount: number;
  currency: string;
  status: string; // created | authorized | captured | refunded | failed
  method?: string | null;
  error_description?: string | null;
};

export type PaymentDecision =
  | { action: "confirm" }
  | { action: "capture" }
  | { action: "wait" }
  | { action: "failed"; reason: string }
  | { action: "reject"; reason: string };

// What to do with a payment the client claims succeeded, judged ONLY on what Razorpay
// itself reports (never on client-supplied or order-derived numbers).
//  - captured  -> confirm: the money moved. A wrong amount/currency is still passed to
//                 the database, which records the payment and queues a refund request.
//  - authorized-> capture, but only when amount and currency equal the order's, so we
//                 never capture money we are not going to honour.
export function decidePayment(
  p: RazorpayPayment,
  expected: { paymentId: string; razorpayOrderId: string; amountCents: number; currency: string },
): PaymentDecision {
  if (p.id !== expected.paymentId) return { action: "reject", reason: "payment id mismatch" };
  if (p.order_id !== expected.razorpayOrderId) {
    return { action: "reject", reason: "payment belongs to a different order" };
  }
  switch (p.status) {
    case "captured":
      return { action: "confirm" };
    case "authorized":
      if (p.amount !== expected.amountCents || p.currency.toUpperCase() !== expected.currency.toUpperCase()) {
        return { action: "reject", reason: "authorized amount or currency does not match the order" };
      }
      return { action: "capture" };
    case "failed":
      return { action: "failed", reason: p.error_description ?? "payment failed" };
    case "refunded":
      // fully refunded already: it was captured, let the database see it
      return { action: "confirm" };
    default:
      return { action: "wait" };
  }
}

export type RazorpayRefund = {
  id: string;
  payment_id: string;
  amount: number;
  status: string; // pending | processed | failed
  notes?: Record<string, unknown> | unknown[] | null;
};

// The refund we created for our own refund row, found by the id we put in `notes`.
export function findRefundByOurId(refunds: RazorpayRefund[], ourRefundId: string): RazorpayRefund | undefined {
  return refunds.find((r) => {
    const notes = r.notes;
    return !!notes && !Array.isArray(notes) && (notes as Record<string, unknown>).refund_id === ourRefundId;
  });
}

// HTTP status -> was the provider's answer definitive?
// 4xx = Razorpay refused (definitive failure). 5xx / timeouts / network errors = unknown.
export function isDefinitiveRefusal(httpStatus: number): boolean {
  return httpStatus >= 400 && httpStatus < 500 && httpStatus !== 408 && httpStatus !== 429;
}
