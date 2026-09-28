import 'dart:async';

import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'razorpay_result.dart';

Future<RazorpayCheckoutResult> openRazorpayCheckout({
  required String keyId,
  required int amountCents,
  required String razorpayOrderId,
  required String name,
  required String description,
  String? prefillEmail,
  String? prefillContact,
}) {
  final completer = Completer<RazorpayCheckoutResult>();
  final razorpay = Razorpay();

  razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
    if (!completer.isCompleted) {
      completer.complete(RazorpayCheckoutResult.success(
        razorpayPaymentId: r.paymentId,
        razorpayOrderId: r.orderId,
        razorpaySignature: r.signature,
      ));
    }
    razorpay.clear();
  });

  razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
    if (!completer.isCompleted) {
      completer.complete(RazorpayCheckoutResult.failure(r.message ?? 'Payment failed'));
    }
    razorpay.clear();
  });

  razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse r) {
    if (!completer.isCompleted) {
      completer.complete(RazorpayCheckoutResult.failure('Payment via external wallet was not completed'));
    }
    razorpay.clear();
  });

  razorpay.open({
    'key': keyId,
    'amount': amountCents,
    'order_id': razorpayOrderId,
    'name': 'Thirty8',
    'description': description,
    'prefill': {
      if (prefillEmail != null) 'email': prefillEmail,
      if (prefillContact != null) 'contact': prefillContact,
    },
    'theme': {'color': '#0F766E'},
  });

  return completer.future;
}
