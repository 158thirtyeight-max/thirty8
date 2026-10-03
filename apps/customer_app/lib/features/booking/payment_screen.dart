import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';
import 'payment_outcome.dart';
import 'razorpay_gateway.dart';

/// Generic payment screen shared by the bus booking and cargo shipment
/// flows. [description] appears in the Razorpay checkout sheet;
/// [onSuccess] builds whichever confirmation screen the caller wants
/// pushed once payment is verified.
///
/// Safety rules:
///  * the ticket is confirmed ONLY by the backend (verify-payment), never by the checkout callback;
///  * after the customer has paid, the screen never offers "Pay" again: it only re-checks (idempotent) until the backend
///    answers, so a slow network or a closed app cannot lead to a double charge;
///  * leaving and coming back (also after an app restart) is safe: the booking screen offers "Complete payment" only
///    while the order is still payable, and the webhook confirms the booking even if this screen was closed.
class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({
    super.key,
    required this.orderReference,
    required this.amountCents,
    required this.description,
    required this.onSuccess,
    this.contactEmail,
    this.contactPhone,
  });

  final String orderReference;
  final int amountCents;
  final String description;
  final WidgetBuilder onSuccess;
  final String? contactEmail;
  final String? contactPhone;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

enum _Phase { preparing, ready, paying, verifying, processing, notApplied, notPayable }

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  _Phase _phase = _Phase.preparing;
  String? _error;
  String? _info;
  Map<String, dynamic>? _razorpayOrder;
  RazorpayCheckoutResult? _paid; // set once Razorpay says the customer paid: from then on we only verify
  Timer? _recheck;
  int _autoChecks = 0;
  bool _verifyInFlight = false;

  @override
  void initState() {
    super.initState();
    _createOrder();
  }

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }

  Future<void> _createOrder() async {
    setState(() {
      _phase = _Phase.preparing;
      _error = null;
    });
    try {
      final res = await ref.read(supabaseProvider).functions.invoke('create-order', body: {'order_reference': widget.orderReference});
      if (!mounted) return;
      setState(() {
        _razorpayOrder = Map<String, dynamic>.from(res.data as Map);
        _phase = _Phase.ready;
      });
    } on FunctionException catch (e) {
      if (!mounted) return;
      final details = e.details;
      final message = details is Map && details['error'] is String ? details['error'] as String : null;
      final notPayable = orderNotPayableMessage(message);
      setState(() {
        if (notPayable != null) {
          _info = notPayable;
          _phase = _Phase.notPayable;
        } else {
          _error = message ?? 'Failed to create the payment order. Please try again.';
          _phase = _Phase.preparing;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Failed to create the payment order. Check your connection and try again.');
    }
  }

  Future<void> _pay() async {
    final order = _razorpayOrder;
    // never start a second checkout: not while one is open, and not once a payment was made on this order
    if (order == null || _phase != _Phase.ready || _paid != null) return;
    setState(() {
      _phase = _Phase.paying;
      _error = null;
    });

    final result = await openRazorpayCheckout(
      keyId: order['key_id'] as String,
      amountCents: order['amount'] as int,
      razorpayOrderId: order['razorpay_order_id'] as String,
      name: 'Thirty8',
      description: widget.description,
      prefillEmail: widget.contactEmail,
      prefillContact: widget.contactPhone,
    );

    if (!mounted) return;
    if (!result.success) {
      // cancelled or failed inside checkout: nothing was charged for this attempt; the same order can be retried
      setState(() {
        _phase = _Phase.ready;
        _error = result.errorMessage;
      });
      return;
    }
    _paid = result;
    await _verify();
  }

  /// Asks the backend what really happened. Safe to call repeatedly: confirmation is idempotent server-side.
  Future<void> _verify() async {
    final paid = _paid;
    if (paid == null || _verifyInFlight) return;
    _verifyInFlight = true;
    _recheck?.cancel();
    setState(() {
      _phase = _Phase.verifying;
      _error = null;
    });

    PaymentOutcome outcome;
    try {
      final res = await ref.read(supabaseProvider).functions.invoke('verify-payment', body: {
        'order_reference': widget.orderReference,
        'razorpay_order_id': paid.razorpayOrderId,
        'razorpay_payment_id': paid.razorpayPaymentId,
        'razorpay_signature': paid.razorpaySignature,
      });
      outcome = interpretVerifyResponse(res.status, res.data);
    } on FunctionException catch (e) {
      outcome = interpretVerifyResponse(e.status, e.details);
    } catch (_) {
      outcome = PaymentOutcome.unreachable;
    } finally {
      _verifyInFlight = false;
    }
    if (!mounted) return;

    switch (outcome) {
      case PaymentOutcome.confirmed:
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: widget.onSuccess));
      case PaymentOutcome.processing:
      case PaymentOutcome.unreachable:
        setState(() {
          _phase = _Phase.processing;
          _info = paymentOutcomeMessage(outcome);
        });
        if (_autoChecks < 4) {
          _autoChecks++;
          _recheck = Timer(const Duration(seconds: 4), _verify);
        }
      case PaymentOutcome.notApplied:
        setState(() {
          _phase = _Phase.notApplied;
          _info = paymentOutcomeMessage(outcome);
        });
      case PaymentOutcome.failed:
        _paid = null; // the attempt failed: a new attempt on the same order is allowed
        setState(() {
          _phase = _Phase.ready;
          _error = paymentOutcomeMessage(outcome);
        });
      case PaymentOutcome.rejected:
        setState(() {
          _phase = _Phase.processing;
          _info = paymentOutcomeMessage(outcome);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget body;
    switch (_phase) {
      case _Phase.preparing:
        body = _error != null ? AppErrorState(message: _error!, onRetry: _createOrder) : const AppLoadingState(message: 'Preparing your payment…');
      case _Phase.ready:
      case _Phase.paying:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          if (_error != null)
            Padding(padding: const EdgeInsets.only(bottom: 16), child: Text(_error!, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.error))),
          AppButton(label: 'Pay now', loading: _phase == _Phase.paying, onPressed: _phase == _Phase.paying ? null : _pay),
        ]);
      case _Phase.verifying:
        body = const AppLoadingState(message: 'Confirming your payment…');
      case _Phase.processing:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hourglass_top, size: 48, color: AppColors.warning),
          const SizedBox(height: 12),
          Text(_info ?? '', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          AppButton(label: 'Check again', onPressed: _verifyInFlight ? null : _verify),
          const SizedBox(height: 8),
          AppButton(label: 'Back to my trips', variant: AppButtonVariant.outline, onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst)),
        ]);
      case _Phase.notApplied:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.info_outline, size: 48, color: AppColors.warning),
          const SizedBox(height: 12),
          Text(_info ?? '', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          AppButton(label: 'Back to home', onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst)),
        ]);
      case _Phase.notPayable:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.info_outline, size: 48, color: AppColors.textTertiary),
          const SizedBox(height: 12),
          Text(_info ?? '', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          AppButton(label: 'Back to home', onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst)),
        ]);
    }

    // while a payment may be in flight, leaving would hide the result: keep the customer on this screen
    final inFlight = _phase == _Phase.paying || _phase == _Phase.verifying;
    return PopScope(
      canPop: !inFlight,
      child: Scaffold(
        appBar: AppBar(title: const Text('Payment')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Total amount', style: theme.textTheme.bodyMedium),
                Text('₹${(widget.amountCents / 100).toStringAsFixed(widget.amountCents % 100 == 0 ? 0 : 2)}', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 32),
                body,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
