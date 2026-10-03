import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'operating_days_picker.dart';
import 'route_model.dart';
import 'stop_card.dart';
import 'stop_schedule.dart';
import 'time_ruler.dart';

/// The parts of a [JourneyEditor].
enum JourneySection { all, setup, stops }

/// Edits one direction of a route: starting point, destination, operating days, the journey window
/// (departure from the start, arrival at the destination) and the intermediate stops.
///
/// Stops are chosen by location only. Their times are scheduled on the timeline: each stop gets an
/// automatic estimated arrival, the operator drags it on a horizontal time ruler and picks how long the
/// bus stops; the departure is calculated (arrival + stop time). It edits [draft] in place and calls
/// [onChanged] after every edit. Used for the outbound journey and, independently, for the return.
class JourneyEditor extends StatelessWidget {
  const JourneyEditor({
    super.key,
    required this.draft,
    required this.cities,
    required this.locations,
    required this.enabled,
    required this.onChanged,
    this.idPrefix = '',
    this.section = JourneySection.all,
  });

  final JourneyDraft draft;

  /// Main-route locations: starting point and destination pickers.
  final List<Map<String, dynamic>> cities;

  /// Every active location with its pickup / drop flags: intermediate stops.
  final List<Map<String, dynamic>> locations;
  final bool enabled;
  final VoidCallback onChanged;

  /// Keeps dropdown keys of the two journeys on one screen apart.
  final String idPrefix;

  /// Which part to show: the route-builder steps show the setup fields and the stop timeline separately.
  final JourneySection section;

  List<RouteStop> get _stops => draft.stops;

  Set<String> _takenIds(RouteStop except) => {
        for (final s in _stops)
          if (!identical(s, except) && s.cityId != null) s.cityId!,
      };

  /// Every edit re-places the automatic estimates, then lets the screen rebuild / mark the draft dirty.
  void _changed() {
    draft.autoSchedule();
    onChanged();
  }

