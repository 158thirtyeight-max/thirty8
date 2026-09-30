import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import '../fleet/bus_status_card.dart';
import '../fleet/fleet_providers.dart';
import '../fleet/stage_basic_screen.dart';
import '../fleet/bus_setup_screen.dart';

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

/// "✓ Operator Approved" — the operator account state, separate from any bus.
class _OperatorStatusCard extends StatelessWidget {
  const _OperatorStatusCard({required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext) {
    final approved = context.isApproved;
    final theme = Theme.of(buildContext);
    return AppCard(
      child: Row(
        children: [
          Icon(approved ? Icons.verified : Icons.info_outline, color: approved ? AppColors.success : AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Operator Status', style: theme.textTheme.bodySmall),
                Text(approved ? '✓ Operator Approved' : 'Operator ${context.status}', style: theme.textTheme.titleSmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Fleet at a glance: how many buses, and for each its status and what is left to do.
class _FleetOverview extends ConsumerWidget {
  const _FleetOverview({required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busesAsync = ref.watch(busesProvider(context.operatorId));
    final theme = Theme.of(buildContext);

    return busesAsync.when(
      data: (buses) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Fleet', style: theme.textTheme.titleMedium)),
              Text('${buses.length} ${buses.length == 1 ? 'Bus' : 'Buses'}', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (buses.isEmpty)
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your operator account is approved. Add your first bus to start setting up routes, fares and schedules.'),
                  const SizedBox(height: AppSpacing.sm),
                  AppButton(
                    label: 'Add New Bus',
                    icon: Icons.add,
                    size: AppButtonSize.small,
                    onPressed: () async {
                      final busId = await Navigator.of(buildContext).push<String>(
                        MaterialPageRoute(builder: (_) => StageBasicScreen(operatorId: context.operatorId)),
                      );
                      ref.invalidate(busesProvider(context.operatorId));
                      if (busId != null && buildContext.mounted) {
                        await Navigator.of(buildContext).push(
                          MaterialPageRoute(builder: (_) => BusSetupScreen(operatorId: context.operatorId, busId: busId)),
                        );
                        ref.invalidate(busesProvider(context.operatorId));
                      }
                    },
                  ),
                ],
              ),
            )
          else
            for (final bus in buses)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: BusStatusCard(
                  operatorId: context.operatorId,
                  bus: bus,
                  compact: true,
                  onChanged: () => ref.invalidate(busesProvider(context.operatorId)),
                ),
              ),
        ],
      ),
      loading: () => const Padding(padding: EdgeInsets.all(AppSpacing.md), child: Center(child: CircularProgressIndicator())),
      error: (e, st) => const Text('Could not load your fleet.'),
    );
  }
}

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
        onRefresh: () async {
          ref.invalidate(dashboardStatsProvider(context));
          ref.invalidate(busesProvider(context.operatorId));
        },
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
            _OperatorStatusCard(context: context),
            if (context.servesBus) ...[
              const SizedBox(height: AppSpacing.md),
              _FleetOverview(context: context),
            ],
            const SizedBox(height: AppSpacing.md),
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
