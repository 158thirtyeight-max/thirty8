import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'fleet_providers.dart';
import 'operating_days_picker.dart';
import 'route_model.dart';

/// Stage D — route for this bus: origin, destination, ordered stops with
/// boarding / dropping flags and clock times, and operating days. Saved through
/// save_bus_route (which also creates the bus's service anchor).
class StageRouteScreen extends ConsumerStatefulWidget {
  const StageRouteScreen({super.key, required this.operatorId, required this.bus});

  final String operatorId;
  final Map<String, dynamic> bus;

  @override
  ConsumerState<StageRouteScreen> createState() => _StageRouteScreenState();
}

class _StageRouteScreenState extends ConsumerState<StageRouteScreen> {
  String? _sourceId;
  String? _destId;
  final _distance = TextEditingController();
  final List<RouteStop> _stops = [
    RouteStop(name: '', isBoarding: true),
    RouteStop(name: '', isDropping: true),
  ];
  Set<int> _days = {1, 2, 3, 4, 5, 6, 7};
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  List<String> _serverErrors = const [];

  bool get _editable {
    final lifecycle = widget.bus['lifecycle_status'] as String?;
    return widget.bus['is_legacy'] == true || lifecycle == 'draft' || lifecycle == 'changes_requested';
  }

  @override
  void dispose() {
    _distance.dispose();
    super.dispose();
  }

  void _load(Map<String, dynamic> data, List<Map<String, dynamic>> cities) {
    if (_loaded) return;
    _loaded = true;
    final service = data['service'] as Map<String, dynamic>?;
    final route = data['route'] as Map<String, dynamic>?;
    if (service == null || route == null) return;

    _sourceId = route['source_city_id'] as String?;
    _destId = route['destination_city_id'] as String?;
    _distance.text = route['distance_km']?.toString() ?? '';
    _days = {for (final d in (service['operating_days'] as List? ?? const [1, 2, 3, 4, 5, 6, 7])) (d as num).toInt()};

    final dep = (service['default_departure_time'] as String? ?? '06:00:00').split(':');
    final depMin = int.parse(dep[0]) * 60 + int.parse(dep[1]);
    final stops = stopsFromPoints(
      boarding: List<Map<String, dynamic>>.from(data['boarding'] as List),
      dropping: List<Map<String, dynamic>>.from(data['dropping'] as List),
      departureMin: depMin,
    );
    if (stops.length >= 2) {
      _stops
        ..clear()
        ..addAll(stops);
    }
  }

