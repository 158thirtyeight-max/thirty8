import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';

final cargoVehiclesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase
      .from('cargo_vehicles')
      .select('*, vehicle_type:cargo_vehicle_types(name)')
      .eq('operator_id', operatorId)
      .order('created_at', ascending: false);
});

final cargoVehicleTypesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('cargo_vehicle_types').select().order('name');
});

class CargoVehiclesScreen extends ConsumerWidget {
  const CargoVehiclesScreen({super.key, required this.context});

  final OperatorContext context;

  Future<void> _addVehicle(BuildContext buildContext, WidgetRef ref) async {
    final types = await ref.read(cargoVehicleTypesProvider.future);
    if (types.isEmpty) {
      if (buildContext.mounted) {
        ScaffoldMessenger.of(buildContext).showSnackBar(const SnackBar(content: Text('No cargo vehicle types configured yet')));
      }
      return;
    }
    if (!buildContext.mounted) return;
    final regController = TextEditingController();
    String selectedType = types.first['id'] as String;

    final saved = await showDialog<bool>(
      context: buildContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Add vehicle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: regController, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Registration number')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: selectedType,
                decoration: const InputDecoration(labelText: 'Vehicle type'),
                items: types.map((t) => DropdownMenuItem(value: t['id'] as String, child: Text(t['name'] as String))).toList(),
                onChanged: (v) => setDialogState(() => selectedType = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (regController.text.trim().isEmpty) return;
                await ref.read(supabaseProvider).from('cargo_vehicles').insert({
                  'operator_id': context.operatorId,
                  'vehicle_type_id': selectedType,
                  'registration_number': regController.text.trim().toUpperCase(),
                });
                if (dialogContext.mounted) Navigator.pop(dialogContext, true);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) ref.invalidate(cargoVehiclesProvider(context.operatorId));
  }

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final vehiclesAsync = ref.watch(cargoVehiclesProvider(context.operatorId));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(cargoVehiclesProvider(context.operatorId)),
        child: vehiclesAsync.when(
          data: (vehicles) => vehicles.isEmpty
              ? ListView(children: const [
                  Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No vehicles yet — add your first vehicle.'))),
                ])
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: vehicles.length,
                  itemBuilder: (c, i) {
                    final v = vehicles[i];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.local_shipping_outlined),
                        title: Text(v['registration_number'] as String),
                        subtitle: Text('${v['vehicle_type']?['name'] ?? '?'} · ${v['status']}'),
                      ),
                    );
                  },
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, st) => Center(child: Text('Could not load vehicles: $e')),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addVehicle(buildContext, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add vehicle'),
      ),
    );
  }
}
