import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import '../bus_ops/route_summary.dart';
import 'bus_navigation.dart';
import 'bus_validators.dart';
import 'fleet_providers.dart';
import 'fleet_status.dart';
import 'manage_bus_screen.dart';
import 'rejected_documents_banner.dart';

/// Next scheduled trips for a bus, from today onwards (each day can differ).
final busUpcomingTripsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, busId) async {
  final now = DateTime.now();
  final rows = await ref
      .watch(supabaseProvider)
      .from('bus_trips')
      .select(
        'id, departure_at, arrival_at, '
        'route:bus_routes(source:locations!bus_routes_source_city_id_fkey(name), destination:locations!bus_routes_destination_city_id_fkey(name))',
      )
      .eq('bus_id', busId)
      .gte('departure_at', DateTime(now.year, now.month, now.day).toUtc().toIso8601String())
      .order('departure_at')
      .limit(3);
  return List<Map<String, dynamic>>.from(rows);
});

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

String _dayLabel(DateTime t) {
  final now = DateTime.now();
  final days = DateTime(t.year, t.month, t.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  return '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]}';
}

class _UpcomingTrips extends ConsumerWidget {
  const _UpcomingTrips({required this.busId});

  final String busId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trips = ref.watch(busUpcomingTripsProvider(busId)).value ?? const [];
    if (trips.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Text('No upcoming trips scheduled', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Upcoming trips', style: theme.textTheme.labelLarge),
          for (final t in trips)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Builder(builder: (_) {
                final route = t['route'] as Map<String, dynamic>?;
                final from = (route?['source'] as Map?)?['name'] ?? '—';
                final to = (route?['destination'] as Map?)?['name'] ?? '—';
                final dep = DateTime.parse(t['departure_at'] as String).toLocal();
                final arrRaw = t['arrival_at'] as String?;
                final arr = arrRaw == null ? null : DateTime.parse(arrRaw).toLocal();
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.route, size: 14)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$from → $to\n${_dayLabel(dep)} · ${_clock(dep)}${arr == null ? '' : ' – ${_clock(arr)}'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                );
              }),
            ),
        ],
      ),
    );
  }
}

/// "Route: A → B" for the bus, or a hint when no route is configured yet.
class _AssignedRoute extends ConsumerWidget {
  const _AssignedRoute({required this.operatorId, required this.busId});

  final String operatorId;
  final String busId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaries = ref.watch(operatorRouteSummariesProvider(operatorId)).value;
    if (summaries == null) return const SizedBox.shrink();
    final s = summaries.where((x) => x.busId == busId).firstOrNull;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(children: [
        const Icon(Icons.alt_route, size: 14),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            s == null ? 'No route configured' : 'Route: ${s.source ?? '—'} → ${s.destination ?? '—'}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }
}

/// One bus with its state, setup checklist and the actions that make sense
/// right now. Used by My Buses (full) and the dashboard (compact).
class BusStatusCard extends ConsumerWidget {
  const BusStatusCard({super.key, required this.operatorId, required this.bus, this.compact = false, this.onChanged, this.operatorContext});

  final String operatorId;
  final Map<String, dynamic> bus;
  final bool compact;
  final VoidCallback? onChanged;

  /// When set (Fleet list), the card offers the single "Manage Bus" action.
  final OperatorContext? operatorContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busId = bus['id'] as String;
    final comp = ref.watch(busCompletenessProvider(busId)).value;
    final theme = Theme.of(context);
    final states = sectionStates(comp);
    final actions = busActions(bus, comp);
    final legacy = busVerificationState(bus) == 'legacy';
    final reason = (bus['review_reason'] as String?) ?? '';
    final showChecklist = comp != null &&
        !isAwaitingReview(bus) &&
        effectiveBusState(bus) != 'suspended' &&
        !(effectiveBusState(bus) == 'active' && isBusComplete(comp));

    Future<void> run(BusAction a) async {
      await openBusAction(context, operatorId: operatorId, bus: bus, action: a);
      ref.invalidate(busCompletenessProvider(busId));
      ref.invalidate(busesProvider(operatorId));
      onChanged?.call();
    }

    // Fleet card: one primary action. State-specific steps (continue setup, submit,
    // activate...) live in Manage Bus → Overview. The compact dashboard card keeps its one quick action.
    final shown = compact ? actions.take(1).toList() : const <BusAction>[];

    Future<void> openManage() async {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ManageBusScreen(context: operatorContext!, busId: busId)),
      );
      ref.invalidate(busCompletenessProvider(busId));
      ref.invalidate(busesProvider(operatorId));
      onChanged?.call();
    }

    return AppCard(
      onTap: compact || operatorContext == null ? () => run(BusAction.viewDetails) : openManage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_bus),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(busDisplayName(bus), style: theme.textTheme.titleSmall)),
              if (comp != null && !compact && !isAwaitingReview(bus) && effectiveBusState(bus) != 'active')
                Text('${busPercent(comp)}%', style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 2),
          // The badge below already says "Active", so don't repeat it as text.
          if (!(compact && effectiveBusState(bus) == 'active'))
            Text(
              compact
                  ? busHeadline(bus, comp)
                  : [
                      busTypeLabel(bus['bus_type'] as String),
                      '${bus['total_seats']} seats',
                      if (effectiveBusState(bus) != 'active') busHeadline(bus, comp),
                    ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              AppBadge(status: bus['lifecycle_status'] as String),
              if (legacy) const AppBadge(status: 'legacy'),
            ],
          ),
          if (!compact) _AssignedRoute(operatorId: operatorId, busId: busId),
          if (legacy && !compact) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Legacy bus — it keeps running, but has not been verified. Complete the checklist and submit it for review.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (isAwaitingReview(bus)) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(children: [
              const Icon(Icons.hourglass_top, size: 16),
              const SizedBox(width: 4),
              Text('Awaiting approval', style: theme.textTheme.bodySmall),
            ]),
          ],
          if (compact && effectiveBusState(bus) == 'active') _UpcomingTrips(busId: busId),
          RejectedDocumentsBanner(operatorId: operatorId, bus: bus, onChanged: onChanged),
          if (showChecklist) ...[
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: 2,
              children: [
                for (final s in busSections)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                      states[s]!.ok ? Icons.check : Icons.warning_amber_rounded,
                      size: 14,
                      color: states[s]!.ok ? AppColors.success : AppColors.warning,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      states[s]!.ok ? busSectionLabels[s]! : '${busSectionLabels[s]} missing',
                      style: theme.textTheme.bodySmall,
                    ),
                  ]),
              ],
            ),
          ],
          if (reason.isNotEmpty && !compact && const ['changes_requested', 'suspended', 'inactive', 'legacy_changes_requested'].contains(effectiveBusState(bus))) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(reason, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ],
          if (shown.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final a in shown)
                    AppButton(label: a.label, size: AppButtonSize.small, onPressed: () => run(a)),
                ],
              ),
            ),
          ],
          if (!compact && operatorContext != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: AppButton(label: 'Manage Bus', size: AppButtonSize.small, onPressed: openManage),
            ),
          ],
        ],
      ),
    );
  }
}
