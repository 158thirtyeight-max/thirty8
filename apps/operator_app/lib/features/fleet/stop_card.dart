import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'route_model.dart';

/// One stop of a bus route. Every stop is an admin-managed main location; the
/// exact pickup / drop point inside it is picked from the master list, filtered
/// by the stop's boarding / dropping flags. Operators cannot type new places.
class StopCard extends StatelessWidget {
  const StopCard({
    super.key,
    required this.stop,
    required this.label,
    required this.showArrival,
    required this.showDeparture,
    required this.lockBoarding,
    required this.lockDropping,
    required this.lockLocation,
    required this.enabled,
    required this.cities,
    required this.points,
    required this.onPickTime,
    required this.onChanged,
    this.onRemove,
    this.dragIndex,
  });

  final RouteStop stop;
  final String label;
  final bool showArrival;
  final bool showDeparture;
  final bool lockBoarding;
  final bool lockDropping;

  /// Origin / destination follow the city pickers at the top of the screen.
  final bool lockLocation;
  final bool enabled;

  /// Active main locations, in admin order.
  final List<Map<String, dynamic>> cities;

  /// Active master pickup / drop points of every main location.
  final List<Map<String, dynamic>> points;
  final void Function(bool arrival) onPickTime;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final int? dragIndex;

  String _cityName(String? id) => cities.firstWhere((c) => c['id'] == id, orElse: () => const {})['name'] as String? ?? '';

  /// Points of this stop's location that allow what the stop is used for.
  List<Map<String, dynamic>> get _options => [
        for (final p in points)
          if (p['main_location_id'] == stop.cityId &&
              (!stop.isBoarding || p['is_pickup_allowed'] == true) &&
              (!stop.isDropping || p['is_drop_allowed'] == true))
            p,
      ];

  /// Falls back to the location itself when the chosen point no longer fits the stop's flags.
  void _revalidatePoint() {
    if (stop.masterPointId != null && !_options.any((p) => p['id'] == stop.masterPointId)) {
      stop
        ..masterPointId = null
        ..name = _cityName(stop.cityId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = _options;
    final legacyName = stop.masterPointId == null && stop.name.trim().isNotEmpty && stop.name.trim() != _cityName(stop.cityId);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (dragIndex != null && enabled)
                  ReorderableDragStartListener(index: dragIndex!, child: const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.drag_handle))),
                Expanded(child: Text(label, style: theme.textTheme.labelLarge)),
                if (onRemove != null && enabled) IconButton(onPressed: onRemove, icon: const Icon(Icons.delete_outline)),
              ],
            ),
            if (lockLocation)
              Text(
                stop.cityId == null ? 'Choose the ${label.toLowerCase()} city above' : _cityName(stop.cityId),
                style: theme.textTheme.titleSmall,
              )
            else
              DropdownButtonFormField<String>(
                key: ValueKey('loc-${stop.cityId}'),
                initialValue: cities.any((c) => c['id'] == stop.cityId) ? stop.cityId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Main location'),
                items: [for (final c in cities) DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String))],
                onChanged: enabled
                    ? (v) {
                        stop
                          ..cityId = v
                          ..masterPointId = null
                          ..name = _cityName(v);
                        onChanged();
                      }
                    : null,
              ),
            if (stop.cityId != null) ...[
              const SizedBox(height: AppSpacing.xs),
              if (options.isEmpty)
                Text(
                  'No pickup / drop points are set up for ${_cityName(stop.cityId)} yet, so this stop uses the location itself.',
                  style: theme.textTheme.bodySmall,
                )
              else
                DropdownButtonFormField<String?>(
                  key: ValueKey('pt-${stop.cityId}-${stop.masterPointId}-${stop.isBoarding}-${stop.isDropping}'),
                  initialValue: options.any((p) => p['id'] == stop.masterPointId) ? stop.masterPointId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Pickup / drop point'),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('${_cityName(stop.cityId)} (location only)')),
                    for (final p in options)
                      DropdownMenuItem<String?>(
                        value: p['id'] as String,
                        child: Text(
                          (p['landmark'] as String?)?.trim().isNotEmpty == true ? '${p['name']} · ${p['landmark']}' : p['name'] as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: enabled
                      ? (v) {
                          stop.masterPointId = v;
                          stop.name = v == null ? _cityName(stop.cityId) : options.firstWhere((p) => p['id'] == v)['name'] as String;
                          onChanged();
                        }
                      : null,
                ),
            ],
            if (legacyName)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text('Current stop name: ${stop.name}', style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                FilterChip(
                  label: const Text('Boarding'),
                  selected: stop.isBoarding,
                  onSelected: (enabled && !lockBoarding)
                      ? (v) {
                          stop.isBoarding = v;
                          _revalidatePoint();
                          onChanged();
                        }
                      : null,
                ),
                FilterChip(
                  label: const Text('Dropping'),
                  selected: stop.isDropping,
                  onSelected: (enabled && !lockDropping)
                      ? (v) {
                          stop.isDropping = v;
                          _revalidatePoint();
                          onChanged();
                        }
                      : null,
                ),
              ],
            ),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                if (showArrival)
                  OutlinedButton(
                    onPressed: enabled ? () => onPickTime(true) : null,
                    child: Text('Arrive ${formatClock(stop.arrivalMin)}'),
                  ),
                if (showDeparture)
                  OutlinedButton(
                    onPressed: enabled ? () => onPickTime(false) : null,
                    child: Text('Depart ${formatClock(stop.departureMin)}'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
