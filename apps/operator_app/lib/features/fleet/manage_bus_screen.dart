import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../bus_ops/routes_list_screen.dart';
import '../bus_ops/route_summary.dart';
import '../bus_ops/trips_screen.dart';
import '../tracking/gps_tracking_screen.dart';
import 'bus_navigation.dart';
import 'bus_validators.dart';
import 'fleet_providers.dart';
import 'fleet_status.dart';
import 'rejected_documents_banner.dart';

/// Everything about one bus in one place: Overview, Route, Trips, Vehicle.
/// Replaces the row of competing card buttons (View Details / Create Trips / Manage).
class ManageBusScreen extends ConsumerWidget {
  const ManageBusScreen({super.key, required this.context, required this.busId, this.initialTab = 0});

  final OperatorContext context;
  final String busId;
  final int initialTab;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busAsync = ref.watch(busProvider(busId));
    return busAsync.when(
      loading: () => Scaffold(appBar: AppBar(title: const Text('Manage Bus')), body: const Center(child: AppLoadingState())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Manage Bus')),
        body: Center(child: AppErrorState(message: 'Could not load this bus.', onRetry: () => ref.invalidate(busProvider(busId)))),
      ),
      data: (bus) => DefaultTabController(
        length: 4,
        initialIndex: initialTab,
        child: Scaffold(
          appBar: AppBar(
            title: Text(busDisplayName(bus), overflow: TextOverflow.ellipsis),
            bottom: const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [Tab(text: 'Overview'), Tab(text: 'Route'), Tab(text: 'Trips'), Tab(text: 'Vehicle')],
            ),
          ),
          body: TabBarView(children: [
            _OverviewTab(context: context, bus: bus),
            _RouteTab(context: context, bus: bus),
            TripsScreen(context: context, busId: busId),
            _VehicleTab(context: context, bus: bus),
          ]),
        ),
      ),
    );
  }
}

