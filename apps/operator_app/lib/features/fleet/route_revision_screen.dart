import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/supabase_providers.dart';
import '../bus_ops/route_summary.dart';
import 'fleet_providers.dart';
import 'journey_editor.dart';
import 'route_model.dart';
import 'stop_schedule.dart';

/// Edits a bus's route as a *revision*. Nothing here changes the live route:
///  - while the bus is still being set up (draft / changes requested) "Save & apply route" applies the
///    route directly (the bus itself still goes through admin approval);
///  - once the bus is approved, "Submit for approval" sends the revision to an admin and the current
///    route stays live until it is approved.
/// A route is one journey (one way) or two linked journeys (round trip), each with its own stops,
/// departure time and operating days.
class RouteRevisionScreen extends ConsumerStatefulWidget {
  const RouteRevisionScreen({
    super.key,
    required this.operatorId,
    required this.bus,
    this.isOperatorAdmin = true,
    this.revisionId,
    this.baseRevisionId,
    this.startWithReturn = false,
  });

  final String operatorId;
  final Map<String, dynamic> bus;

  /// Submitting a change for an approved bus needs an operator administrator.
  final bool isOperatorAdmin;

  /// Continue this draft; when null a draft is started (or the open one resumed).
  final String? revisionId;

  /// Start the new draft from this earlier revision (resubmitting a rejected one).
  final String? baseRevisionId;

  /// Open with the round-trip return journey configured.
  final bool startWithReturn;

  @override
  ConsumerState<RouteRevisionScreen> createState() => _RouteRevisionScreenState();
}

class _RouteRevisionScreenState extends ConsumerState<RouteRevisionScreen> {
  String? _revisionId;
  String _tripType = 'one_way';
  JourneyDraft _out = JourneyDraft();
  JourneyDraft? _ret;
  String _status = 'draft';
  int _step = 0;
  final TextEditingController _nameCtl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _namesSynced = false;
  String? _loadError;
  String? _error;
  List<String> _problems = const [];

  String get _busId => widget.bus['id'] as String;

  bool get _setupStage {
    final lifecycle = widget.bus['lifecycle_status'] as String?;
    return lifecycle == 'draft' || lifecycle == 'changes_requested';
  }

  bool get _editable => _status == 'draft' && !_saving;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final db = ref.read(supabaseProvider);
    try {
      final id = widget.revisionId ??
          (await db.rpc('start_route_revision', params: {
            'p_bus_id': _busId,
            'p_base_revision_id': widget.baseRevisionId,
          })) as String;
      final rev = await db
          .from('route_revisions')
          .select('*, route_revision_journeys(*, route_revision_stops(*, location:locations(name)))')
          .eq('id', id)
          .single();
      final journeys = List<Map<String, dynamic>>.from(rev['route_revision_journeys'] as List);
      final out = journeys.where((j) => j['direction'] == 'outbound').firstOrNull;
      final ret = journeys.where((j) => j['direction'] == 'return').firstOrNull;
      if (!mounted) return;
      setState(() {
        _revisionId = id;
        _status = rev['status'] as String;
        _tripType = rev['trip_type'] as String;
        _nameCtl.text = (rev['name'] as String?) ?? '';
        _out = out == null ? JourneyDraft() : journeyFromRevision(out);
        _ret = ret == null ? null : journeyFromRevision(ret);
        if (widget.startWithReturn && _status == 'draft') {
          _enableReturn();
          _step = 2;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e is PostgrestException ? e.message : 'Could not open the route editor.';
        _loading = false;
      });
    }
  }

  void _touch() => setState(() {
        _dirty = true;
        _problems = const [];
        _error = null;
      });

  /// A new return journey runs the other way: B -> A.
  void _enableReturn() {
    _tripType = 'round_trip';
    _ret ??= JourneyDraft(sourceId: _out.destId, destId: _out.sourceId, stops: [
      RouteStop(name: '', isBoarding: true, cityId: _out.destId),
      RouteStop(name: '', isDropping: true, cityId: _out.sourceId),
    ]);
  }

  Set<int> _shiftDays(Set<int> days, int by) => {for (final d in days) ((d - 1 + by) % 7) + 1};

