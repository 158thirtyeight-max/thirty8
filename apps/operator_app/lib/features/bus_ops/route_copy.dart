import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import '../fleet/route_revision_screen.dart';
import 'journey_timeline.dart';
import 'route_summary.dart';

/// Buses of the operator a route can be copied to (every bus except the source whose route is not locked).
final copyTargetBusesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('buses')
      .select('id, name, registration_number, lifecycle_status, active_route_revision_id')
      .eq('operator_id', operatorId)
      .inFilter('lifecycle_status', ['draft', 'changes_requested', 'approved', 'active'])
      .order('registration_number');
  return List<Map<String, dynamic>>.from(rows);
});

/// Copy Route: pick the destination bus, preview the route being copied, confirm. The copy is a new
/// independent draft revision on the destination bus (never shared with the source); when the
/// destination already has a route the user must confirm replacing it through a new revision, and the
/// approved route stays live until the new revision is approved. The draft opens for editing.
Future<void> showCopyRouteSheet(BuildContext context, WidgetRef ref, {required OperatorContext ctx, required RouteSummary source}) async {
  final opened = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CopyRouteSheet(ctx: ctx, source: source),
  );
  if (opened == null || !context.mounted) return;
  ref.invalidate(operatorRouteSummariesProvider(ctx.operatorId));
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => RouteRevisionScreen(
      operatorId: ctx.operatorId,
      bus: opened['bus'] as Map<String, dynamic>,
      isOperatorAdmin: ctx.isAdmin,
      revisionId: opened['revision_id'] as String,
    ),
  ));
  ref.invalidate(operatorRouteSummariesProvider(ctx.operatorId));
}

class _CopyRouteSheet extends ConsumerStatefulWidget {
  const _CopyRouteSheet({required this.ctx, required this.source});

  final OperatorContext ctx;
  final RouteSummary source;

  @override
  ConsumerState<_CopyRouteSheet> createState() => _CopyRouteSheetState();
}

class _CopyRouteSheetState extends ConsumerState<_CopyRouteSheet> {
  Map<String, dynamic>? _dest;
  bool _busy = false;
  String? _error;

  String _label(Map<String, dynamic> b) {
    final name = (b['name'] as String?)?.trim() ?? '';
    final reg = b['registration_number'] as String? ?? '';
    return name.isEmpty ? reg : '$name · $reg';
  }

  Future<void> _copy({bool replace = false}) async {
    final dest = _dest;
    if (dest == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = Map<String, dynamic>.from(await ref.read(supabaseProvider).rpc('copy_route_to_bus', params: {
        'p_source_bus_id': widget.source.busId,
        'p_dest_bus_id': dest['id'],
        'p_replace': replace,
      }) as Map);
      if (res['needs_confirmation'] == true) {
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Replace the existing route?'),
            content: Text(
              '${_label(dest)} already has ${res['destination_has_route'] == true ? 'a route${res['destination_route_name'] != null ? ' (${res['destination_route_name']})' : ''}' : 'an unsubmitted route draft'}. '
              'The copy becomes a new revision that replaces it only after it is approved. The current route stays live until then'
              '${res['destination_has_draft'] == true ? ', and the existing draft will be discarded' : ''}.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Replace via new revision')),
            ],
          ),
        );
        if (ok == true) await _copy(replace: true);
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, {'revision_id': res['revision_id'], 'bus': dest});
    } catch (e) {
      if (mounted) setState(() => _error = e is PostgrestException ? e.message : 'Could not copy the route.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.source;
    final buses = ref.watch(copyTargetBusesProvider(widget.ctx.operatorId));
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, MediaQuery.of(context).viewInsets.bottom + AppSpacing.md),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Copy route', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text('From ${s.busLabel}: ${s.routeName}', style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.md),
            buses.when(
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(message: 'Could not load your buses.', onRetry: () => ref.invalidate(copyTargetBusesProvider(widget.ctx.operatorId))),
              data: (all) {
                final targets = all.where((b) => b['id'] != s.busId).toList();
                if (targets.isEmpty) return const Text('You have no other bus to copy this route to.');
                return DropdownButtonFormField<String>(
                  initialValue: _dest?['id'] as String?,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Copy to vehicle'),
                  items: [for (final b in targets) DropdownMenuItem(value: b['id'] as String, child: Text(_label(b)))],
                  onChanged: _busy ? null : (v) => setState(() => _dest = targets.firstWhere((b) => b['id'] == v)),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Route being copied', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            if (s.activeRevisionId != null)
              ref.watch(routeRevisionDetailProvider(s.activeRevisionId!)).when(
                    data: (rev) => RevisionTimelines(revision: rev),
                    loading: () => const AppLoadingState(),
                    error: (e, _) => const Text('Could not load the route preview.'),
                  )
            else
              Text('${s.source ?? '?'} → ${s.destination ?? '?'} · ${s.isRoundTrip ? 'Round trip' : 'One way'}'),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Stops, times, permissions and days are copied as an independent route. Trips, bookings, passengers, seats and payments are not copied, and changing the copy never changes ${s.busLabel}.',
              style: theme.textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: AppSpacing.md),
            AppButton(label: 'Copy route', expand: true, loading: _busy, onPressed: (_dest == null || _busy) ? null : () => _copy()),
          ],
        ),
      ),
    );
  }
}
