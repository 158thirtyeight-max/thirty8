import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../core/supabase_providers.dart';
import 'fleet_providers.dart';
import 'setup_continue.dart';
import 'operating_days_picker.dart';
import 'route_model.dart';
import 'stop_card.dart';

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

  void _load(Map<String, dynamic> data, List<Map<String, dynamic>> cities) {
    if (_loaded) return;
    _loaded = true;
    final service = data['service'] as Map<String, dynamic>?;
    final route = data['route'] as Map<String, dynamic>?;
    if (service == null || route == null) return;

    _sourceId = route['source_city_id'] as String?;
    _destId = route['destination_city_id'] as String?;
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
      // Older routes were saved without main locations on every stop; the ends follow the route's cities.
      _stops.first.cityId ??= _sourceId;
      _stops.last.cityId ??= _destId;
    }
  }

  /// Prefills origin, destination, distance and every stop from an admin-defined
  /// catalog route. Stop clock times follow the origin departure time (default 06:00).
  void _applyCatalogRoute(Map<String, dynamic> t) {
    final depMin = _stops.first.departureMin ?? 360;
    final rows = List<Map<String, dynamic>>.from(t['stops'] as List)
      ..sort((a, b) => (a['sequence_no'] as int).compareTo(b['sequence_no'] as int));
    if (rows.length < 2) return;
    setState(() {
      _dirty = true;
      _sourceId = t['source_city_id'] as String?;
      _destId = t['destination_city_id'] as String?;
      _stops
        ..clear()
        ..addAll([
          for (var i = 0; i < rows.length; i++)
            RouteStop(
              name: rows[i]['name'] as String,
              cityId: rows[i]['city_id'] as String?,
              isBoarding: i == 0 || rows[i]['is_boarding'] == true,
              isDropping: i == rows.length - 1 || rows[i]['is_dropping'] == true,
              arrivalMin: i == 0 || rows[i]['arrival_offset_min'] == null ? null : clockFromOffset(depMin, rows[i]['arrival_offset_min'] as int),
              departureMin: i == rows.length - 1
                  ? null
                  : (i == 0 ? depMin : (rows[i]['departure_offset_min'] == null ? null : clockFromOffset(depMin, rows[i]['departure_offset_min'] as int))),
            ),
        ]);
    });
  }

  /// Locations used by the other stops: a location appears once on a route.
  Set<String> _takenIds(RouteStop except) => {
        for (final s in _stops)
          if (!identical(s, except) && s.cityId != null) s.cityId!,
      };

  Future<void> _pickTime(RouteStop stop, {required bool arrival}) async {
    final current = arrival ? stop.arrivalMin : stop.departureMin;
    final picked = await pick24HourTime(context, minutes: current);
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
      final name = cities.firstWhere((c) => c['id'] == id, orElse: () => const {})['name'] as String? ?? '';
      final stop = source ? _stops.first : _stops.last;
      if (source) {
        _sourceId = id;
      } else {
        _destId = id;
      }
      stop
        ..cityId = id
        ..name = name;
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
        'p_distance_km': null, // calculated by the database from the locations
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
      // Location / point rules are enforced in the database; show its message so the operator can fix the stop.
      final message = e is PostgrestException ? e.message : e.toString();
      setState(() => _error = message.contains('locked')
          ? 'The route is locked while this bus is under review.'
          : (e is PostgrestException && RegExp(r'^(Stop \d+|The (first|last) stop|A location|Origin and)').hasMatch(message))
              ? message
              : 'Could not save the route. Please check the details and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routeAsync = ref.watch(busRouteProvider(widget.bus['id'] as String));
    final citiesAsync = ref.watch(citiesProvider);
    final locationsAsync = ref.watch(stopLocationsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Route & stops')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (routeAsync.hasError || citiesAsync.hasError || locationsAsync.hasError) {
            return AppErrorState(
              message: 'Could not load the route.',
              onRetry: () {
                ref.invalidate(busRouteProvider(widget.bus['id'] as String));
                ref.invalidate(citiesProvider);
                ref.invalidate(stopLocationsProvider);
              },
            );
          }
          if (!routeAsync.hasValue || !citiesAsync.hasValue || !locationsAsync.hasValue) return const AppLoadingState();
          final cities = citiesAsync.requireValue;
          _load(routeAsync.requireValue, cities);
          return _form(context, cities, locationsAsync.requireValue);
        }),
      ),
    );
  }

  Widget _form(BuildContext context, List<Map<String, dynamic>> cities, List<Map<String, dynamic>> locations) {
    final theme = Theme.of(context);
    final duration = journeyDurationMin(_stops);
    final edit = _editable && !_saving;

    Widget cityDropdown(String label, String? value, bool source) => DropdownButtonFormField<String>(
          key: ValueKey('$label-$value'),
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
        if (edit)
          ref.watch(routeCatalogProvider).maybeWhen(
                data: (catalog) => catalog.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: DropdownButtonFormField<Map<String, dynamic>>(
                          initialValue: null,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Start from a platform route (optional)'),
                          items: [for (final t in catalog) DropdownMenuItem(value: t, child: Text(t['name'] as String))],
                          onChanged: (t) {
                            if (t != null) _applyCatalogRoute(t);
                          },
                        ),
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
        cityDropdown('Origin city', _sourceId, true),
        const SizedBox(height: AppSpacing.md),
        cityDropdown('Destination city', _destId, false),
        const SizedBox(height: AppSpacing.md),
        Text('Operating days', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        OperatingDaysPicker(days: _days, enabled: edit, onChanged: (d) => setState(() { _days = d; _dirty = true; })),
        const SizedBox(height: AppSpacing.md),
        Text('Stops in travel order', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.xs),
        StopCard(
          key: ObjectKey(_stops.first),
          stop: _stops.first,
          label: 'Origin',
          showArrival: false,
          showDeparture: true,
          lockBoarding: true,
          lockDropping: false,
          lockLocation: true,
          locations: locations,
          takenIds: _takenIds(_stops.first),
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
              StopCard(
                key: ObjectKey(_stops[i]),
                stop: _stops[i],
                label: 'Stop $i',
                showArrival: true,
                showDeparture: true,
                lockBoarding: false,
                lockDropping: false,
                lockLocation: false,
                enabled: edit,
                locations: locations,
                takenIds: _takenIds(_stops[i]),
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
        StopCard(
          key: ObjectKey(_stops.last),
          stop: _stops.last,
          label: 'Destination',
          showArrival: true,
          showDeparture: false,
          lockBoarding: false,
          lockDropping: true,
          lockLocation: true,
          locations: locations,
          takenIds: _takenIds(_stops.first),
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
          SetupContinueButton(
            loading: _saving,
            onPressed: () async {
              if (_dirty) await _save();
              if (context.mounted && _serverErrors.isEmpty && _error == null) Navigator.of(context).pop(kSetupContinue);
            },
          ),
        ],
      ],
    );
  }
}