  /// Builds the return journey from the outbound one (reverse stops, mirrored times). The result is an
  /// ordinary return journey: its stops, times and days stay editable and independent.
  void _generateReverse() {
    if (!_out.hasWindow) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Set the outbound departure and arrival times first.')));
      return;
    }
    final previous = _ret;
    final keepWindow = previous != null && previous.hasWindow;
    final arrivesNextDay = _out.startMin! + _out.durationMin! >= minutesPerDay;
    final offset = previous != null && previous.startMin != null ? previous.departureDayOffset : (arrivesNextDay ? 1 : 0);
    // The reverse route never copies the outbound clock times: it mirrors the stops and stop times and the
    // return keeps (or is given) its own departure and arrival.
    final reversed = reverseJourney(_out)
      ..departureDayOffset = offset
      ..days = previous != null && previous.startMin != null && previous.days.isNotEmpty ? previous.days : _shiftDays(_out.days, offset);
    if (keepWindow) {
      reversed
        ..startMin = previous.startMin
        ..durationMin = previous.durationMin
        ..autoSchedule();
    }
    setState(() {
      _tripType = 'round_trip';
      _ret = reversed;
      _dirty = true;
      _problems = const [];
    });
    if (!keepWindow) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reverse route created. Now set the return departure and arrival times.')));
    }
  }

  void _setDayOffset(int offset) {
    final r = _ret;
    if (r == null) return;
    r.days = _shiftDays(r.days, offset - r.departureDayOffset);
    r.departureDayOffset = offset;
    _touch();
  }

  Map<String, dynamic> _payload(List<Map<String, dynamic>> cities) {
    String? nameOf(String? id) => cities.where((c) => c['id'] == id).map((c) => c['name'] as String).firstOrNull;
    final from = nameOf(_out.sourceId);
    final to = nameOf(_out.destId);
    return {
      'trip_type': _tripType,
      if (_nameCtl.text.trim().isNotEmpty) 'name': _nameCtl.text.trim() else if (from != null && to != null) 'name': '$from to $to',
      'outbound': journeyToPayload(_out),
      if (_tripType == 'round_trip' && _ret != null) 'return': journeyToPayload(_ret!),
    };
  }

  List<String> _localProblems() {
    final out = <String>[
      for (final e in _out.validate()) 'Outbound: $e',
    ];
    if (_tripType == 'round_trip') {
      final r = _ret;
      if (r == null) {
        out.add('Return: configure the return journey');
      } else {
        out.addAll([for (final e in r.validate()) 'Return: $e']);
        if (r.sourceId != _out.destId || r.destId != _out.sourceId) {
          out.add('Return: it must start where the outbound ends and end where it starts');
        }
      }
    }
    return out;
  }

  String _message(Object e) => e is PostgrestException ? e.message : 'Something went wrong. Please try again.';

  /// Saves the draft. Drafts may be incomplete; the server's validation is shown but does not block.
  Future<bool> _saveDraft(List<Map<String, dynamic>> cities) async {
    final conflicts = [
      for (final c in _out.scheduleConflicts()) 'Outbound: ${c.message}',
      if (_tripType == 'round_trip' && _ret != null)
        for (final c in _ret!.scheduleConflicts()) 'Return: ${c.message}',
    ];
    if (conflicts.isNotEmpty) {
      setState(() {
        _problems = conflicts;
        _error = 'Fix the stop times shown in red before saving.';
      });
      return false;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await ref.read(supabaseProvider).rpc('save_route_revision', params: {
        'p_revision_id': _revisionId,
        'p_payload': _payload(cities),
      });
      final map = Map<String, dynamic>.from(res as Map);
      final errors = List<Map<String, dynamic>>.from(map['errors'] as List);
      setState(() {
        _dirty = false;
        _problems = [
          for (final e in errors) '${e['direction'] == 'return' ? 'Return' : 'Outbound'}: ${e['message']}',
        ];
      });
      ref.invalidate(operatorRouteSummariesProvider(widget.operatorId));
      return true;
    } catch (e) {
      setState(() => _error = _message(e));
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _askReason() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit for approval'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your current route stays live until an admin approves this change. Tell the admin why it is needed.'),
            const SizedBox(height: AppSpacing.sm),
            AppTextField(controller: controller, label: 'Reason for the change'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Submit')),
        ],
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<void> _submit(List<Map<String, dynamic>> cities) async {
    final local = _localProblems();
    if (local.isNotEmpty) {
      setState(() => _problems = local);
      return;
    }
    String? reason;
    if (!_setupStage) {
      reason = await _askReason();
      if (reason == null) return;
      if (reason.isEmpty) {
        setState(() => _error = 'A reason for the change is required.');
        return;
      }
    }
    if (!await _saveDraft(cities)) return;
    setState(() => _saving = true);
    try {
      final res = await ref.read(supabaseProvider).rpc('submit_route_revision', params: {
        'p_revision_id': _revisionId,
        'p_reason': reason,
      });
      final map = Map<String, dynamic>.from(res as Map);
      if (map['ok'] != true) {
        final errors = List<Map<String, dynamic>>.from((map['errors'] as List?) ?? const []);
        setState(() => _problems = [
              for (final e in errors) '${e['direction'] == 'return' ? 'Return' : 'Outbound'}: ${e['message']}',
            ]);
        return;
      }
      ref.invalidate(operatorRouteSummariesProvider(widget.operatorId));
      ref.invalidate(busRouteProvider(_busId));
      ref.invalidate(busCompletenessProvider(_busId));
      if (!mounted) return;
      final applied = map['applied'] == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(applied ? 'Route saved.' : 'Submitted. Your current route stays live until an admin approves the change.'),
      ));
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _withdraw() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this draft?'),
        content: const Text('Your live route is not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(supabaseProvider).rpc('withdraw_route_revision', params: {'p_revision_id': _revisionId});
      ref.invalidate(operatorRouteSummariesProvider(widget.operatorId));
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final citiesAsync = ref.watch(citiesProvider);
    final locationsAsync = ref.watch(stopLocationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Route & stops'),
        actions: [
          if (_status == 'draft' && _revisionId != null && !_setupStage)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'discard') _withdraw();
              },
              itemBuilder: (_) => const [PopupMenuItem(value: 'discard', child: Text('Discard draft'))],
            ),
        ],
      ),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (_loadError != null) return AppErrorState(message: _loadError!, onRetry: () => setState(() { _loadError = null; _loading = true; _init(); }));
          if (citiesAsync.hasError || locationsAsync.hasError) {
            return AppErrorState(message: 'Could not load locations.', onRetry: () { ref.invalidate(citiesProvider); ref.invalidate(stopLocationsProvider); });
          }
          if (_loading || !citiesAsync.hasValue || !locationsAsync.hasValue) return const AppLoadingState();
          final cities = citiesAsync.requireValue;
          final locations = locationsAsync.requireValue;
          if (!_namesSynced) {
            _namesSynced = true;
            syncStopNames(_out.stops, locations);
            if (_ret != null) syncStopNames(_ret!.stops, locations);
          }
          return _body(context, cities, locations);
        }),
      ),
    );
  }

  int get _lastStep => _tripType == 'round_trip' ? 2 : 1;

  Widget _stepHeader(BuildContext context) {
    final theme = Theme.of(context);
    final labels = ['Journey', 'Stops', if (_tripType == 'round_trip') 'Return'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
          InkWell(
            onTap: () => setState(() => _step = i),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: i == _step ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
                  child: Text('${i + 1}', style: TextStyle(fontSize: 12, color: i == _step ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
                ),
                const SizedBox(width: 4),
                Text(labels[i], style: theme.textTheme.labelLarge?.copyWith(fontWeight: i == _step ? FontWeight.w700 : FontWeight.w400)),
              ]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _stepJourney(BuildContext context, List<Map<String, dynamic>> cities, List<Map<String, dynamic>> locations, bool edit) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Journey type', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'one_way', label: Text('One way')),
            ButtonSegment(value: 'round_trip', label: Text('Round trip')),
          ],
          selected: {_tripType},
          onSelectionChanged: edit
              ? (s) => setState(() {
                    _dirty = true;
                    if (s.first == 'round_trip') {
                      _enableReturn();
                    } else {
                      _tripType = 'one_way';
                    }
                  })
              : null,
        ),
        const SizedBox(height: AppSpacing.md),
        AppTextField(controller: _nameCtl, label: 'Route name', enabled: edit, onChanged: (_) => _touch()),
        const SizedBox(height: AppSpacing.md),
        JourneyEditor(
          draft: _out,
          cities: cities,
          locations: locations,
          enabled: edit,
          onChanged: _touch,
          idPrefix: 'out-',
          section: JourneySection.setup,
        ),
        if (_tripType == 'round_trip')
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: Text('The return journey has its own schedule: you set it in the Return step.', style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }

  Widget _stepStops(BuildContext context, List<Map<String, dynamic>> cities, List<Map<String, dynamic>> locations, bool edit) {
    return JourneyEditor(
      draft: _out,
      cities: cities,
      locations: locations,
      enabled: edit,
      onChanged: _touch,
      idPrefix: 'out-',
      section: JourneySection.stops,
    );
  }

  Widget _stepReturn(BuildContext context, List<Map<String, dynamic>> cities, List<Map<String, dynamic>> locations, bool edit) {
    final theme = Theme.of(context);
    final ret = _ret;
    if (ret == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The return is its own journey: it has its own stops, departure time and operating days, and may leave the same day or later.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (edit)
          AppButton(label: 'Generate reverse route', variant: AppButtonVariant.outline, icon: Icons.swap_vert, expand: true, onPressed: _generateReverse),
        const SizedBox(height: AppSpacing.sm),
        Text('Return departs', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Same day')),
            ButtonSegment(value: 1, label: Text('Next day')),
            ButtonSegment(value: 2, label: Text('+2 days')),
          ],
          selected: {ret.departureDayOffset.clamp(0, 2)},
          onSelectionChanged: edit ? (s) => _setDayOffset(s.first) : null,
        ),
        const SizedBox(height: AppSpacing.md),
        JourneyEditor(draft: ret, cities: cities, locations: locations, enabled: edit, onChanged: _touch, idPrefix: 'ret-', section: JourneySection.setup),
        const SizedBox(height: AppSpacing.md),
        JourneyEditor(draft: ret, cities: cities, locations: locations, enabled: edit, onChanged: _touch, idPrefix: 'ret-', section: JourneySection.stops),
      ],
    );
  }

  Widget _body(BuildContext context, List<Map<String, dynamic>> cities, List<Map<String, dynamic>> locations) {
    final theme = Theme.of(context);
    final edit = _editable;
    final canSubmit = _setupStage || widget.isOperatorAdmin;
    final step = _step.clamp(0, _lastStep);
    final atEnd = step == _lastStep;

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        AppCard(
          child: Text(
            _setupStage
                ? 'This bus is still being set up, so saving applies the route directly.'
                : 'Changes are sent to an admin for approval. Your current route stays live and unchanged until the change is approved.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (_status != 'draft')
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text('This revision is $_status and can no longer be edited.', style: TextStyle(color: theme.colorScheme.error)),
          ),
        const SizedBox(height: AppSpacing.md),
        _stepHeader(context),
        const SizedBox(height: AppSpacing.md),
        switch (step) {
          0 => _stepJourney(context, cities, locations, edit),
          1 => _stepStops(context, cities, locations, edit),
          _ => _stepReturn(context, cities, locations, edit),
        },
        const SizedBox(height: AppSpacing.md),
        if (_problems.isNotEmpty)
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in _problems)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 4),
                      Expanded(child: Text(p, style: TextStyle(color: theme.colorScheme.error))),
                    ]),
                  ),
              ],
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            if (step > 0)
              Expanded(child: AppButton(label: 'Back', variant: AppButtonVariant.outline, onPressed: () => setState(() => _step = step - 1))),
            if (step > 0 && !atEnd) const SizedBox(width: AppSpacing.sm),
            if (!atEnd) Expanded(child: AppButton(label: 'Next', onPressed: () => setState(() => _step = step + 1))),
          ],
        ),
        if (edit) ...[
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Save draft',
            variant: AppButtonVariant.outline,
            expand: true,
            onPressed: (_saving || !_dirty) ? null : () => _saveDraft(cities),
          ),
          if (atEnd) ...[
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: _setupStage ? 'Save & apply route' : 'Submit for approval',
              expand: true,
              loading: _saving,
              onPressed: (_saving || !canSubmit) ? null : () => _submit(cities),
            ),
            if (!canSubmit)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text('Only an operator administrator can submit route changes for approval.', style: theme.textTheme.bodySmall),
              ),
          ],
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}
