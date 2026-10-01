import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import 'route_model.dart';

/// One stop of a bus route. A stop is a location from the admin-managed master
/// list, referenced by id: the origin and destination follow the main-route
/// pickers at the top of the screen, intermediate stops are picked from every
/// active location that allows what the stop is used for (pickup and/or drop).
/// Operators cannot type new places.
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
    required this.locations,
    required this.takenIds,
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

  /// Every active location (id, name, location_code, is_pickup_enabled, is_drop_enabled), in admin order.
  final List<Map<String, dynamic>> locations;

  /// Locations already used by other stops of this route (a location appears once).
  final Set<String> takenIds;
  final void Function(bool arrival) onPickTime;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final int? dragIndex;

  Map<String, dynamic>? get _current => locations.cast<Map<String, dynamic>?>().firstWhere((l) => l!['id'] == stop.cityId, orElse: () => null);

  String _name(String? id) => locations.firstWhere((l) => l['id'] == id, orElse: () => const {})['name'] as String? ?? '';

  bool get _pickupOk => _current == null || _current!['is_pickup_enabled'] == true;
  bool get _dropOk => _current == null || _current!['is_drop_enabled'] == true;

  /// Stops can only be pickup / drop where the location allows it.
  void _clampFlags() {
    if (!_pickupOk && !lockBoarding) stop.isBoarding = false;
    if (!_dropOk && !lockDropping) stop.isDropping = false;
  }

  /// Locations offered for this stop: active, not used elsewhere on the route, and allowing
  /// pickup / drop as the stop requires. The stop's own current location is always listed.
  List<Map<String, dynamic>> get _options => [
        for (final l in locations)
          if (l['id'] == stop.cityId ||
              (!takenIds.contains(l['id']) &&
                  (!stop.isBoarding || l['is_pickup_enabled'] == true) &&
                  (!stop.isDropping || l['is_drop_enabled'] == true)))
            l,
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _current;
    final blocksPickup = current != null && !_pickupOk;
    final blocksDrop = current != null && !_dropOk;

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
                stop.cityId == null ? 'Choose the ${label.toLowerCase()} location above' : '${_name(stop.cityId)}  ·  ${current?['location_code'] ?? ''}',
                style: theme.textTheme.titleSmall,
              )
            else
              DropdownButtonFormField<String>(
                key: ValueKey('loc-${stop.cityId}-${stop.isBoarding}-${stop.isDropping}'),
                initialValue: _options.any((l) => l['id'] == stop.cityId) ? stop.cityId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Location'),
                items: [
                  for (final l in _options)
                    DropdownMenuItem(value: l['id'] as String, child: Text('${l['name']}  ·  ${l['location_code']}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: enabled
                    ? (v) {
                        stop
                          ..cityId = v
                          ..name = _name(v);
                        _clampFlags();
                        onChanged();
                      }
                    : null,
              ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                FilterChip(
                  label: const Text('Pickup'),
                  selected: stop.isBoarding,
                  onSelected: (enabled && !lockBoarding && !blocksPickup)
                      ? (v) {
                          stop.isBoarding = v;
                          onChanged();
                        }
                      : null,
                ),
                FilterChip(
                  label: const Text('Drop'),
                  selected: stop.isDropping,
                  onSelected: (enabled && !lockDropping && !blocksDrop)
                      ? (v) {
                          stop.isDropping = v;
                          onChanged();
                        }
                      : null,
                ),
              ],
            ),
            if (blocksPickup || blocksDrop)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  '${blocksPickup ? 'Pickup' : ''}${blocksPickup && blocksDrop ? ' and ' : ''}${blocksDrop ? 'Drop' : ''} is not enabled at ${_name(stop.cityId)}.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
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
