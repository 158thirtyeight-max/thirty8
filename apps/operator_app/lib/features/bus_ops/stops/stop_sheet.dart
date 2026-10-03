import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'stop_schedule.dart';

/// Outcome of the stop sheet: either an edited [stop] or a request to [delete].
class StopSheetResult {
  const StopSheetResult.saved(StopDraft this.stop) : delete = false;
  const StopSheetResult.deleted()
      : stop = null,
        delete = true;

  final StopDraft? stop;
  final bool delete;
}

/// Bottom sheet for configuring one intermediate stop. Works on a copy of
/// [initial]; nothing changes until Done is tapped.
Future<StopSheetResult?> showStopSheet(
  BuildContext context, {
  required StopDraft initial,
  required int stopNumber,
  required List<Map<String, dynamic>> cities,
  required int prevDeparture,
  required int? nextArrival,
  required int totalMinutes,
  required int departureMinuteOfDay,
}) {
  return showModalBottomSheet<StopSheetResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _StopSheet(
      initial: initial.copy(),
      stopNumber: stopNumber,
      cities: cities,
      prevDeparture: prevDeparture,
      nextArrival: nextArrival,
      totalMinutes: totalMinutes,
      departureMinuteOfDay: departureMinuteOfDay,
    ),
  );
}

class _StopSheet extends StatefulWidget {
  const _StopSheet({
    required this.initial,
    required this.stopNumber,
    required this.cities,
    required this.prevDeparture,
    required this.nextArrival,
    required this.totalMinutes,
    required this.departureMinuteOfDay,
  });

  final StopDraft initial;
  final int stopNumber;
  final List<Map<String, dynamic>> cities;
  final int prevDeparture;
  final int? nextArrival;
  final int totalMinutes;
  final int departureMinuteOfDay;

  @override
  State<_StopSheet> createState() => _StopSheetState();
}

class _StopSheetState extends State<_StopSheet> {
  static const _fineStep = 5;
  static const _basicDurations = [2, 5, 10, 15];
  static const _mealDurations = [20, 30, 45];

  late final StopDraft _stop = widget.initial;

  ArrivalWindow get _window => arrivalWindow(
        prevDeparture: widget.prevDeparture,
        nextArrival: widget.nextArrival,
        totalMinutes: widget.totalMinutes,
        durationMinutes: _stop.durationMinutes,
      );

  int get _maxDuration => maxDuration(arrivalOffset: _stop.arrivalOffset, nextArrival: widget.nextArrival, totalMinutes: widget.totalMinutes);

  String _clock(int offset) => clockLabel(widget.departureMinuteOfDay, offset);

  void _setArrival(num value) {
    final window = _window;
    if (window.isEmpty) return;
    setState(() => _stop.arrivalOffset = window.clamp(value.round()));
  }

  void _togglePurpose(String id) {
    setState(() {
      if (!_stop.purposes.remove(id)) _stop.purposes.add(id);
      _stop.pruneSubOptions();
      // Deliberately no duration change here: the operator stays in control.
    });
  }

  void _toggle(Set<String> set, String id) => setState(() => set.contains(id) ? set.remove(id) : set.add(id));

  void _togglePickupDrop({required bool pickup}) {
    setState(() {
      if (pickup) {
        if (_stop.allowsPickup && !_stop.allowsDrop) return; // keep at least one
        _stop.allowsPickup = !_stop.allowsPickup;
      } else {
        if (_stop.allowsDrop && !_stop.allowsPickup) return;
        _stop.allowsDrop = !_stop.allowsDrop;
      }
    });
  }

