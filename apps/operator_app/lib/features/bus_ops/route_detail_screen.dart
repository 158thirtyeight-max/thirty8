import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'journey_timeline.dart';
import 'route_copy.dart';
import 'route_navigation.dart';
import 'route_points_screen.dart';
import 'route_summary.dart';

/// The live route of a bus as a stop-by-stop timeline, plus any change waiting for approval or still a
/// draft. The live route stays exactly as approved until an admin approves a change.
class RouteDetailScreen extends ConsumerWidget {
  const RouteDetailScreen({super.key, required this.summary, required this.ctx});

  final RouteSummary summary;
  final OperatorContext ctx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep this screen in step with the list after an edit / submit / withdraw.
    final fresh = ref.watch(operatorRouteSummariesProvider(ctx.operatorId)).maybeWhen(
          data: (all) => all.where((s) => s.busId == summary.busId).firstOrNull,
          orElse: () => null,
        );
    final s = fresh ?? summary;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(s.busLabel)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.routeName, style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.xs, children: [
                    AppChip(label: s.isRoundTrip ? 'Round trip' : 'One way'),
                    AppChip(label: s.routeStatus),
                    AppBadge(status: s.approvalStatus),
                  ]),
                  if (s.lastUpdated != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text('Last updated ${DateFormat('d MMM yyyy').format(s.lastUpdated!)}', style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            if (s.approvalStatus == 'rejected') ...[
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your last change was rejected', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.error)),
                    const SizedBox(height: AppSpacing.xs),
                    Text(s.rejectionReason ?? 'No reason given.'),
                    const SizedBox(height: AppSpacing.sm),
                    Text('Your approved route is unchanged and still live.', style: theme.textTheme.bodySmall),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton(
                      label: 'Resubmit corrections',
                      size: AppButtonSize.small,
                      onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s, baseRevisionId: s.rejectedRevisionId),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text('Current route (live)', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            _live(context, s),
            if (s.openRevisionId != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(s.isPending ? 'Proposed change — awaiting admin approval' : 'Draft change — not submitted yet', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              ref.watch(routeRevisionDetailProvider(s.openRevisionId!)).when(
                    data: (rev) => RevisionTimelines(revision: rev),
                    loading: () => const AppLoadingState(),
                    error: (e, _) => AppErrorState(message: 'Could not load the proposed route.', onRetry: () => ref.invalidate(routeRevisionDetailProvider(s.openRevisionId!))),
                  ),
              const SizedBox(height: AppSpacing.sm),
              if (s.isPending)
                AppButton(
                  label: 'Withdraw this request',
                  variant: AppButtonVariant.outline,
                  expand: true,
                  onPressed: () => _withdraw(context, ref, s),
                )
              else
                AppButton(
                  label: 'Continue editing / submit for approval',
                  expand: true,
                  onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s),
                ),
            ],
            const SizedBox(height: AppSpacing.lg),
            if (s.openRevisionId == null) ...[
              AppButton(label: 'Edit route', expand: true, onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s)),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: s.isRoundTrip ? 'Edit return route' : 'Configure return route',
                variant: AppButtonVariant.outline,
                expand: true,
                onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: s, returnRoute: true),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (s.hasLiveRoute) ...[
              AppButton(label: 'Copy route to another bus', variant: AppButtonVariant.outline, expand: true, onPressed: () => showCopyRouteSheet(context, ref, ctx: ctx, source: s)),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppButton(
              label: 'View route history',
              variant: AppButtonVariant.ghost,
              expand: true,
              onPressed: () => openRouteHistory(context, s, ctx),
            ),
          ],
        ),
      ),
    );
  }

  Widget _live(BuildContext context, RouteSummary s) {
    if (s.activeRevisionId != null) {
      return Consumer(builder: (context, ref, _) {
        return ref.watch(routeRevisionDetailProvider(s.activeRevisionId!)).when(
              data: (rev) => RevisionTimelines(revision: rev),
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(message: 'Could not load the route.', onRetry: () => ref.invalidate(routeRevisionDetailProvider(s.activeRevisionId!))),
            );
      });
    }
    // Routes set up before revisions existed have no revision history yet: show the stops as stored.
    if (s.liveRouteId != null) {
      return AppCard(
        padding: EdgeInsets.zero,
        child: AppListItem(
          leading: const Icon(Icons.alt_route),
          title: '${s.source ?? '?'} → ${s.destination ?? '?'}',
          subtitle: 'Boarding and dropping points',
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => RoutePointsScreen(routeId: s.liveRouteId!, routeLabel: '${s.source ?? '?'} → ${s.destination ?? '?'}'),
          )),
        ),
      );
    }
    return const AppEmptyState(message: 'No route is live yet.', icon: Icons.alt_route);
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref, RouteSummary s) async {
    try {
      await ref.read(supabaseProvider).rpc('withdraw_route_revision', params: {'p_revision_id': s.openRevisionId});
      ref.invalidate(operatorRouteSummariesProvider(ctx.operatorId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is PostgrestException ? e.message : 'Could not withdraw the request.')));
      }
    }
  }
}