  Future<void> _pickEndpoint(BuildContext context, {required bool start}) async {
    final current = start ? draft.startMin : draft.endMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: current == null ? const TimeOfDay(hour: 6, minute: 0) : TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null) return;
    final m = picked.hour * 60 + picked.minute;
    start ? draft.setStart(m) : draft.setEnd(m);
    onChanged();
  }

  void _setCity({required bool source, required String? id}) {
    final name = cities.firstWhere((c) => c['id'] == id, orElse: () => const {})['name'] as String? ?? '';
    final stop = source ? _stops.first : _stops.last;
    if (source) {
      draft.sourceId = id;
    } else {
      draft.destId = id;
    }
    stop
      ..cityId = id
      ..name = name;
    _changed();
  }

  String _endLabel() {
    final end = draft.endMin;
    if (end == null) return 'Choose';
    final days = (draft.startMin! + draft.durationMin!) ~/ minutesPerDay;
    return '${formatClock(end)}${days > 0 ? ' (+$days day${days > 1 ? 's' : ''})' : ''}';
  }

  // ---- stop editor (bottom sheet) ----------------------------------------------------------------

  Future<void> _editStop(BuildContext context, int index) async {
    final stop = _stops[index];
    final first = index == 0;
    final last = index == _stops.length - 1;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, MediaQuery.of(sheetContext).viewInsets.bottom + AppSpacing.md),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StopCard(
                  stop: stop,
                  label: first ? 'Starting point' : (last ? 'Destination' : 'Stop $index'),
                  showArrival: !first,
                  showDeparture: !last,
                  showTimes: false,
                  lockBoarding: first,
                  lockDropping: last,
                  lockLocation: first || last,
                  locations: locations,
                  takenIds: _takenIds(stop),
                  enabled: enabled,
                  onRemove: (first || last)
                      ? null
                      : () {
                          _stops.remove(stop);
                          _changed();
                          Navigator.pop(sheetContext);
                        },
                  onPickTime: (_) {},
                  onChanged: () {
                    _changed();
                    setSheet(() {});
                  },
                ),
                if (first || last)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.schedule),
                    onPressed: (!enabled || (last && draft.startMin == null))
                        ? null
                        : () async {
                            await _pickEndpoint(sheetContext, start: first);
                            setSheet(() {});
                          },
                    label: Text(first
                        ? 'Departure time: ${draft.startMin == null ? 'choose' : formatClock(draft.startMin)}'
                        : 'Arrival time: ${_endLabel()}'),
                  )
                else
                  ..._timeControls(sheetContext, setSheet, stop, index),
                const SizedBox(height: AppSpacing.sm),
                AppButton(label: 'Done', expand: true, onPressed: () => Navigator.pop(sheetContext)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _timeControls(BuildContext context, StateSetter setSheet, RouteStop stop, int index) {
    final theme = Theme.of(context);
    if (!draft.hasWindow) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Text('Set the departure time and the destination arrival time first, then schedule this stop.', style: theme.textTheme.bodyMedium),
        ),
      ];
    }
    final bounds = draft.arrivalBounds(index)!;
    final arrival = (stop.arrivalOffset ?? bounds.min).clamp(bounds.min, bounds.max);
    final dur = draft.durationMin!;
    final custom = !dwellChoices.contains(stop.dwellMin);

    void setArrival(int v) {
      stop
        ..arrivalOffset = v.clamp(bounds.min, bounds.max)
        ..manualTime = true;
      _changed();
      setSheet(() {});
    }

    void setDwell(int d) {
      stop.dwellMin = d.clamp(1, maxDwellMin);
      _changed();
      setSheet(() {});
    }

    return [
      const SizedBox(height: AppSpacing.sm),
      Text('Bus arrives', style: theme.textTheme.labelLarge),
      Center(
        child: Text(draft.timeLabel(arrival), style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.primary)),
      ),
      TimeRuler(
        startMin: draft.startMin!,
        duration: dur,
        value: arrival,
        min: bounds.min,
        max: bounds.max,
        enabled: enabled,
        onChanged: setArrival,
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton.filledTonal(
            tooltip: '5 minutes earlier',
            onPressed: enabled && arrival - snapMinutes >= bounds.min ? () => setArrival(arrival - snapMinutes) : null,
            icon: const Icon(Icons.remove),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text('fine adjust · $snapMinutes min', style: theme.textTheme.bodySmall),
          const SizedBox(width: AppSpacing.sm),
          IconButton.filledTonal(
            tooltip: '5 minutes later',
            onPressed: enabled && arrival + snapMinutes <= bounds.max ? () => setArrival(arrival + snapMinutes) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      Text(
        'This stop can be placed between ${draft.timeLabel(bounds.min)} and ${draft.timeLabel(bounds.max)}.',
        style: theme.textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: AppSpacing.md),
      Text('How long will the bus stop here?', style: theme.textTheme.labelLarge),
      const SizedBox(height: AppSpacing.xs),
      Wrap(
        spacing: AppSpacing.sm,
        children: [
          for (final d in dwellChoices)
            ChoiceChip(label: Text('$d min'), selected: stop.dwellMin == d, onSelected: enabled ? (_) => setDwell(d) : null),
          ChoiceChip(label: const Text('Custom'), selected: custom, onSelected: enabled ? (_) => setDwell(custom ? stop.dwellMin : 20) : null),
        ],
      ),
      if (custom)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(onPressed: enabled && stop.dwellMin > 1 ? () => setDwell(stop.dwellMin - 1) : null, icon: const Icon(Icons.remove_circle_outline)),
            Text('${stop.dwellMin} minutes', style: theme.textTheme.titleMedium),
            IconButton(onPressed: enabled && stop.dwellMin < maxDwellMin ? () => setDwell(stop.dwellMin + 1) : null, icon: const Icon(Icons.add_circle_outline)),
          ],
        ),
      const SizedBox(height: AppSpacing.sm),
      Row(children: [
        const Icon(Icons.departure_board, size: 18),
        const SizedBox(width: 6),
        Text('Bus leaves at ${draft.timeLabel(arrival + stop.dwellMin)}', style: theme.textTheme.titleSmall),
        const SizedBox(width: 6),
        Text('(calculated)', style: theme.textTheme.bodySmall),
      ]),
    ];
  }

  // ---- journey setup step ------------------------------------------------------------------------

  Widget _setupSection(BuildContext context) {
    final theme = Theme.of(context);
    Widget cityDropdown(String label, String? value, bool source) => DropdownButtonFormField<String>(
          key: ValueKey('$idPrefix$label-$value'),
          initialValue: cities.any((c) => c['id'] == value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [for (final c in cities) DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String))],
          onChanged: enabled ? (v) => _setCity(source: source, id: v) : null,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        cityDropdown('Starting point', draft.sourceId, true),
        const SizedBox(height: AppSpacing.md),
        cityDropdown('Destination', draft.destId, false),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                onPressed: enabled ? () => _pickEndpoint(context, start: true) : null,
                label: Text('Departs ${draft.startMin == null ? '--:--' : formatClock(draft.startMin)}'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.flag_outlined),
                onPressed: (enabled && draft.startMin != null) ? () => _pickEndpoint(context, start: false) : null,
                label: Text('Arrives ${draft.endMin == null ? '--:--' : _endLabel()}'),
              ),
            ),
          ],
        ),
        if (draft.startMin == null)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('Set the departure time first, then the arrival time.', style: theme.textTheme.bodySmall)),
        const SizedBox(height: AppSpacing.md),
        Text('Operating days', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        OperatingDaysPicker(
          days: draft.days,
          enabled: enabled,
          onChanged: (d) {
            draft.days = d;
            onChanged();
          },
        ),
      ],
    );
  }

  // ---- stops step ------------------------------------------------------------------------------

  String _detail(int i) {
    final n = _stops.length;
    if (i == 0) return draft.startMin == null ? 'Set the departure time' : 'Departs ${formatClock(draft.startMin)}';
    if (i == n - 1) return (draft.startMin == null || draft.durationMin == null) ? 'Set the arrival time' : 'Arrives ${draft.timeLabel(draft.durationMin!)}';
    final a = _stops[i].arrivalOffset;
    if (!draft.hasWindow || a == null) return 'Time not scheduled yet';
    return 'Arr ${draft.timeLabel(a)} · stops ${_stops[i].dwellMin} min · Dep ${draft.timeLabel(a + _stops[i].dwellMin)}';
  }

  Widget _stopsSection(BuildContext context) {
    final theme = Theme.of(context);
    final n = _stops.length;
    final conflicts = {for (final c in draft.scheduleConflicts()) c.index: c.message};
    Widget tile(int i, {Widget? handle}) => JourneyStopTile(
          stop: _stops[i],
          sequence: i + 1,
          isFirst: i == 0,
          isLast: i == n - 1,
          detail: _detail(i),
          conflict: conflicts[i],
          onTap: () => _editStop(context, i),
          handle: handle,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Route timeline', style: theme.textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(
          draft.hasWindow
              ? 'Add stops by location. Tap a stop to set when the bus arrives and how long it stops.'
              : 'Set the departure and arrival times in step 1 to schedule the stops.',
          style: theme.textTheme.bodySmall,
        ),
        if (conflicts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('These stops need a correction:', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.error)),
                  for (final m in conflicts.values) Text('• $m', style: TextStyle(color: theme.colorScheme.error)),
                ],
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        tile(0),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (oldIndex, newIndex) {
            if (newIndex > oldIndex) newIndex -= 1;
            final moved = _stops.removeAt(oldIndex + 1);
            _stops.insert(newIndex + 1, moved);
            _changed();
          },
          children: [
            for (var i = 1; i < n - 1; i++)
              KeyedSubtree(
                key: ObjectKey(_stops[i]),
                child: tile(
                  i,
                  handle: enabled
                      ? ReorderableDragStartListener(index: i - 1, child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle)))
                      : null,
                ),
              ),
          ],
        ),
        if (enabled)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                _stops.insert(_stops.length - 1, RouteStop(name: '', isBoarding: true, isDropping: true));
                _changed();
                _editStop(context, _stops.length - 2);
              },
              icon: const Icon(Icons.add),
              label: const Text('Add stop'),
            ),
          ),
        tile(n - 1),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Journey time: ${formatDuration(draft.durationMin)} · Operating: ${describeOperatingDays(draft.days)}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return switch (section) {
      JourneySection.setup => _setupSection(context),
      JourneySection.stops => _stopsSection(context),
      JourneySection.all => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_setupSection(context), const SizedBox(height: AppSpacing.md), _stopsSection(context)],
        ),
    };
  }
}

