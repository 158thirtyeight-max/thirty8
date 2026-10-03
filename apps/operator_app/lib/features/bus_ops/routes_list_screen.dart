import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/operator_providers.dart';
import '../fleet/operating_days_picker.dart';
import 'route_copy.dart';
import 'route_navigation.dart';
import 'route_summary.dart';

/// The Routes tab: one card per bus route with its live (approved) route, trip type, status and
/// approval state, and the actions to view, change or review the route. Changes never touch the live
/// route directly; they become revisions that wait for admin approval.
class RoutesListScreen extends ConsumerWidget {
  const RoutesListScreen({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final async = ref.watch(operatorRouteSummariesProvider(context.operatorId));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(operatorRouteSummariesProvider(context.operatorId)),
        child: async.when(
          data: (routes) => routes.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [AppEmptyState(message: 'No routes yet. A route is set up for each bus under Fleet → your bus → Route.', icon: Icons.alt_route)],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: routes.length,
                  itemBuilder: (c, i) => RouteCard(summary: routes[i], ctx: context),
                ),
          loading: () => const AppLoadingState(),
          error: (e, st) => AppErrorState(
            message: 'Could not load routes.',
            onRetry: () => ref.invalidate(operatorRouteSummariesProvider(context.operatorId)),
          ),
        ),
      ),
    );
  }
}

class RouteCard extends ConsumerWidget {
  const RouteCard({super.key, required this.summary, required this.ctx});

  final RouteSummary summary;
  final OperatorContext ctx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = summary;
    final theme = Theme.of(context);
    final stops = s.intermediateStops;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => openRouteDetail(context, s, ctx),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(s.routeName, style: theme.textTheme.titleMedium)),
                    AppBadge(status: s.approvalStatus),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(s.busLabel, style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpacing.sm),
                Text('${s.source ?? '—'} → ${s.destination ?? '—'}', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: [
                  AppChip(label: s.isRoundTrip ? 'Round trip' : 'One way'),
                  AppChip(label: s.routeStatus),
                  if (s.operatingDays != null) AppChip(label: describeOperatingDays(s.operatingDays!)),
                  AppChip(label: stops == null ? 'Stops: —' : '$stops intermediate stop${stops == 1 ? '' : 's'}'),
                ]),
                if (s.lastUpdated != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text('Last updated ${DateFormat('d MMM yyyy').format(s.lastUpdated!)}', style: theme.textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          if (s.approvalStatus == 'rejected')
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text('Rejected: ${s.rejectionReason ?? 'no reason given'}', style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (s.isPending)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Text('A change is waiting for admin approval. Your current route stays live.', style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: [
            AppButton(label: 'View', size: AppButtonSize.small, variant: AppButtonVariant.outline, onPressed: () => openRouteDetail(context, s, ctx)),
            AppButton(
              label: 'Edit',
              size: AppButtonSize.small,
              variant: AppButtonVariant.outline,
              onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s),
            ),
            AppButton(
              label: s.isRoundTrip ? 'Edit return' : 'Configure return',
              size: AppButtonSize.small,
              variant: AppButtonVariant.outline,
              onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s, returnRoute: true),
            ),
            if (s.hasLiveRoute)
              AppButton(label: 'Copy route', size: AppButtonSize.small, variant: AppButtonVariant.outline, onPressed: () => showCopyRouteSheet(context, ref, ctx: ctx, source: s)),
            AppButton(label: 'History', size: AppButtonSize.small, variant: AppButtonVariant.ghost, onPressed: () => openRouteHistory(context, s, ctx)),
            if (s.hasDraft)
              AppButton(
                label: 'Submit for approval',
                size: AppButtonSize.small,
                onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s),
              ),
            if (s.approvalStatus == 'rejected')
              AppButton(
                label: 'Resubmit',
                size: AppButtonSize.small,
                onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s, baseRevisionId: s.rejectedRevisionId),
              ),
          ]),
        ],
      ),
    );
  }
}