  Future<void> _pickTime(RouteStop stop, {required bool arrival}) async {
    final current = arrival ? stop.arrivalMin : stop.departureMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: current == null ? const TimeOfDay(hour: 6, minute: 0) : TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked == null) return;
    setState(() {
      _dirty = true;
      final m = picked.hour * 60 + picked.minute;
      arrival ? stop.arrivalMin = m : stop.departureMin = m;
    });
  }

  void _setCity({required bool source, required String? id, required List<Map<String, dynamic>> cities}) {
    setState(() {
      _dirty = true;
      final name = cities.firstWhere((c) => c['id'] == id, orElse: () => const {})['name'] as String?;
      if (source) {
        _sourceId = id;
        if (name != null && _stops.first.name.trim().isEmpty) _stops.first.name = name;
        _stops.first.cityId = id;
      } else {
        _destId = id;
        if (name != null && _stops.last.name.trim().isEmpty) _stops.last.name = name;
        _stops.last.cityId = id;
      }
    });
  }

  Future<void> _save() async {
    final errors = validateRoute(sourceCityId: _sourceId, destinationCityId: _destId, stops: _stops, operatingDays: _days);
    if (errors.isNotEmpty) {
      setState(() => _serverErrors = errors);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _serverErrors = const [];
    });
    try {
      final dep = _stops.first.departureMin!;
      final res = await ref.read(supabaseProvider).rpc('save_bus_route', params: {
        'p_bus_id': widget.bus['id'],
        'p_source_city_id': _sourceId,
        'p_destination_city_id': _destId,
        'p_distance_km': double.tryParse(_distance.text.trim()),
        'p_departure_time': '${(dep ~/ 60).toString().padLeft(2, '0')}:${(dep % 60).toString().padLeft(2, '0')}:00',
        'p_duration_min': journeyDurationMin(_stops),
        'p_operating_days': (_days.toList()..sort()),
        'p_stops': stopsToJson(_stops),
      });
      final map = Map<String, dynamic>.from(res as Map);
      ref.invalidate(busRouteProvider(widget.bus['id'] as String));
      setState(() {
        _dirty = false;
        _loaded = false; // reload so new point ids are picked up
        _serverErrors = List<String>.from(map['errors'] as List);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_serverErrors.isEmpty ? 'Route saved.' : 'Saved — but the route still has issues to fix.'),
        ));
      }
    } catch (e) {
      setState(() => _error = e.toString().contains('locked')
          ? 'The route is locked while this bus is under review.'
          : 'Could not save the route. Please check the details and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routeAsync = ref.watch(busRouteProvider(widget.bus['id'] as String));
    final citiesAsync = ref.watch(citiesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Route & stops')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (routeAsync.hasError || citiesAsync.hasError) {
            return AppErrorState(
              message: 'Could not load the route.',
              onRetry: () {
                ref.invalidate(busRouteProvider(widget.bus['id'] as String));
                ref.invalidate(citiesProvider);
              },
            );
          }
          if (!routeAsync.hasValue || !citiesAsync.hasValue) return const AppLoadingState();
          final cities = citiesAsync.requireValue;
          _load(routeAsync.requireValue, cities);
          return _form(context, cities);
        }),
      ),
    );
  }

  Widget _form(BuildContext context, List<Map<String, dynamic>> cities) {
    final theme = Theme.of(context);
    final duration = journeyDurationMin(_stops);
    final edit = _editable && !_saving;

    Widget cityDropdown(String label, String? value, bool source) => DropdownButtonFormField<String>(
          initialValue: cities.any((c) => c['id'] == value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [for (final c in cities) DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String))],
          onChanged: edit ? (v) => _setCity(source: source, id: v, cities: cities) : null,
        );

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        if (!_editable) const Padding(padding: EdgeInsets.only(bottom: AppSpacing.sm), child: Text('This bus is under review or approved, so the route is read-only.')),
        cityDropdown('Origin city', _sourceId, true),
        const SizedBox(height: AppSpacing.md),
        cityDropdown('Destination city', _destId, false),
        const SizedBox(height: AppSpacing.md),
        AppTextField(
          controller: _distance,
          label: 'Distance in km (optional)',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          enabled: edit,
          onChanged: (_) => _dirty = true,
        ),
        const SizedBox(height: AppSpacing.md),
        Text('Operating days', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        OperatingDaysPicker(days: _days, enabled: edit, onChanged: (d) => setState(() { _days = d; _dirty = true; })),
        const SizedBox(height: AppSpacing.md),
        Text('Stops in travel order', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        _StopCard(
          key: ObjectKey(_stops.first),
          stop: _stops.first,
          label: 'Origin',
          showArrival: false,
          showDeparture: true,
          lockBoarding: true,
          lockDropping: false,
          enabled: edit,
          onPickTime: (arrival) => _pickTime(_stops.first, arrival: arrival),
          onChanged: () => setState(() => _dirty = true),
        ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (oldIndex, newIndex) {
            setState(() {
              _dirty = true;
              if (newIndex > oldIndex) newIndex -= 1;
              final moved = _stops.removeAt(oldIndex + 1);
              _stops.insert(newIndex + 1, moved);
            });
          },
          children: [
            for (var i = 1; i < _stops.length - 1; i++)
              _StopCard(
                key: ObjectKey(_stops[i]),
                stop: _stops[i],
                label: 'Stop $i',
                showArrival: true,
                showDeparture: true,
                lockBoarding: false,
                lockDropping: false,
                enabled: edit,
                cities: cities,
                dragIndex: i - 1,
                onRemove: () => setState(() { _dirty = true; _stops.removeAt(i); }),
                onPickTime: (arrival) => _pickTime(_stops[i], arrival: arrival),
                onChanged: () => setState(() => _dirty = true),
              ),
          ],
        ),
        if (edit)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _dirty = true;
                _stops.insert(_stops.length - 1, RouteStop(name: '', isBoarding: true, isDropping: true));
              }),
              icon: const Icon(Icons.add),
              label: const Text('Add intermediate stop'),
            ),
          ),
        _StopCard(
          key: ObjectKey(_stops.last),
          stop: _stops.last,
          label: 'Destination',
          showArrival: true,
          showDeparture: false,
          lockBoarding: false,
          lockDropping: true,
          enabled: edit,
          onPickTime: (arrival) => _pickTime(_stops.last, arrival: arrival),
          onChanged: () => setState(() => _dirty = true),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Estimated journey duration: ${formatDuration(duration)}', style: theme.textTheme.titleSmall),
              Text('Operating: ${describeOperatingDays(_days)}', style: theme.textTheme.bodySmall),
              const SizedBox(height: AppSpacing.xs),
              if (_serverErrors.isEmpty)
                Text('Enter every stop time; the duration is the time to the destination.', style: theme.textTheme.bodySmall)
              else
                for (final e in _serverErrors)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
                      const SizedBox(width: 4),
                      Expanded(child: Text(e, style: TextStyle(color: theme.colorScheme.error))),
                    ]),
                  ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_editable) ...[
          const SizedBox(height: AppSpacing.md),
          AppButton(label: 'Save route', expand: true, loading: _saving, onPressed: (_saving || !_dirty) ? null : _save),
          AppButton(
            label: 'Save & continue later',
            variant: AppButtonVariant.ghost,
            expand: true,
            onPressed: _saving
                ? null
                : () async {
                    if (_dirty) await _save();
                    if (context.mounted && _serverErrors.isEmpty) Navigator.of(context).pop();
                  },
          ),
        ],
      ],
    );
  }
}

