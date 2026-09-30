import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import 'bus_setup_screen.dart';
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

    Future<void> openSetup(String busId) async {
      await Navigator.of(buildContext).push(
        MaterialPageRoute(builder: (_) => BusSetupScreen(operatorId: context.operatorId, busId: busId)),
      );
      ref.invalidate(busesProvider(context.operatorId));
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
                if (busId != null) await openSetup(busId);
              },
              icon: const Icon(Icons.add),
              label: const Text('Add New Bus'),
            )
          : null,
    );
  }
}
