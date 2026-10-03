import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/operator_providers.dart';
import 'journey_timeline.dart';
import 'route_navigation.dart';
import 'route_summary.dart';

String _originLabel(Map<String, dynamic> r) => switch (r['origin']) {
      'admin' => 'Admin',
      'route_copy' => 'Route copy${r['source_registration_number'] != null ? ' from ${r['source_registration_number']}' : ''}',
      _ => 'Operator',
    };

String _badgeFor(String status) => switch (status) {
      'pending_approval' => 'pending',
      'superseded' => 'inactive',
      'withdrawn' => 'cancelled',
      _ => status,
    };

/// Every revision of a bus's route, newest first: who changed what, when, whether it was approved,
/// and the admin's reason when it was rejected.
class RouteHistoryScreen extends ConsumerWidget {
  const RouteHistoryScreen({super.key, required this.summary, required this.ctx});

  final RouteSummary summary;
  final OperatorContext ctx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(busRevisionsProvider(summary.busId));
    return Scaffold(
      appBar: AppBar(title: const Text('Route history')),
      body: SafeArea(
        child: async.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load the history.', onRetry: () => ref.invalidate(busRevisionsProvider(summary.busId))),
          data: (revs) => revs.isEmpty
              ? const AppEmptyState(message: 'No route changes yet.', icon: Icons.history)
              : ListView.builder(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: revs.length,
                  itemBuilder: (context, i) {
                    final r = revs[i];
                    final live = r['id'] == summary.activeRevisionId;
                    final when = DateTime.tryParse((r['submitted_at'] ?? r['created_at']) as String)?.toLocal();
                    return AppCard(
                      padding: EdgeInsets.zero,
                      child: AppListItem(
                        leading: const Icon(Icons.history),
                        title: 'Revision ${r['revision_no']} · ${r['name'] ?? 'Route'}',
                        subtitle: [
                          if (r['trip_type'] == 'round_trip') 'Round trip' else 'One way',
                          if (when != null) DateFormat('d MMM yyyy').format(when),
                          _originLabel(r),
                          if (r['previous_revision_no'] != null) 'replaced revision ${r['previous_revision_no']}',
                          if (live) 'live now',
                          if (r['change_reason'] != null) '“${r['change_reason']}”',
                          if (r['status'] == 'rejected' && r['rejection_reason'] != null) 'Rejected: ${r['rejection_reason']}',
                        ].join(' · '),
                        trailing: AppBadge(status: _badgeFor(r['status'] as String)),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => RevisionViewScreen(summary: summary, ctx: ctx, revisionId: r['id'] as String, status: r['status'] as String),
                        )),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

/// One revision, read only. A rejected revision can be corrected and resubmitted from here.
class RevisionViewScreen extends ConsumerWidget {
  const RevisionViewScreen({super.key, required this.summary, required this.ctx, required this.revisionId, required this.status});

  final RouteSummary summary;
  final OperatorContext ctx;
  final String revisionId;
  final String status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(routeRevisionDetailProvider(revisionId));
    return Scaffold(
      appBar: AppBar(title: const Text('Route revision')),
      body: SafeArea(
        child: async.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load this revision.', onRetry: () => ref.invalidate(routeRevisionDetailProvider(revisionId))),
          data: (rev) => ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Revision ${rev['revision_no']}', style: Theme.of(context).textTheme.titleMedium),
                        AppBadge(status: _badgeFor(rev['status'] as String)),
                      ],
                    ),
                    if (rev['change_reason'] != null) Padding(padding: const EdgeInsets.only(top: AppSpacing.xs), child: Text('Reason: ${rev['change_reason']}')),
                    if (rev['submitted_at'] != null)
                      Text('Submitted ${DateFormat('d MMM yyyy, h:mm a').format(DateTime.parse(rev['submitted_at'] as String).toLocal())}', style: Theme.of(context).textTheme.bodySmall),
                    if (rev['reviewed_at'] != null)
                      Text('Reviewed ${DateFormat('d MMM yyyy, h:mm a').format(DateTime.parse(rev['reviewed_at'] as String).toLocal())}', style: Theme.of(context).textTheme.bodySmall),
                    if (rev['rejection_reason'] != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text('Rejected: ${rev['rejection_reason']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              RevisionTimelines(revision: rev),
              if (status == 'rejected') ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Resubmit corrections',
                  expand: true,
                  onPressed: () => openRouteEditor(context, ref, ctx: ctx, summary: summary, baseRevisionId: revisionId),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
