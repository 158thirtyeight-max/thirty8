import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../bus_ops/route_summary.dart';
import 'bus_navigation.dart';
import 'fleet_status.dart';
import 'bus_status_card.dart';
import 'fleet_providers.dart';
import 'stage_basic_screen.dart';

/// My Buses / Fleet. Bus management is unlocked only for an approved operator
/// (the server enforces this in create_bus as well).
class MyBusesScreen extends ConsumerWidget {
  const MyBusesScreen({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busesAsync = ref.watch(busesProvider(context.operatorId));

    /// After a bus is registered, offer the next logical step instead of dropping the operator on the list.
    Future<void> offerConfigureRoute(String busId) async {
      final bus = await ref.read(busProvider(busId).future);
      if (!buildContext.mounted) return;
      final go = await showModalBottomSheet<bool>(
        context: buildContext,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bus added', style: Theme.of(sheet).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                const Text('Next, configure its route so you can schedule trips.'),
                const SizedBox(height: AppSpacing.md),
                AppButton(label: 'Configure Route', expand: true, onPressed: () => Navigator.pop(sheet, true)),
                const SizedBox(height: AppSpacing.xs),
                AppButton(label: 'Later', expand: true, variant: AppButtonVariant.ghost, onPressed: () => Navigator.pop(sheet, false)),
              ],
            ),
          ),
        ),
      );
      if (go == true && buildContext.mounted) {
        await openBusAction(buildContext, operatorId: context.operatorId, bus: bus, action: BusAction.configureRoute);
        ref.invalidate(busesProvider(context.operatorId));
        ref.invalidate(operatorRouteSummariesProvider(context.operatorId));
      }
    }

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(busesProvider(context.operatorId)),
        child: busesAsync.when(
          data: (buses) => buses.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    AppEmptyState(message: 'No buses yet — add your first bus.', icon: Icons.directions_bus_outlined),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: buses.length,
                  itemBuilder: (c, i) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: BusStatusCard(
                      operatorId: context.operatorId,
                      operatorContext: context,
                      bus: buses[i],
                      onChanged: () => ref.invalidate(busesProvider(context.operatorId)),
                    ),
                  ),
                ),
          loading: () => const AppLoadingState(),
          error: (e, st) => AppErrorState(
            message: 'Could not load your fleet.',
            onRetry: () => ref.invalidate(busesProvider(context.operatorId)),
          ),
        ),
      ),
      floatingActionButton: context.isApproved
          ? FloatingActionButton.extended(
              onPressed: () async {
                final busId = await Navigator.of(buildContext).push<String>(
                  MaterialPageRoute(builder: (_) => StageBasicScreen(operatorId: context.operatorId)),
                );
                ref.invalidate(busesProvider(context.operatorId));
                if (busId != null) await offerConfigureRoute(busId);
              },
              icon: const Icon(Icons.add),
              label: const Text('Add New Bus'),
            )
          : null,
    );
  }
}
