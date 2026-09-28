// Platform-specific Razorpay checkout. razorpay_flutter only supports
// Android/iOS (no web plugin implementation), so the real implementation
// is conditionally imported and never touched when compiling for web —
// otherwise the web build breaks on an unsupported plugin.
export 'razorpay_result.dart';
export 'razorpay_gateway_io.dart' if (dart.library.html) 'razorpay_gateway_web.dart';
