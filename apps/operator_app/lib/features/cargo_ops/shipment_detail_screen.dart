import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/supabase_providers.dart';

final shipmentProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, shipmentId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('cargo_shipments').select().eq('id', shipmentId).single();
});

/// Status handling: picked_up/delivered require photo proof (via the
/// dedicated confirm_cargo_pickup/confirm_cargo_delivery RPCs which also
/// advance status); the transit-only statuses in between use the generic
/// update_cargo_status RPC.
class ShipmentDetailScreen extends ConsumerStatefulWidget {
  const ShipmentDetailScreen({super.key, required this.shipmentId, required this.operatorId});

  final String shipmentId;
  final String operatorId;

  @override
  ConsumerState<ShipmentDetailScreen> createState() => _ShipmentDetailScreenState();
}

class _ShipmentDetailScreenState extends ConsumerState<ShipmentDetailScreen> {
  bool _busy = false;

  Future<String?> _uploadProof(String suffix) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 70);
    if (picked == null) return null;
    final path = '${widget.shipmentId}/${suffix}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await ref.read(supabaseProvider).storage.from('cargo-proofs').upload(path, File(picked.path));
    return path;
  }

  Future<void> _confirmPickup() async {
    setState(() => _busy = true);
    try {
      final proofPath = await _uploadProof('pickup');
      if (proofPath == null) return;
      await ref.read(supabaseProvider).rpc('confirm_cargo_pickup', params: {'p_shipment_id': widget.shipmentId, 'p_proof_url': proofPath});
      ref.invalidate(shipmentProvider(widget.shipmentId));
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelivery() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Recipient name'),
        content: TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Who received it?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, nameController.text.trim()), child: const Text('Continue')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    setState(() => _busy = true);
    try {
      final proofPath = await _uploadProof('delivery');
      if (proofPath == null) return;
      await ref.read(supabaseProvider).rpc('confirm_cargo_delivery', params: {
        'p_shipment_id': widget.shipmentId,
        'p_proof_url': proofPath,
        'p_recipient_name': name,
      });
      ref.invalidate(shipmentProvider(widget.shipmentId));
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _advanceStatus(String newStatus) async {
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc('update_cargo_status', params: {'p_shipment_id': widget.shipmentId, 'p_new_status': newStatus});
      ref.invalidate(shipmentProvider(widget.shipmentId));
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Action failed: $e')));
  }

  @override
  Widget build(BuildContext context) {
    final shipmentAsync = ref.watch(shipmentProvider(widget.shipmentId));

    return Scaffold(
      appBar: AppBar(title: const Text('Shipment')),
      body: shipmentAsync.when(
        data: (s) {
          final status = s['status'] as String;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s['shipment_reference'] as String, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text('Status: $status'),
                      Text('Weight: ${s['weight_kg']} kg'),
                      Text('Total fare: ₹${((s['total_fare_cents'] as int) / 100).toStringAsFixed(0)}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pickup', style: Theme.of(context).textTheme.titleSmall),
                      Text(s['pickup_address'] as String? ?? 'Hub pickup'),
                      Text('${s['pickup_contact_name']} · ${s['pickup_contact_phone']}'),
                      const Divider(height: 24),
                      Text('Delivery', style: Theme.of(context).textTheme.titleSmall),
                      Text(s['delivery_address'] as String? ?? 'Hub delivery'),
                      Text('${s['delivery_contact_name']} · ${s['delivery_contact_phone']}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_busy)
                const Center(child: CircularProgressIndicator())
              else ...[
                if (status == 'confirmed')
                  ElevatedButton.icon(icon: const Icon(Icons.camera_alt), onPressed: _confirmPickup, label: const Text('Confirm pickup (photo)')),
                if (status == 'picked_up')
                  ElevatedButton(onPressed: () => _advanceStatus('in_transit'), child: const Text('Mark in transit')),
                if (status == 'in_transit')
                  ElevatedButton(onPressed: () => _advanceStatus('arrived_at_hub'), child: const Text('Mark arrived at hub')),
                if (status == 'arrived_at_hub')
                  ElevatedButton(onPressed: () => _advanceStatus('out_for_delivery'), child: const Text('Mark out for delivery')),
                if (status == 'out_for_delivery')
                  ElevatedButton.icon(icon: const Icon(Icons.camera_alt), onPressed: _confirmDelivery, label: const Text('Confirm delivery (photo)')),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Could not load shipment: $e')),
      ),
    );
  }
}
