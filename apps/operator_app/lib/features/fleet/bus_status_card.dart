import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bus_navigation.dart';
import 'bus_validators.dart';
import 'fleet_providers.dart';
import 'fleet_status.dart';

/// One bus with its state, setup checklist and the actions that make sense
/// right now. Used by My Buses (full) and the dashboard (compact).
class BusStatusCard extends ConsumerWidget {
  const BusStatusCard({super.key, required this.operatorId, required this.bus, this.compact = false, this.onChanged});

  final String operatorId;
  final Map<String, dynamic> bus;
  final bool compact;
  final VoidCallback? onChanged;

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

    final shown = compact ? actions.take(1).toList() : actions.take(4).toList();

    return AppCard(
      onTap: () => run(BusAction.viewDetails),
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
          Text(
            compact ? busHeadline(bus, comp) : '${busTypeLabel(bus['bus_type'] as String)} · ${bus['total_seats']} seats · ${busHeadline(bus, comp)}',
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
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                for (var i = 0; i < shown.length; i++)
                  AppButton(
                    label: shown[i].label,
                    size: AppButtonSize.small,
                    variant: i == 0 ? AppButtonVariant.primary : AppButtonVariant.outline,
                    onPressed: () => run(shown[i]),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
