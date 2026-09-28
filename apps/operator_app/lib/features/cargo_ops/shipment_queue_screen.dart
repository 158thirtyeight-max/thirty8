import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'cargo_vehicles_screen.dart';
import 'shipment_detail_screen.dart';

final shipmentQueueProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase
      .from('cargo_shipments')
      .select()
      .eq('operator_id', operatorId)
      .inFilter('status', ['confirmed', 'picked_up', 'in_transit', 'arrived_at_hub', 'out_for_delivery'])
      .order('created_at', ascending: false);
});

class ShipmentQueueScreen extends ConsumerWidget {
  const ShipmentQueueScreen({super.key, required this.context});

  final OperatorContext context;

  Future<void> _accept(BuildContext buildContext, WidgetRef ref, String shipmentId) async {
    final vehicles = await ref.read(cargoVehiclesProvider(context.operatorId).future);
    if (vehicles.isEmpty) {
      if (buildContext.mounted) {
        ScaffoldMessenger.of(buildContext).showSnackBar(const SnackBar(content: Text('Add a vehicle before accepting shipments')));
      }
      return;
    }
    if (!buildContext.mounted) return;
    String selectedVehicle = vehicles.first['id'] as String;
    final confirmed = await showDialog<bool>(
      context: buildContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Accept shipment'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedVehicle,
            decoration: const InputDecoration(labelText: 'Assign vehicle'),
            items: vehicles.map((v) => DropdownMenuItem(value: v['id'] as String, child: Text(v['registration_number'] as String))).toList(),
            onChanged: (v) => setDialogState(() => selectedVehicle = v!),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Accept')),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(supabaseProvider).rpc('accept_cargo_shipment', params: {'p_shipment_id': shipmentId, 'p_vehicle_id': selectedVehicle});
      ref.invalidate(shipmentQueueProvider(context.operatorId));
    } catch (e) {
      if (buildContext.mounted) {
        ScaffoldMessenger.of(buildContext).showSnackBar(SnackBar(content: Text('Could not accept: $e')));
      }
    }
  }

  Future<void> _reject(BuildContext buildContext, WidgetRef ref, String shipmentId) async {
    try {
      await ref.read(supabaseProvider).rpc('reject_cargo_shipment', params: {'p_shipment_id': shipmentId, 'p_reason': 'Operator declined'});
      ref.invalidate(shipmentQueueProvider(context.operatorId));
    } catch (e) {
      if (buildContext.mounted) {
        ScaffoldMessenger.of(buildContext).showSnackBar(SnackBar(content: Text('Could not reject: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final shipmentsAsync = ref.watch(shipmentQueueProvider(context.operatorId));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(shipmentQueueProvider(context.operatorId)),
        child: shipmentsAsync.when(
          data: (shipments) => shipments.isEmpty
              ? ListView(children: const [
                  Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No active shipments right now.'))),
                ])
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: shipments.length,
                  itemBuilder: (c, i) {
                    final s = shipments[i];
                    // status stays 'confirmed' through acceptance — vehicle_id
                    // (set by accept_cargo_shipment) is what actually marks a
                    // shipment as accepted and ready for pickup.
                    final awaitingAcceptance = s['status'] == 'confirmed' && s['vehicle_id'] == null;
                    final displayStatus = awaitingAcceptance ? 'awaiting acceptance' : s['status'] as String;
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.inventory_2_outlined),
                        title: Text(s['shipment_reference'] as String),
                        subtitle: Text('${s['weight_kg']} kg · $displayStatus · ₹${((s['total_fare_cents'] as int) / 100).toStringAsFixed(0)}'),
                        trailing: awaitingAcceptance
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(icon: const Icon(Icons.close, color: Colors.red), onPressed: () => _reject(buildContext, ref, s['id'] as String)),
                                  IconButton(icon: const Icon(Icons.check, color: Colors.green), onPressed: () => _accept(buildContext, ref, s['id'] as String)),
                                ],
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: awaitingAcceptance
                            ? null
                            : () => Navigator.of(buildContext).push(
                                  MaterialPageRoute(builder: (_) => ShipmentDetailScreen(shipmentId: s['id'] as String, operatorId: context.operatorId)),
                                ),
                      ),
                    );
                  },
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, st) => Center(child: Text('Could not load shipments: $e')),
        ),
      ),
    );
  }
}