class _StopCard extends StatelessWidget {
  const _StopCard({
    super.key,
    required this.stop,
    required this.label,
    required this.showArrival,
    required this.showDeparture,
    required this.lockBoarding,
    required this.lockDropping,
    required this.enabled,
    required this.onPickTime,
    required this.onChanged,
    this.onRemove,
    this.dragIndex,
    this.cities,
  });

  final RouteStop stop;
  final String label;
  final bool showArrival;
  final bool showDeparture;
  final bool lockBoarding;
  final bool lockDropping;
  final bool enabled;
  final void Function(bool arrival) onPickTime;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final int? dragIndex;

  /// When given, the stop can be linked to a city so customers searching that
  /// city find this bus.
  final List<Map<String, dynamic>>? cities;

  @override
  Widget build(BuildContext context) {
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
                Expanded(child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
                if (onRemove != null && enabled) IconButton(onPressed: onRemove, icon: const Icon(Icons.delete_outline)),
              ],
            ),
            TextFormField(
              initialValue: stop.name,
              enabled: enabled,
              decoration: const InputDecoration(labelText: 'Stop / bus stand name'),
              textCapitalization: TextCapitalization.words,
              onChanged: (v) {
                stop.name = v;
                onChanged();
              },
            ),
            if (cities != null) ...[
              const SizedBox(height: AppSpacing.xs),
              DropdownButtonFormField<String?>(
                initialValue: cities!.any((c) => c['id'] == stop.cityId) ? stop.cityId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'City (optional — lets customers search this stop)'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Not linked to a city')),
                  for (final c in cities!) DropdownMenuItem<String?>(value: c['id'] as String, child: Text(c['name'] as String)),
                ],
                onChanged: enabled ? (v) { stop.cityId = v; onChanged(); } : null,
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              children: [
                FilterChip(
                  label: const Text('Boarding'),
                  selected: stop.isBoarding,
                  onSelected: (enabled && !lockBoarding) ? (v) { stop.isBoarding = v; onChanged(); } : null,
                ),
                FilterChip(
                  label: const Text('Dropping'),
                  selected: stop.isDropping,
                  onSelected: (enabled && !lockDropping) ? (v) { stop.isDropping = v; onChanged(); } : null,
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
