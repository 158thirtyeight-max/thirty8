import 'dart:io';

import 'package:design_system/design_system.dart';
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
        content: AppTextField(controller: nameController, label: 'Who received it?'),
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
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(s['shipment_reference'] as String, style: Theme.of(context).textTheme.titleLarge)),
                        AppBadge(status: status),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Weight: ${s['weight_kg']} kg'),
                    Text('Total fare: ₹${((s['total_fare_cents'] as int) / 100).toStringAsFixed(0)}'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AppCard(
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
              const SizedBox(height: 24),
              if (_busy)
                const AppLoadingState()
              else ...[
                if (status == 'confirmed')
                  AppButton(label: 'Confirm pickup (photo)', icon: Icons.camera_alt, onPressed: _confirmPickup, expand: true),
                if (status == 'picked_up')
                  AppButton(label: 'Mark in transit', onPressed: () => _advanceStatus('in_transit'), expand: true),
                if (status == 'in_transit')
                  AppButton(label: 'Mark arrived at hub', onPressed: () => _advanceStatus('arrived_at_hub'), expand: true),
                if (status == 'arrived_at_hub')
                  AppButton(label: 'Mark out for delivery', onPressed: () => _advanceStatus('out_for_delivery'), expand: true),
                if (status == 'out_for_delivery')
                  AppButton(label: 'Confirm delivery (photo)', icon: Icons.camera_alt, onPressed: _confirmDelivery, expand: true),
              ],
            ],
          );
        },
        loading: () => const AppLoadingState(),
        error: (e, st) => AppErrorState(
          message: 'Could not load shipment: $e',
          onRetry: () => ref.invalidate(shipmentProvider(widget.shipmentId)),
        ),
      ),
    );
  }
}
