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
                    _StatCard(label: "Today's trips", value: stats['todaysTrips'] ?? 0, icon: Icons.today),
                    _StatCard(label: 'Buses in fleet', value: stats['buses'] ?? 0, icon: Icons.directions_bus),
                  ],
                  if (context.servesCargo) ...[
                    _StatCard(label: 'Awaiting acceptance', value: stats['pendingShipments'] ?? 0, icon: Icons.inbox),
                    _StatCard(label: 'In transit', value: stats['inTransitShipments'] ?? 0, icon: Icons.local_shipping),
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

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.icon});

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 6),
            Text('$value', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text(label, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
