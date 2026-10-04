import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bus_validators.dart';
import 'fleet_providers.dart';
import 'fleet_status.dart';
import 'rejected_documents_banner.dart';
import 'setup_continue.dart';
import 'stage_basic_screen.dart';
import 'stage_documents_screen.dart';
import 'stage_fare_screen.dart';
import 'stage_review_screen.dart';
import 'route_revision_screen.dart';
import 'stage_schedule_screen.dart';
import 'stage_seat_layout_screen.dart';

/// One stage of bus setup (A-G). New stages are added here as they are built,
/// so the hub always lists the full journey and each stage saves on its own —
/// the operator can leave and return without losing progress.
class BusSetupStage {
  const BusSetupStage({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
    this.section,
  });

  /// Checklist section (fleet_status.busSections) this stage completes, if any.
  final String? section;

  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget Function(BuildContext context, String operatorId, Map<String, dynamic> bus) builder;
}

final List<BusSetupStage> busSetupStages = [
  BusSetupStage(
    key: 'basic',
    section: 'basic',
    title: 'A · Basic information',
    subtitle: 'Name, registration, make/model, type, capacity, photos',
    icon: Icons.directions_bus_outlined,
    builder: (context, operatorId, bus) => StageBasicScreen(operatorId: operatorId, bus: bus),
  ),
  BusSetupStage(
    key: 'documents',
    section: 'documents',
    title: 'B · Vehicle documents',
    subtitle: 'RC, insurance, fitness, permit, PUC and more',
    icon: Icons.description_outlined,
    builder: (context, operatorId, bus) => StageDocumentsScreen(operatorId: operatorId, bus: bus),
  ),
  BusSetupStage(
    key: 'seats',
    section: 'seats',
    title: 'C · Seat layout',
    subtitle: 'Visual editor: seats, berths, aisle, driver area, reserved seats',
    icon: Icons.event_seat_outlined,
    builder: (context, operatorId, bus) => StageSeatLayoutScreen(operatorId: operatorId, bus: bus),
  ),
  BusSetupStage(
    key: 'route',
    section: 'route',
    title: 'D · Route & stops',
    subtitle: 'Start, destination, stops, timings, one way or round trip',
    icon: Icons.alt_route,
    builder: (context, operatorId, bus) => RouteRevisionScreen(operatorId: operatorId, bus: bus),
  ),
  BusSetupStage(
    key: 'fare',
    section: 'fare',
    title: 'E · Fares',
    subtitle: 'Base, stop-to-stop, premium seats and extra charges',
    icon: Icons.currency_rupee,
    builder: (context, operatorId, bus) => StageFareScreen(operatorId: operatorId, bus: bus),
  ),
  BusSetupStage(
    key: 'schedule',
    section: 'schedule',
    title: 'F · Schedule',
    subtitle: 'Departure, operating days, booking window and cut-offs',
    icon: Icons.schedule,
    builder: (context, operatorId, bus) => StageScheduleScreen(operatorId: operatorId, bus: bus),
  ),
  BusSetupStage(
    key: 'review',
    title: 'G · Review & submit',
    subtitle: 'Check everything, submit for approval, activate',
    icon: Icons.fact_check_outlined,
    builder: (context, operatorId, bus) => StageReviewScreen(operatorId: operatorId, busId: bus['id'] as String),
  ),
];

class BusSetupScreen extends ConsumerWidget {
  const BusSetupScreen({super.key, required this.operatorId, required this.busId});

  final String operatorId;
  final String busId;

  /// Opens a section; while the operator keeps choosing "Save & Continue to Next Section" the next one opens.
  Future<void> _runFrom(BuildContext context, WidgetRef ref, int index, Map<String, dynamic> bus) async {
    var i = index;
    var current = bus;
    while (i < busSetupStages.length) {
      final stage = busSetupStages[i];
      final result = await Navigator.of(context).push<Object?>(
        MaterialPageRoute(builder: (c) => stage.builder(c, operatorId, current)),
      );
      ref.invalidate(busProvider(busId));
      ref.invalidate(busCompletenessProvider(busId));
      if (result != kSetupContinue || !context.mounted) return;
      current = await ref.read(busProvider(busId).future);
      i++;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busAsync = ref.watch(busProvider(busId));
    final comp = ref.watch(busCompletenessProvider(busId)).value;
    final states = sectionStates(comp);

    return Scaffold(
      appBar: AppBar(title: const Text('Bus setup')),
      body: busAsync.when(
        data: (bus) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(busProvider(busId)),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(busDisplayName(bus), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: AppSpacing.xs),
                    Text('${busTypeLabel(bus['bus_type'] as String)} · ${bus['total_seats']} seats'),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      children: [
                        AppBadge(status: bus['lifecycle_status'] as String),
                        if (busVerificationState(bus) == 'legacy') const AppBadge(status: 'legacy'),
                      ],
                    ),
                    if (comp != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text('Bus Setup: ${busPercent(comp)}% Complete', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.xs),
                      LinearProgressIndicator(value: busPercent(comp) / 100),
                    ],
                    RejectedDocumentsBanner(operatorId: operatorId, bus: bus),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              for (final stage in busSetupStages)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    padding: EdgeInsets.zero,
                    child: AppListItem(
                      leading: Icon(stage.icon),
                      title: stage.title,
                      subtitle: stage.section != null && comp != null && !states[stage.section]!.ok
                          ? 'Missing: ${states[stage.section]!.missing.isEmpty ? busSectionLabels[stage.section] : states[stage.section]!.missing.join(', ')}'
                          : stage.subtitle,
                      trailing: stage.section == null || comp == null
                          ? null
                          : Icon(
                              states[stage.section]!.ok ? Icons.check_circle : Icons.warning_amber_rounded,
                              color: states[stage.section]!.ok ? AppColors.success : AppColors.warning,
                            ),
                      onTap: () => _runFrom(context, ref, busSetupStages.indexOf(stage), bus),
                    ),
                  ),
                ),
            ],
          ),
        ),
        loading: () => const AppLoadingState(),
        error: (e, _) => AppErrorState(message: 'Could not load this bus.', onRetry: () => ref.invalidate(busProvider(busId))),
      ),
    );
  }
}