/// One stop of the compact route timeline: sequence number, name, calculated times and boarding /
/// dropping status. The starting point and destination get a filled marker, intermediate stops a ring;
/// a stop whose time conflicts is highlighted. Tapping opens the stop editor.
class JourneyStopTile extends StatelessWidget {
  const JourneyStopTile({
    super.key,
    required this.stop,
    required this.sequence,
    required this.isFirst,
    required this.isLast,
    required this.detail,
    required this.onTap,
    this.conflict,
    this.handle,
  });

  final RouteStop stop;
  final int sequence;
  final bool isFirst;
  final bool isLast;
  final String detail;
  final String? conflict;
  final VoidCallback onTap;
  final Widget? handle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final endpoint = isFirst || isLast;
    final bad = conflict != null;
    final color = bad ? theme.colorScheme.error : theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  Expanded(child: Container(width: 2, color: isFirst ? Colors.transparent : color.withValues(alpha: 0.4))),
                  Container(
                    width: endpoint ? 16 : 12,
                    height: endpoint ? 16 : 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: endpoint ? color : theme.colorScheme.surface,
                      border: Border.all(color: color, width: 2),
                    ),
                  ),
                  Expanded(child: Container(width: 2, color: isLast ? Colors.transparent : color.withValues(alpha: 0.4))),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$sequence. ${stop.name.isEmpty ? 'Choose a location' : stop.name}${isFirst ? '  ·  Start' : (isLast ? '  ·  Destination' : '')}',
                      style: endpoint ? theme.textTheme.titleSmall : theme.textTheme.bodyLarge,
                    ),
                    Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: bad ? theme.colorScheme.error : null)),
                    Text(
                      [if (stop.isBoarding) 'Boarding', if (stop.isDropping) 'Dropping'].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            ?handle,
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
