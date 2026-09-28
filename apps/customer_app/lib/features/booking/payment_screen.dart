import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';
import 'razorpay_gateway.dart';

/// Generic payment screen shared by the bus booking and cargo shipment
/// flows. [description] appears in the Razorpay checkout sheet;
/// [onSuccess] builds whichever confirmation screen the caller wants
/// pushed once payment is verified.
class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({
    super.key,
    required this.orderReference,
    required this.amountCents,
    required this.description,
    required this.onSuccess,
  });

  final String orderReference;
  final int amountCents;
  final String description;
  final WidgetBuilder onSuccess;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  bool _creatingOrder = true;
  bool _paying = false;
  String? _error;
  Map<String, dynamic>? _razorpayOrder;

  @override
  void initState() {
    super.initState();
    _createOrder();
  }

  Future<void> _createOrder() async {
    setState(() {
      _creatingOrder = true;
      _error = null;
    });
    try {
      final res = await ref.read(supabaseProvider).functions.invoke(
        'create-order',
        body: {'order_reference': widget.orderReference},
      );
      if (!mounted) return;
      setState(() {
        _razorpayOrder = Map<String, dynamic>.from(res.data as Map);
        _creatingOrder = false;
      });
    } on FunctionException catch (e) {
      if (!mounted) return;
      final details = e.details;
      final message = details is Map && details['error'] is String ? details['error'] as String : e.reasonPhrase ?? 'Failed to create payment order';
      setState(() {
        _error = message;
        _creatingOrder = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to create payment order. Please try again.';
        _creatingOrder = false;
      });
    }
  }

  Future<void> _pay() async {
    final order = _razorpayOrder;
    if (order == null) return;
    setState(() => _paying = true);

    final result = await openRazorpayCheckout(
      keyId: order['key_id'] as String,
      amountCents: order['amount'] as int,
      razorpayOrderId: order['razorpay_order_id'] as String,
      name: 'Thirty8',
      description: widget.description,
    );

    if (!result.success) {
      if (!mounted) return;
      setState(() {
        _paying = false;
        _error = result.errorMessage;
      });
      return;
    }

    try {
      final res = await ref.read(supabaseProvider).functions.invoke('verify-payment', body: {
        'order_reference': widget.orderReference,
        'razorpay_order_id': result.razorpayOrderId,
        'razorpay_payment_id': result.razorpayPaymentId,
        'razorpay_signature': result.razorpaySignature,
      });
      if (res.status != 200 || (res.data as Map)['ok'] != true) {
        throw Exception('Payment could not be verified');
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: widget.onSuccess),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _paying = false;
        _error = 'Payment succeeded but could not be confirmed. Check My Trips shortly, or contact support.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Total amount', style: Theme.of(context).textTheme.bodyMedium),
              Text(
                '₹${(widget.amountCents / 100).toStringAsFixed(0)}',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 32),
              if (_creatingOrder) const AppLoadingState(),
              if (_error != null)
                AppErrorState(message: _error!, onRetry: _createOrder)
              else if (!_creatingOrder && _razorpayOrder != null)
                AppButton(
                  label: 'Pay now',
                  loading: _paying,
                  onPressed: _paying ? null : _pay,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
