/// What the customer is told after paying.
///
/// The Razorpay checkout callback alone proves nothing: the ticket is shown only once the BACKEND
/// (verify-payment, which asks Razorpay what was really paid) says `ok`. These helpers turn the backend's
/// answers into a small set of outcomes so every screen reacts the same way, and so the rules can be tested.
library;

enum PaymentOutcome {
  /// Verified and the booking is confirmed.
  confirmed,

  /// Razorpay has not (yet) reported the payment as captured: safe to check again, never pay again.
  processing,

  /// Money was received but the booking could not be confirmed; a refund has been requested.
  notApplied,

  /// The payment failed; the customer may try again.
  failed,

  /// The payment did not match the order (or the signature was wrong).
  rejected,

  /// We could not reach the backend / Razorpay: the result is unknown. Checking again is safe (idempotent).
  unreachable,
}

PaymentOutcome interpretVerifyResponse(int? status, Object? body) {
  final map = body is Map ? body : const {};
  final code = map['code'];
  if (status == 200 && map['ok'] == true) return PaymentOutcome.confirmed;
  if (code == 'payment_not_applied') return PaymentOutcome.notApplied;
  if (code == 'payment_pending' || status == 202) return PaymentOutcome.processing;
  if (code == 'payment_failed' || status == 402) return PaymentOutcome.failed;
  if (code == 'payment_rejected' || status == 400) return PaymentOutcome.rejected;
  return PaymentOutcome.unreachable;
}

String paymentOutcomeMessage(PaymentOutcome outcome) {
  switch (outcome) {
    case PaymentOutcome.confirmed:
      return 'Payment confirmed.';
    case PaymentOutcome.processing:
      return 'Your payment is being confirmed. This usually takes a few seconds. Please do not pay again.';
    case PaymentOutcome.notApplied:
      return 'Your payment was received, but we could not confirm this booking (for example the seats were released). A refund has been requested and thirty8 will review it.';
    case PaymentOutcome.failed:
      return 'The payment did not go through. You have not been charged for a ticket. You can try again.';
    case PaymentOutcome.rejected:
      return 'We could not match this payment to your booking. If money was deducted, please contact support.';
    case PaymentOutcome.unreachable:
      return 'We could not confirm your payment right now (check your connection). If money was deducted, it is safe: tap "Check again" and do not pay twice.';
  }
}

/// create-order refuses an order that is no longer payable (already paid, cancelled...). Returns a message when so.
String? orderNotPayableMessage(String? backendError) {
  if (backendError == null || !backendError.contains('not payable')) return null;
  if (backendError.contains('paid')) {
    return 'This booking has already been paid for. Open My Trips to see its status; do not pay again.';
  }
  return 'This booking can no longer be paid for. Please start a new booking.';
}
