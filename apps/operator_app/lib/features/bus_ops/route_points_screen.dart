import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

final boardingPointsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, routeId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('boarding_points').select().eq('route_id', routeId).order('sequence_no');
});

final droppingPointsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, routeId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('dropping_points').select().eq('route_id', routeId).order('sequence_no');
});

/// Manages boarding & dropping points for one route — customers pick from
/// these when booking a trip on this route.
class RoutePointsScreen extends ConsumerWidget {
  const RoutePointsScreen({super.key, required this.routeId, required this.routeLabel});

  final String routeId;
  final String routeLabel;

  Future<void> _addPoint(BuildContext context, WidgetRef ref, {required bool isBoarding}) async {
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isBoarding ? 'Add boarding point' : 'Add dropping point'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            TextField(controller: addressController, decoration: const InputDecoration(labelText: 'Address (optional)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (nameController.text.trim().isEmpty) return;
              final table = isBoarding ? 'boarding_points' : 'dropping_points';
              final existing = await ref.read(supabaseProvider).from(table).select('id').eq('route_id', routeId).count();
              await ref.read(supabaseProvider).from(table).insert({
                'route_id': routeId,
                'name': nameController.text.trim(),
                'address': addressController.text.trim().isEmpty ? null : addressController.text.trim(),
                'sequence_no': existing.count + 1,
              });
              if (dialogContext.mounted) Navigator.pop(dialogContext, true);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (saved == true) {
      if (isBoarding) {
        ref.invalidate(boardingPointsProvider(routeId));
      } else {
        ref.invalidate(droppingPointsProvider(routeId));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boardingAsync = ref.watch(boardingPointsProvider(routeId));
    final droppingAsync = ref.watch(droppingPointsProvider(routeId));

    return Scaffold(
      appBar: AppBar(title: Text(routeLabel)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Boarding points', style: Theme.of(context).textTheme.titleMedium),
              IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => _addPoint(context, ref, isBoarding: true)),
            ],
          ),
          boardingAsync.when(
            data: (points) => points.isEmpty
                ? const Padding(padding: EdgeInsets.all(8), child: Text('None yet'))
                : Column(children: points.map((p) => ListTile(leading: const Icon(Icons.pin_drop_outlined), title: Text(p['name'] as String), subtitle: p['address'] != null ? Text(p['address'] as String) : null)).toList()),
            loading: () => const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
            error: (e, st) => Text('Error: $e'),
          ),
          const Divider(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Dropping points', style: Theme.of(context).textTheme.titleMedium),
              IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => _addPoint(context, ref, isBoarding: false)),
            ],
          ),
          droppingAsync.when(
            data: (points) => points.isEmpty
                ? const Padding(padding: EdgeInsets.all(8), child: Text('None yet'))
                : Column(children: points.map((p) => ListTile(leading: const Icon(Icons.pin_drop_outlined), title: Text(p['name'] as String), subtitle: p['address'] != null ? Text(p['address'] as String) : null)).toList()),
            loading: () => const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
            error: (e, st) => Text('Error: $e'),
          ),
        ],
      ),
    );
  }
}