Future<void> _refreshBus(WidgetRef ref, String operatorId, String busId) async {
  ref.invalidate(busProvider(busId));
  ref.invalidate(busesProvider(operatorId));
  ref.invalidate(busCompletenessProvider(busId));
  ref.invalidate(busRouteProvider(busId));
  ref.invalidate(operatorRouteSummariesProvider(operatorId));
}

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab({required this.context, required this.bus});

  final OperatorContext context;
  final Map<String, dynamic> bus;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busId = bus['id'] as String;
    final comp = ref.watch(busCompletenessProvider(busId)).value;
    final theme = Theme.of(buildContext);
    final states = sectionStates(comp);
    final state = effectiveBusState(bus);
    final reason = (bus['review_reason'] as String?) ?? '';
    const stateActions = {BusAction.continueSetup, BusAction.submit, BusAction.activate, BusAction.deactivate, BusAction.viewReason};
    final actions = busActions(bus, comp).where(stateActions.contains).toList();
    final showChecklist = comp != null && !isAwaitingReview(bus) && !(state == 'active' && isBusComplete(comp));

    Widget row(String label, String? value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 130, child: Text(label, style: theme.textTheme.bodySmall)),
            Expanded(child: Text(value == null || value.isEmpty ? '—' : value)),
          ]),
        );

    return RefreshIndicator(
      onRefresh: () => _refreshBus(ref, context.operatorId, busId),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.directions_bus),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(busDisplayName(bus), style: theme.textTheme.titleMedium)),
                  AppBadge(status: bus['lifecycle_status'] as String),
                ]),
                const SizedBox(height: AppSpacing.xs),
                Text(busHeadline(bus, comp), style: theme.textTheme.bodySmall),
                const Divider(height: AppSpacing.lg),
                row('Registration', bus['registration_number'] as String?),
                row('Category', busTypeLabel(bus['bus_type'] as String)),
                row('Seating capacity', '${bus['total_seats']} seats'),
                row('Make / model', [bus['manufacturer'], bus['model']].where((e) => e != null && '$e'.isNotEmpty).join(' ')),
                row('Manufactured', bus['manufacturing_year']?.toString()),
                row('Registered', bus['registration_year']?.toString()),
              ],
            ),
          ),
          RejectedDocumentsBanner(operatorId: context.operatorId, bus: bus, onChanged: () => _refreshBus(ref, context.operatorId, busId)),
          if (reason.isNotEmpty && const ['changes_requested', 'suspended', 'inactive', 'legacy_changes_requested'].contains(state))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text(reason, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ),
          if (showChecklist) ...[
            const SizedBox(height: AppSpacing.md),
            Text('Setup checklist', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            for (final s in busSections)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  states[s]!.ok ? Icons.check_circle : Icons.warning_amber_rounded,
                  color: states[s]!.ok ? AppColors.success : AppColors.warning,
                ),
                title: Text(busSectionLabels[s]!),
                subtitle: states[s]!.ok || states[s]!.missing.isEmpty ? null : Text('Missing: ${states[s]!.missing.join(', ')}'),
              ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (var i = 0; i < actions.length; i++)
                  AppButton(
                    label: actions[i].label,
                    variant: i == 0 ? AppButtonVariant.primary : AppButtonVariant.outline,
                    onPressed: () async {
                      await openBusAction(buildContext, operatorId: context.operatorId, bus: bus, action: actions[i]);
                      await _refreshBus(ref, context.operatorId, busId);
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RouteTab extends ConsumerWidget {
  const _RouteTab({required this.context, required this.bus});

  final OperatorContext context;
  final Map<String, dynamic> bus;

  static String _offset(int? m) => m == null ? '' : (m < 60 ? '+${m}m' : '+${m ~/ 60}h${m % 60 == 0 ? '' : ' ${m % 60}m'}');

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busId = bus['id'] as String;
    final summariesAsync = ref.watch(operatorRouteSummariesProvider(context.operatorId));
    final routeAsync = ref.watch(busRouteProvider(busId));
    final theme = Theme.of(buildContext);

    return summariesAsync.when(
      loading: () => const Center(child: AppLoadingState()),
      error: (e, _) => Center(
        child: AppErrorState(
          message: 'Could not load the route.',
          onRetry: () => ref.invalidate(operatorRouteSummariesProvider(context.operatorId)),
        ),
      ),
      data: (all) {
        final summary = all.where((s) => s.busId == busId).firstOrNull;
        if (summary == null) {
          return Center(
            child: AppEmptyState(
              icon: Icons.alt_route,
              message: 'No route configured for this bus yet.',
              action: AppButton(
                label: 'Configure Route',
                onPressed: () async {
                  await openBusAction(buildContext, operatorId: context.operatorId, bus: bus, action: BusAction.configureRoute);
                  await _refreshBus(ref, context.operatorId, busId);
                },
              ),
            ),
          );
        }
        final data = routeAsync.value;
        final boarding = List<Map<String, dynamic>>.from((data?['boarding'] as List?) ?? const []);
        final dropping = List<Map<String, dynamic>>.from((data?['dropping'] as List?) ?? const []);
        return ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            RouteCard(summary: summary, ctx: context),
            if (boarding.isNotEmpty || dropping.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text('Stops in order', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (final p in boarding)
                    AppListItem(
                      leading: const Icon(Icons.trip_origin, size: 18),
                      title: p['name'] as String,
                      subtitle: 'Pickup · departs ${_offset(p['departure_offset_min'] as int?)}',
                    ),
                  for (final p in dropping.where((d) => !boarding.any((b) => b['name'] == d['name'])))
                    AppListItem(
                      leading: const Icon(Icons.flag_outlined, size: 18),
                      title: p['name'] as String,
                      subtitle: 'Drop · arrives ${_offset(p['arrival_offset_min'] as int?)}',
                    ),
                ]),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _VehicleTab extends ConsumerWidget {
  const _VehicleTab({required this.context, required this.bus});

  final OperatorContext context;
  final Map<String, dynamic> bus;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busId = bus['id'] as String;
    final comp = ref.watch(busCompletenessProvider(busId)).value;
    final all = busActions(bus, comp);
    final canActivate = all.contains(BusAction.activate);
    final canDeactivate = all.contains(BusAction.deactivate);

    Future<void> run(BusAction a) async {
      await openBusAction(buildContext, operatorId: context.operatorId, bus: bus, action: a);
      await _refreshBus(ref, context.operatorId, busId);
    }

    Widget tile(IconData icon, String title, String subtitle, VoidCallback onTap) => AppCard(
          padding: EdgeInsets.zero,
          child: AppListItem(leading: Icon(icon), title: title, subtitle: subtitle, trailing: const Icon(Icons.chevron_right), onTap: onTap),
        );

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        tile(Icons.edit_outlined, 'Edit bus', 'Details, documents, seat layout and photos', () => run(BusAction.viewDetails)),
        const SizedBox(height: AppSpacing.sm),
        tile(Icons.payments_outlined, 'Fares', 'Base fares and extra charges', () => run(BusAction.manageFare)),
        const SizedBox(height: AppSpacing.sm),
        tile(Icons.schedule, 'Schedule', 'Departure time, operating days, booking rules', () => run(BusAction.manageSchedule)),
        const SizedBox(height: AppSpacing.sm),
        tile(
          Icons.sensors,
          'GPS Tracking',
          'Tracker device, connection and last location',
          () => Navigator.of(buildContext).push(
            MaterialPageRoute<void>(builder: (_) => GpsTrackingScreen(busId: busId, busRegistration: bus['registration_number'] as String? ?? '', operatorContext: context)),
          ),
        ),
        if (canActivate || canDeactivate) ...[
          const SizedBox(height: AppSpacing.sm),
          tile(
            Icons.power_settings_new,
            canActivate ? 'Activate bus' : 'Deactivate bus',
            canActivate ? 'Make this bus bookable' : 'Stop new trips and bookings for this bus',
            () => run(canActivate ? BusAction.activate : BusAction.deactivate),
          ),
        ],
      ],
    );
  }
}
