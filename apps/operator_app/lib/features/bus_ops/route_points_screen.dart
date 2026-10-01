import 'package:design_system/design_system.dart';
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

/// Read-only view of the boarding & dropping points of one route — customers pick
/// from these when booking. Points are edited in the bus setup (Fleet → bus → Route).
class RoutePointsScreen extends ConsumerWidget {
  const RoutePointsScreen({super.key, required this.routeId, required this.routeLabel});

  final String routeId;
  final String routeLabel;

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
            ],
          ),
          boardingAsync.when(
            data: (points) => points.isEmpty
                ? const Padding(padding: EdgeInsets.all(8), child: Text('None yet'))
                : Column(children: points.map((p) => AppListItem(leading: const Icon(Icons.pin_drop_outlined), title: p['name'] as String, subtitle: p['address'] as String?)).toList()),
            loading: () => const Padding(padding: EdgeInsets.all(16), child: AppLoadingState()),
            error: (e, st) => Text('Error: $e'),
          ),
          const Divider(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Dropping points', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          droppingAsync.when(
            data: (points) => points.isEmpty
                ? const Padding(padding: EdgeInsets.all(8), child: Text('None yet'))
                : Column(children: points.map((p) => AppListItem(leading: const Icon(Icons.pin_drop_outlined), title: p['name'] as String, subtitle: p['address'] as String?)).toList()),
            loading: () => const Padding(padding: EdgeInsets.all(16), child: AppLoadingState()),
            error: (e, st) => Text('Error: $e'),
          ),
        ],
      ),
    );
  }
}
