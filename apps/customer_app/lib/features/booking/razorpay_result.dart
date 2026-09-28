class RazorpayCheckoutResult {
  final bool success;
  final String? razorpayPaymentId;
  final String? razorpayOrderId;
  final String? razorpaySignature;
  final String? errorMessage;

  RazorpayCheckoutResult.success({
    required this.razorpayPaymentId,
    required this.razorpayOrderId,
    required this.razorpaySignature,
  })  : success = true,
        errorMessage = null;

  RazorpayCheckoutResult.failure(this.errorMessage)
      : success = false,
        razorpayPaymentId = null,
        razorpayOrderId = null,
        razorpaySignature = null;
}
