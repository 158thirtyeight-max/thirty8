import 'razorpay_result.dart';

/// razorpay_flutter has no web implementation. A real web checkout would
/// embed Razorpay's checkout.js directly; not built yet — the web target
/// exists for development/testing (search, booking, etc.), and payment is
/// completed on the mobile app for now.
Future<RazorpayCheckoutResult> openRazorpayCheckout({
  required String keyId,
  required int amountCents,
  required String razorpayOrderId,
  required String name,
  required String description,
  String? prefillEmail,
  String? prefillContact,
}) async {
  return RazorpayCheckoutResult.failure(
    'Payment checkout is not yet available on web — please use the Thirty8 mobile app to complete payment.',
  );
}