  Future<void> _customDuration() async {
    final controller = TextEditingController(text: _basicDurations.contains(_stop.durationMinutes) ? '' : '${_stop.durationMinutes}');
    final max = _maxDuration;
    final minutes = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Custom stop duration'),
        content: AppTextField(
          controller: controller,
          label: 'Minutes (1–$max)',
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              if (v != null && v >= 1 && v <= max) Navigator.pop(ctx, v);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (minutes != null) setState(() => _stop.durationMinutes = minutes);
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _chip(StopOption o, bool selected, VoidCallback onTap) => FilterChip(
        avatar: Icon(o.icon, size: 18),
        label: Text(o.label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      );

  Widget _durationChip(int minutes, int max) => ChoiceChip(
        label: Text('$minutes min'),
        selected: _stop.durationMinutes == minutes,
        onSelected: minutes > max ? null : (_) => setState(() => _stop.durationMinutes = minutes),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final window = _window;
    final total = widget.totalMinutes;
    final hasMeal = _stop.purposes.contains(StopCatalog.mealBreak);
    final hasTea = _stop.purposes.contains(StopCatalog.teaRefreshment);
    final maxDur = _maxDuration;
    final durations = [..._basicDurations, if (hasMeal) ..._mealDurations];
    final isCustom = !durations.contains(_stop.durationMinutes);
    final canSave = !window.isEmpty && _stop.locationCityId.isNotEmpty;
    final ticks = List.generate(5, (i) => (total * i / 4).round());

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Stop ${widget.stopNumber}', style: theme.textTheme.titleLarge)),
                      IconButton(
                        tooltip: 'Remove stop',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => Navigator.pop(context, const StopSheetResult.deleted()),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    initialValue: widget.cities.any((c) => c['id'] == _stop.locationCityId) ? _stop.locationCityId : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Location'),
                    items: widget.cities
                        .map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        _stop.locationCityId = v;
                        _stop.locationName = widget.cities.firstWhere((c) => c['id'] == v)['name'] as String;
                      });
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    children: [
                      FilterChip(label: const Text('Pickup'), selected: _stop.allowsPickup, onSelected: (_) => _togglePickupDrop(pickup: true)),
                      FilterChip(label: const Text('Drop'), selected: _stop.allowsDrop, onSelected: (_) => _togglePickupDrop(pickup: false)),
                    ],
                  ),

                  // Stop purpose & facilities (informational; never affects timing)
                  _heading('Stop Purpose & Facilities'),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [for (final o in StopCatalog.purposes) _chip(o, _stop.purposes.contains(o.id), () => _togglePurpose(o.id))],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    alignment: Alignment.topCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (hasMeal) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Text('Which meal?', style: theme.textTheme.labelLarge),
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.sm,
                            children: [for (final o in StopCatalog.mealTypes) _chip(o, _stop.mealTypes.contains(o.id), () => _toggle(_stop.mealTypes, o.id))],
                          ),
                        ],
                        if (hasTea) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Text('Serving (optional)', style: theme.textTheme.labelLarge),
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.sm,
                            children: [
                              for (final o in StopCatalog.refreshmentTypes) _chip(o, _stop.refreshmentTypes.contains(o.id), () => _toggle(_stop.refreshmentTypes, o.id))
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text('Facilities available (optional)', style: theme.textTheme.labelLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [for (final o in StopCatalog.facilities) _chip(o, _stop.facilities.contains(o.id), () => _toggle(_stop.facilities, o.id))],
                  ),

                  // Arrival time
                  _heading('Bus arrives'),
                  Center(
                    child: Text(
                      _clock(_stop.arrivalOffset),
                      style: theme.textTheme.displaySmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Departs ${_clock(0)}', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                      Text('Arrives ${_clock(total)}', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                    ],
                  ),
                  Slider(
                    min: 0,
                    max: total.toDouble(),
                    value: _stop.arrivalOffset.clamp(0, total).toDouble(),
                    onChanged: window.isEmpty ? null : _setArrival,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [for (final t in ticks) Text(clockLabel(widget.departureMinuteOfDay, t).split(' ').first, style: theme.textTheme.labelSmall)],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        tooltip: 'Earlier',
                        icon: const Icon(Icons.remove),
                        onPressed: window.isEmpty || _stop.arrivalOffset <= window.min ? null : () => _setArrival(_stop.arrivalOffset - _fineStep),
                      ),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                          child: Text('fine adjust · $_fineStep min', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: 'Later',
                        icon: const Icon(Icons.add),
                        onPressed: window.isEmpty || _stop.arrivalOffset >= window.max ? null : () => _setArrival(_stop.arrivalOffset + _fineStep),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      window.isEmpty
                          ? 'No room for this stop between the neighbouring stops — shorten the stop duration or move a neighbouring stop.'
                          : 'This stop can be placed between ${_clock(window.min)} and ${_clock(window.max)}.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),

                  // Duration
                  _heading('How long will the bus stop here?'),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final d in durations) _durationChip(d, maxDur),
                      ChoiceChip(
                        label: Text(isCustom ? 'Custom · ${_stop.durationMinutes} min' : 'Custom'),
                        selected: isCustom,
                        onSelected: (_) => _customDuration(),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      const Icon(Icons.directions_bus_outlined),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: 'Bus leaves at ${_clock(_stop.departureOffset)}', style: theme.textTheme.titleSmall),
                          TextSpan(text: '  (calculated)', style: theme.textTheme.bodySmall),
                        ])),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Pinned so Done is always reachable on small screens.
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.md),
            child: AppButton(
              label: 'Done',
              expand: true,
              onPressed: canSave ? () => Navigator.pop(context, StopSheetResult.saved(_stop)) : null,
            ),
          ),
        ],
      ),
    );
  }
}
