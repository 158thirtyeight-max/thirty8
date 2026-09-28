import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import '../booking/payment_screen.dart';
import 'shipment_confirmation_screen.dart';

class ShipmentQuoteScreen extends ConsumerStatefulWidget {
  const ShipmentQuoteScreen({
    super.key,
    required this.sourceCityId,
    required this.destinationCityId,
    required this.cargoTypeId,
    required this.weightKg,
    required this.shipment,
  });

  final String sourceCityId;
  final String destinationCityId;
  final String cargoTypeId;
  final double weightKg;
  final Map<String, dynamic> shipment;

  @override
  ConsumerState<ShipmentQuoteScreen> createState() => _ShipmentQuoteScreenState();
}

class _ShipmentQuoteScreenState extends ConsumerState<ShipmentQuoteScreen> {
  bool _loading = true;
  bool _confirming = false;
  String? _error;
  Map<String, dynamic>? _quote;

  @override
  void initState() {
    super.initState();
    _loadQuote();
  }

  Future<void> _loadQuote() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref.read(supabaseProvider).rpc('get_cargo_quote', params: {
        'p_source_city_id': widget.sourceCityId,
        'p_destination_city_id': widget.destinationCityId,
        'p_cargo_type_id': widget.cargoTypeId,
        'p_weight_kg': widget.weightKg,
      });
      if (!mounted) return;
      setState(() {
        _quote = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No operator currently serves this route for your package. Please try a different route or weight.';
        _loading = false;
      });
    }
  }

  Future<void> _confirmAndPay() async {
    setState(() => _confirming = true);
    try {
      final res = await ref.read(supabaseProvider).rpc('create_shipment', params: {'p_shipment': widget.shipment});
      if (!mounted) return;
      final shipment = Map<String, dynamic>.from(res as Map);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PaymentScreen(
            orderReference: shipment['order_reference'] as String,
            amountCents: shipment['amount_cents'] as int,
            description: 'Shipment ${shipment['shipment_reference']}',
            onSuccess: (_) => ShipmentConfirmationScreen(shipmentReference: shipment['shipment_reference'] as String),
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not create the shipment. Please try again.')));
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Price quote')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _QuoteRow('Distance', '${_quote!['distance_km']} km'),
                              _QuoteRow('Base fare', '₹${(_quote!['base_fare_cents'] / 100).toStringAsFixed(0)}'),
                              _QuoteRow('Distance charge', '₹${(_quote!['distance_fare_cents'] / 100).toStringAsFixed(0)}'),
                              _QuoteRow('Weight charge', '₹${(_quote!['weight_fare_cents'] / 100).toStringAsFixed(0)}'),
                              if ((_quote!['surcharge_cents'] as int) > 0)
                                _QuoteRow('Surcharge', '₹${(_quote!['surcharge_cents'] / 100).toStringAsFixed(0)}'),
                              const Divider(),
                              _QuoteRow(
                                'Total',
                                '₹${((_quote!['total_fare_cents'] as int) / 100).toStringAsFixed(0)}',
                                bold: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _confirming ? null : _confirmAndPay,
                        child: _confirming
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Confirm & pay'),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _QuoteRow extends StatelessWidget {
  const _QuoteRow(this.label, this.value, {this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 18 : 14);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label, style: style), Text(value, style: style)],
      ),
    );
  }
}
