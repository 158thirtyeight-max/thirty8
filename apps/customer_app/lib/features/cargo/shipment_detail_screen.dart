import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'shipment_tracking_screen.dart';

class ShipmentDetailScreen extends ConsumerStatefulWidget {
  const ShipmentDetailScreen({super.key, required this.shipmentId});

  final String shipmentId;

  @override
  ConsumerState<ShipmentDetailScreen> createState() => _ShipmentDetailScreenState();
}

class _ShipmentDetailScreenState extends ConsumerState<ShipmentDetailScreen> {
  bool _loading = true;
  bool _cancelling = false;
  Map<String, dynamic>? _shipment;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(supabaseProvider).from('cargo_shipments').select().eq('id', widget.shipmentId).single();
      if (!mounted) return;
      setState(() {
        _shipment = res;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel shipment?'),
        content: const Text('Shipments can only be cancelled before pickup. A full refund will be initiated if already paid.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep shipment')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Cancel shipment')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _cancelling = true);
    try {
      await ref.read(supabaseProvider).rpc('cancel_shipment', params: {'p_shipment_id': widget.shipmentId, 'p_reason': 'Cancelled by customer'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Shipment cancelled')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not cancel this shipment')));
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_shipment == null) return const Scaffold(body: Center(child: Text('Shipment not found')));

    final shipment = _shipment!;
    final status = shipment['status'] as String;
    final canCancel = status == 'draft' || status == 'confirmed';
    final fare = ((shipment['total_fare_cents'] as int? ?? 0) / 100).toStringAsFixed(0);

    return Scaffold(
      appBar: AppBar(title: Text(shipment['shipment_reference'] as String)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Status', style: Theme.of(context).textTheme.bodyMedium),
                Text(status.replaceAll('_', ' ').toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total fare', style: Theme.of(context).textTheme.bodyMedium),
                Text('₹$fare'),
              ],
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pickup', style: Theme.of(context).textTheme.titleSmall),
                    Text(shipment['pickup_type'] == 'address' ? (shipment['pickup_address'] as String? ?? '') : 'Hub drop-off'),
                    const SizedBox(height: 12),
                    Text('Delivery', style: Theme.of(context).textTheme.titleSmall),
                    Text(shipment['delivery_type'] == 'address' ? (shipment['delivery_address'] as String? ?? '') : 'Hub pickup'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShipmentTrackingScreen(shipmentId: widget.shipmentId))),
              icon: const Icon(Icons.local_shipping_outlined),
              label: const Text('Track shipment'),
            ),
            if (canCancel) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _cancelling ? null : _cancel,
                style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                icon: _cancelling
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cancel_outlined),
                label: const Text('Cancel shipment'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
