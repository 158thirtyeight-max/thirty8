import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'bus_validators.dart';
import 'fare_model.dart';
import 'fleet_providers.dart';
import 'fleet_status.dart';
import 'operating_days_picker.dart';
import 'route_model.dart';
import 'stage_seat_layout_screen.dart';

/// Stage G — final review of one bus: everything configured, the completion
/// percentage, what is missing, and the workflow action (submit for approval,
/// activate, deactivate). The server re-checks all of it in the RPCs.
class StageReviewScreen extends ConsumerStatefulWidget {
  const StageReviewScreen({super.key, required this.operatorId, required this.busId});

  final String operatorId;
  final String busId;

  @override
  ConsumerState<StageReviewScreen> createState() => _StageReviewScreenState();
}

class _StageReviewScreenState extends ConsumerState<StageReviewScreen> {
  bool _busy = false;
  String? _error;

  void _refreshAll() {
    ref.invalidate(busProvider(widget.busId));
    ref.invalidate(busCompletenessProvider(widget.busId));
    ref.invalidate(busReadinessProvider(widget.busId));
    ref.invalidate(busesProvider(widget.operatorId));
  }

  Future<void> _run(String rpc, String okMessage) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc(rpc, params: {'p_bus_id': widget.busId});
      _refreshAll();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(okMessage)));
    } catch (e) {
      final text = e.toString();
      final i = text.indexOf('Missing:');
      final j = text.indexOf('cannot be activated:');
      setState(() => _error = i >= 0
          ? text.substring(i).split('"').first
          : j >= 0
              ? 'The bus ${text.substring(j).split('"').first}'
              : 'That did not work. Please review the checklist below and try again.');
      _refreshAll();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm(String title, String body, VoidCallback onYes) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok == true) onYes();
  }

  @override
  Widget build(BuildContext context) {
    final busAsync = ref.watch(busProvider(widget.busId));
    final compAsync = ref.watch(busCompletenessProvider(widget.busId));

    return Scaffold(
      appBar: AppBar(title: const Text('Review & submit')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (busAsync.hasError || compAsync.hasError) {
            return AppErrorState(message: 'Could not load the bus review.', onRetry: _refreshAll);
          }
          if (!busAsync.hasValue || !compAsync.hasValue) return const AppLoadingState();
          return _body(context, busAsync.requireValue, compAsync.requireValue);
        }),
      ),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> bus, Map<String, dynamic> comp) {
    final theme = Theme.of(context);
    final id = widget.busId;
    final states = sectionStates(comp);
    final missing = List<String>.from(comp['missing'] as List);
    final actions = busActions(bus, comp);
    final state = effectiveBusState(bus);
    final reason = (bus['review_reason'] as String?) ?? '';
    final docs = ref.watch(busDocumentsProvider(id)).value ?? const <Map<String, dynamic>>[];
    final layout = ref.watch(busLayoutProvider(id)).value;
    final route = ref.watch(busRouteProvider(id)).value;
    final fares = ref.watch(busFaresProvider(id)).value;
    final readiness = (state == 'approved' || (state == 'inactive' && bus['approved_by'] != null))
        ? ref.watch(busReadinessProvider(id)).value
        : null;

    final seats = layout == null ? const <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(layout['seats'] as List);
    final bookable = seats.where((s) => s['kind'] == 'bookable').length;
    final service = route?['service'] as Map<String, dynamic>?;
    final boarding = route == null ? const [] : List<Map<String, dynamic>>.from(route['boarding'] as List);
    final dropping = route == null ? const [] : List<Map<String, dynamic>>.from(route['dropping'] as List);

    Widget check(bool ok, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded, size: 18, color: ok ? AppColors.success : AppColors.warning),
            const SizedBox(width: 6),
            Expanded(child: Text(text)),
          ]),
        );

    Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: theme.textTheme.titleSmall), const SizedBox(height: 4), ...children])),
        );

    final stops = service == null
        ? const <RouteStop>[]
        : stopsFromPoints(
            boarding: List<Map<String, dynamic>>.from(boarding),
            dropping: List<Map<String, dynamic>>.from(dropping),
            departureMin: () {
              final t = (service['default_departure_time'] as String? ?? '00:00:00').split(':');
              return int.parse(t[0]) * 60 + int.parse(t[1]);
            }(),
          );

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bus Setup: ${busPercent(comp)}% Complete', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              LinearProgressIndicator(value: busPercent(comp) / 100),
              const SizedBox(height: AppSpacing.sm),
              Wrap(spacing: AppSpacing.sm, children: [
                AppBadge(status: bus['lifecycle_status'] as String),
                if (bus['is_legacy'] == true) const AppBadge(status: 'legacy'),
              ]),
              const SizedBox(height: AppSpacing.xs),
              Text(busHeadline(bus, comp), style: theme.textTheme.bodyMedium),
              for (final m in missing)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('Missing: $m', style: TextStyle(color: theme.colorScheme.error)),
                ),
            ],
          ),
        ),
        if (reason.isNotEmpty && (state == 'changes_requested' || state == 'legacy_changes_requested' || state == 'suspended' || state == 'inactive')) ...[
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(state == 'suspended' ? 'Suspension reason' : state == 'inactive' ? 'Reason' : 'Changes requested', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(reason),
            ]),
          ),
        ],
        if (readiness != null && readiness['ready'] != true) ...[
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Before this bus can be activated', style: theme.textTheme.titleSmall),
              for (final b in List<String>.from(readiness['blockers'] as List)) check(false, b),
            ]),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        section('Bus', [
          Text(busDisplayName(bus)),
          Text('${busTypeLabel(bus['bus_type'] as String)} · capacity ${bus['total_seats']}'),
          if (bus['manufacturer'] != null) Text('${bus['manufacturer']} ${bus['model'] ?? ''} · ${bus['manufacturing_year'] ?? '—'}'),
          check(states['basic']!.ok, states['basic']!.ok ? 'Basic information and photographs complete' : 'Missing: ${states['basic']!.missing.join(', ')}'),
        ]),
        section('Documents', [
          if (states['documents']!.missing.isNotEmpty) check(false, 'Missing: ${states['documents']!.missing.join(', ')}'),
          for (final d in docs)
            Row(children: [
              Expanded(child: Text('${d['doc_type']}'.replaceAll('_', ' '))),
              AppBadge(status: d['status'] as String),
            ]),
          if (docs.isEmpty) const Text('No documents uploaded'),
        ]),
        section('Seat layout', [
          Text('Total seats: ${seats.length} · Configured: ${seats.length} · Available for booking: $bookable'),
          check(states['seats']!.ok, states['seats']!.ok ? 'Layout is valid' : 'Layout needs attention'),
          for (final e in List<String>.from(((comp['details'] as Map?)?['seats'] as List?) ?? const [])) Text('• $e', style: TextStyle(color: theme.colorScheme.error)),
        ]),
        section('Route', [
          if (service == null) const Text('No route yet') else ...[
            Text('${stops.isEmpty ? '—' : stops.first.name} → ${stops.isEmpty ? '—' : stops.last.name}'),
            Text('${stops.length} stops · ${boarding.length} boarding · ${dropping.length} dropping points'),
          ],
          check(states['route']!.ok, states['route']!.ok ? 'Route is complete' : 'Route needs attention'),
          for (final e in List<String>.from(((comp['details'] as Map?)?['route'] as List?) ?? const [])) Text('• $e', style: TextStyle(color: theme.colorScheme.error)),
        ]),
        section('Fare', [
          if (fares != null)
            for (final r in List<Map<String, dynamic>>.from(fares['rules'] as List).where((r) => r['from_boarding_point_id'] == null && r['to_dropping_point_id'] == null && r['seat_category'] == null))
              Text('${r['seat_type']}${r['berth'] != null ? ' (${r['berth']})' : ''}: ${formatRupees(r['base_fare_cents'] as int)}'),
          if (fares != null) Text('${(fares['rules'] as List).length} fare rules · ${(fares['charges'] as List).length} extra charges'),
          check(states['fare']!.ok, states['fare']!.ok ? 'Fares configured' : 'Fares need attention'),
          for (final e in List<String>.from(((comp['details'] as Map?)?['fare'] as List?) ?? const [])) Text('• $e', style: TextStyle(color: theme.colorScheme.error)),
        ]),
        section('Schedule', [
          if (service != null) ...[
            Text('Departs ${(service['default_departure_time'] as String).substring(0, 5)} · journey ${formatDuration(service['est_duration_min'] as int?)}'),
            Text(describeOperatingDays({for (final d in (service['operating_days'] as List)) (d as num).toInt()})),
          ],
          check(states['schedule']!.ok, states['schedule']!.ok ? 'Schedule confirmed' : 'Schedule needs attention'),
        ]),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: AppSpacing.md),
        if (actions.contains(BusAction.submit))
          AppButton(
            label: BusAction.submit.label,
            expand: true,
            loading: _busy,
            onPressed: _busy
                ? null
                : () => _confirm(
                      'Submit for approval?',
                      bus['is_legacy'] == true
                          ? 'An admin will review this bus. It stays in service while the review is in progress.'
                          : 'You will not be able to change core details while the bus is under review.',
                      () => _run('submit_bus', 'Submitted for approval.'),
                    ),
          ),
        if (actions.contains(BusAction.activate))
          AppButton(
            label: BusAction.activate.label,
            expand: true,
            loading: _busy,
            onPressed: (_busy || (readiness != null && readiness['ready'] != true)) ? null : () => _run('activate_bus', 'The bus is now active and bookable.'),
          ),
        if (actions.contains(BusAction.deactivate))
          AppButton(
            label: BusAction.deactivate.label,
            variant: AppButtonVariant.outline,
            expand: true,
            onPressed: _busy
                ? null
                : () => _confirm('Deactivate this bus?', 'It will no longer be bookable. You can reactivate it later.', () => _run('deactivate_bus', 'The bus was deactivated.')),
          ),
      ],
    );
  }
}
