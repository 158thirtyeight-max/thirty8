import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';

final dashboardStatsProvider = FutureProvider.autoDispose.family<Map<String, int>, OperatorContext>((ref, ctx) async {
  final supabase = ref.watch(supabaseProvider);
  final stats = <String, int>{};

  if (ctx.servesBus) {
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day).toIso8601String();
    final todayEnd = DateTime(today.year, today.month, today.day + 1).toIso8601String();

    final todaysTrips = await supabase
        .from('bus_trips')
        .select('id')
        .eq('operator_id', ctx.operatorId)
        .gte('departure_at', todayStart)
        .lt('departure_at', todayEnd)
        .count();
    stats['todaysTrips'] = todaysTrips.count;

    final busCount = await supabase.from('buses').select('id').eq('operator_id', ctx.operatorId).count();
    stats['buses'] = busCount.count;
  }

  if (ctx.servesCargo) {
    final pending = await supabase
        .from('cargo_shipments')
        .select('id')
        .eq('operator_id', ctx.operatorId)
        .eq('status', 'confirmed')
        .count();
    stats['pendingShipments'] = pending.count;

    final inTransit = await supabase
        .from('cargo_shipments')
        .select('id')
        .eq('operator_id', ctx.operatorId)
        .inFilter('status', ['picked_up', 'in_transit', 'arrived_at_hub', 'out_for_delivery']).count();
    stats['inTransitShipments'] = inTransit.count;
  }

  return stats;
});

class DashboardTab extends ConsumerWidget {
  const DashboardTab({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final statsAsync = ref.watch(dashboardStatsProvider(context));
    final op = context.operator;

    return Scaffold(
      appBar: AppBar(title: Text(op['name'] as String? ?? 'Dashboard')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(dashboardStatsProvider(context)),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (op['status'] != 'approved')
              Card(
                color: Theme.of(buildContext).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Operator status: ${op['status']}', style: TextStyle(color: Theme.of(buildContext).colorScheme.onErrorContainer)),
                ),
              ),
            const SizedBox(height: 8),
            statsAsync.when(
              data: (stats) => GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.1,
                children: [
                  if (context.servesBus) ...[
                    AppStatCard(label: "Today's trips", value: '${stats['todaysTrips'] ?? 0}', icon: Icons.today),
                    AppStatCard(label: 'Buses in fleet', value: '${stats['buses'] ?? 0}', icon: Icons.directions_bus),
                  ],
                  if (context.servesCargo) ...[
                    AppStatCard(label: 'Awaiting acceptance', value: '${stats['pendingShipments'] ?? 0}', icon: Icons.inbox),
                    AppStatCard(label: 'In transit', value: '${stats['inTransitShipments'] ?? 0}', icon: Icons.local_shipping),
                  ],
                ],
              ),
              loading: () => const Padding(padding: EdgeInsets.only(top: 32), child: Center(child: CircularProgressIndicator())),
              error: (e, st) => Padding(padding: const EdgeInsets.only(top: 32), child: Text('Could not load stats: $e')),
            ),
          ],
        ),
      ),
    );
  }
}
