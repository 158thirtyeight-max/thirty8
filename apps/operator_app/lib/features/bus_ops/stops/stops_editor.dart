import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'stop_schedule.dart';
import 'stop_sheet.dart';

/// "Route & stops" section of the service form: the ordered list of
/// intermediate stops, each opened in [showStopSheet] for editing. Holds no
/// state of its own — [stops] belongs to the form, which saves them together
/// with the schedule.
class StopsEditor extends StatelessWidget {
  const StopsEditor({
    super.key,
    required this.stops,
    required this.cities,
    required this.totalMinutes,
    required this.departureMinuteOfDay,
    required this.onChanged,
  });

  final List<StopDraft> stops;

  /// Cities a stop may use (origin and destination already excluded).
  final List<Map<String, dynamic>> cities;
  final int totalMinutes;
  final int departureMinuteOfDay;
  final ValueChanged<List<StopDraft>> onChanged;

  int _prevDeparture(int index) => index == 0 ? 0 : stops[index - 1].departureOffset;
  int? _nextArrival(int index) => index + 1 < stops.length ? stops[index + 1].arrivalOffset : null;

  Future<void> _edit(BuildContext context, int index) async {
    final result = await showStopSheet(
      context,
      initial: stops[index],
      stopNumber: index + 1,
      cities: cities,
      prevDeparture: _prevDeparture(index),
      nextArrival: _nextArrival(index),
      totalMinutes: totalMinutes,
      departureMinuteOfDay: departureMinuteOfDay,
    );
    if (result == null) return;
    final next = [...stops];
    if (result.delete) {
      next.removeAt(index);
    } else {
      next[index] = result.stop!;
    }
    onChanged(next);
  }

  Future<void> _add(BuildContext context) async {
    if (cities.isEmpty) return _notify(context, 'No cities available for stops');
    // Start 30 minutes after the previous stop leaves, or a third of the way in,
    // whichever fits; refuse when the journey is already full.
    final prev = stops.isEmpty ? 0 : stops.last.departureOffset;
    final defaultDuration = 2;
    final room = totalMinutes - prev - defaultDuration - 1;
    if (room < 1) return _notify(context, 'No room for another stop before the destination');
    final arrival = stops.isEmpty ? (totalMinutes ~/ 3).clamp(1, room) : (prev + 30 > totalMinutes - defaultDuration - 1 ? prev + 1 : prev + 30);
    final used = stops.map((s) => s.locationCityId).toSet();
    final city = cities.firstWhere((c) => !used.contains(c['id']), orElse: () => cities.first);
    final draft = StopDraft(
      locationCityId: city['id'] as String,
      locationName: city['name'] as String,
      arrivalOffset: stops.isEmpty ? arrival.clamp(1, room) : arrival,
      durationMinutes: defaultDuration,
    );
    final result = await showStopSheet(
      context,
      initial: draft,
      stopNumber: stops.length + 1,
      cities: cities,
      prevDeparture: prev,
      nextArrival: null,
      totalMinutes: totalMinutes,
      departureMinuteOfDay: departureMinuteOfDay,
    );
    if (result == null || result.delete) return;
    onChanged([...stops, result.stop!]);
  }

  void _notify(BuildContext context, String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stops.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text('Non-stop service. Add intermediate stops where passengers can board, get off or take a break.', style: theme.textTheme.bodySmall),
          ),
        for (var i = 0; i < stops.length; i++)
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: InkWell(
              onTap: () => _edit(context, i),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('Stop ${i + 1} · ${stops[i].locationName}', style: theme.textTheme.titleSmall)),
                        const Icon(Icons.edit_outlined, size: 18),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Arrives ${clockLabel(departureMinuteOfDay, stops[i].arrivalOffset)} · leaves ${clockLabel(departureMinuteOfDay, stops[i].departureOffset)} (${durationLabel(stops[i].durationMinutes)})',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        if (stops[i].allowsPickup) const Chip(label: Text('Pickup'), visualDensity: VisualDensity.compact),
                        if (stops[i].allowsDrop) const Chip(label: Text('Drop'), visualDensity: VisualDensity.compact),
                        for (final l in StopCatalog.customerLabels(
                          purposes: stops[i].purposes.toList(),
                          mealTypes: stops[i].mealTypes.toList(),
                          refreshmentTypes: stops[i].refreshmentTypes.toList(),
                        ))
                          Chip(label: Text(l), visualDensity: VisualDensity.compact),
                        for (final l in StopCatalog.facilityLabels(stops[i].facilities.toList()))
                          Chip(avatar: const Icon(Icons.check, size: 14), label: Text(l), visualDensity: VisualDensity.compact),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: () => _add(context), icon: const Icon(Icons.add_location_alt_outlined), label: const Text('Add stop')),
        ),
      ],
    );
  }
}
