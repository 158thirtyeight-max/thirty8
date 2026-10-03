import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'fleet_list_screen.dart';
import 'route_form_screen.dart' show citiesProvider;
import 'routes_list_screen.dart';
import 'stops/stop_schedule.dart';
import 'stops/stops_editor.dart';

/// Schedule setup for a recurring service. The operator defines timing and
/// operating days ONCE; the backend generates every departure inside the
/// admin-controlled booking window and keeps extending it. There is no
/// per-date or per-month scheduling here, and the booking window is read-only.
class ServiceFormScreen extends ConsumerStatefulWidget {
  const ServiceFormScreen({super.key, required this.operatorId, this.service});

  final String operatorId;

  /// Existing bus_services row when editing; null when creating.
  final Map<String, dynamic>? service;

  @override
  ConsumerState<ServiceFormScreen> createState() => _ServiceFormScreenState();
}

class _ServiceFormScreenState extends ConsumerState<ServiceFormScreen> {
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String? _routeId;
  String? _busId;
  TimeOfDay _departureTime = const TimeOfDay(hour: 8, minute: 0);
  int _durationMinutes = 240;
  final Set<int> _days = {1, 2, 3, 4, 5, 6, 7}; // ISO weekday: 1 = Monday
  final _fareController = TextEditingController(text: '450');
  final _closeController = TextEditingController();
  final _cutoffController = TextEditingController();
  bool _loading = false;
  String? _error;
  List<StopDraft> _stops = [];
  bool _stopsDirty = false;

  Map<String, dynamic>? _preview; // from preview_service_schedule (backend = source of truth)
  Map<String, dynamic>? _overview; // from get_service_schedule_overview (edit mode)
  String _status = 'active';

  bool get _editing => widget.service != null;

  @override
  void initState() {
    super.initState();
    final s = widget.service;
    if (s != null) {
      _routeId = s['route_id'] as String;
      _busId = s['bus_id'] as String;
      final parts = (s['default_departure_time'] as String).split(':');
      _departureTime = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      _durationMinutes = s['default_arrival_offset_minutes'] as int;
      _days
        ..clear()
        ..addAll(((s['operating_days'] as List<dynamic>?) ?? const [1, 2, 3, 4, 5, 6, 7]).map((e) => (e as num).toInt()));
      _status = s['status'] as String;
      final close = s['booking_close_minutes'];
      final cutoff = s['boarding_cutoff_minutes'];
      if (close != null) _closeController.text = '$close';
      if (cutoff != null) _cutoffController.text = '$cutoff';
      _loadOverview();
      _loadPreview();
      _loadStops();
    }
  }

  @override
  void dispose() {
    _fareController.dispose();
    _closeController.dispose();
    _cutoffController.dispose();
    super.dispose();
  }

  Future<void> _loadStops() async {
    try {
      final rows = await ref
          .read(supabaseProvider)
          .from('bus_service_stops')
          .select('*, cities(name)')
          .eq('service_id', widget.service!['id'] as String)
          .order('sequence_no');
      if (!mounted) return;
      setState(() => _stops = (rows as List<dynamic>).map((r) => StopDraft.fromRow(r as Map<String, dynamic>)).toList());
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load stops: $e');
    }
  }

  /// Cities a stop may use: everything except the route's origin and destination.
  List<Map<String, dynamic>> _stopCities(List<Map<String, dynamic>> cities, List<Map<String, dynamic>> routes) {
    final route = routes.where((r) => r['id'] == _routeId).firstOrNull;
    final excluded = {route?['source_city_id'], route?['destination_city_id']};
    return cities.where((c) => !excluded.contains(c['id'])).toList();
  }

  String _timeString(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

  String _arrivalLabel() {
    final total = _departureTime.hour * 60 + _departureTime.minute + _durationMinutes;
    final dayOffset = total ~/ 1440;
    final m = total % 1440;
    final t = TimeOfDay(hour: m ~/ 60, minute: m % 60);
    return dayOffset > 0 ? '${t.format(context)} (+$dayOffset day)' : t.format(context);
  }

  String _durationLabel() {
    final h = _durationMinutes ~/ 60;
    final m = _durationMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  Future<void> _loadPreview() async {
    if (_routeId == null || _days.isEmpty) {
      setState(() => _preview = null);
      return;
    }
    try {
      final res = await ref.read(supabaseProvider).rpc('preview_service_schedule', params: {
        'p_route_id': _routeId,
        'p_operating_days': _days.toList()..sort(),
        'p_departure_time': _timeString(_departureTime),
      });
      if (mounted) setState(() => _preview = Map<String, dynamic>.from(res as Map));
    } catch (_) {
      if (mounted) setState(() => _preview = null);
    }
  }

  Future<void> _loadOverview() async {
    final id = widget.service?['id'] as String?;
    if (id == null) return;
    try {
      final res = await ref.read(supabaseProvider).rpc('get_service_schedule_overview', params: {'p_service_id': id});
      if (mounted) {
        setState(() {
          _overview = Map<String, dynamic>.from(res as Map);
          _status = _overview!['status'] as String? ?? _status;
        });
      }
    } catch (_) {}
  }

  Future<void> _pickDeparture() async {
    final picked = await showTimePicker(context: context, initialTime: _departureTime);
    if (picked == null) return;
    setState(() => _departureTime = picked); // duration is kept, arrival follows
    _loadPreview();
  }

  Future<void> _pickArrival() async {
    final current = (_departureTime.hour * 60 + _departureTime.minute + _durationMinutes) % 1440;
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60));
    if (picked == null) return;
    var diff = (picked.hour * 60 + picked.minute) - (_departureTime.hour * 60 + _departureTime.minute);
    if (diff <= 0) diff += 1440; // arrives the next day
    setState(() => _durationMinutes = diff);
  }

  int? _optionalMinutes(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : int.tryParse(t);
  }

  Future<void> _save() async {
    if (_routeId == null || _busId == null) {
      setState(() => _error = 'Pick a route and a bus');
      return;
    }
    if (_days.isEmpty) {
      setState(() => _error = 'Select at least one operating day');
      return;
    }
    final close = _optionalMinutes(_closeController);
    final cutoff = _optionalMinutes(_cutoffController);
    final maxClose = (_preview?['booking_close_minutes_max'] as num?)?.toInt();
    final maxCutoff = (_preview?['boarding_cutoff_minutes_max'] as num?)?.toInt();
    if ((close != null && maxClose != null && close > maxClose) || (cutoff != null && maxCutoff != null && cutoff > maxCutoff)) {
      setState(() => _error = 'Booking close / boarding cut-off exceed the platform maximum ($maxClose / $maxCutoff minutes)');
      return;
    }
    final stopsError = validateStops(_stops, _durationMinutes);
    if (stopsError != null) {
      setState(() => _error = stopsError);
      return;
    }
    final fareRupees = int.tryParse(_fareController.text.trim());
    if (!_editing && (fareRupees == null || fareRupees <= 0)) {
      setState(() => _error = 'Enter a fare in rupees');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final supabase = ref.read(supabaseProvider);
      final days = _days.toList()..sort();
      final canSetRules = _preview?['operator_can_set_booking_rules'] as bool? ?? true;

      final fields = <String, dynamic>{
        'bus_id': _busId,
        'default_departure_time': _timeString(_departureTime),
        'default_arrival_offset_minutes': _durationMinutes,
        'operating_days': days,
        if (canSetRules) 'booking_close_minutes': close,
        if (canSetRules) 'boarding_cutoff_minutes': cutoff,
      };

      String serviceId;
      if (_editing) {
        serviceId = widget.service!['id'] as String;
        await supabase.from('bus_services').update(fields).eq('id', serviceId);
      } else {
        // The fare rule is applied to every seat type on the bus's active layout.
        final seatRows = await supabase
            .from('seats')
            .select('seat_type, bus_layouts!inner(bus_id, is_active)')
            .eq('bus_layouts.bus_id', _busId!)
            .eq('bus_layouts.is_active', true);
        final seatTypes = (seatRows as List<dynamic>).map((r) => (r as Map<String, dynamic>)['seat_type'] as String).toSet();
        if (seatTypes.isEmpty) {
          throw 'This bus has no seat layout yet — add one before creating a schedule';
        }

        final route = await supabase.from('bus_routes').select('source_city_id, destination_city_id').eq('id', _routeId!).single();
        final inserted = await supabase
            .from('bus_services')
            .insert({
              'operator_id': widget.operatorId,
              'route_id': _routeId,
              'service_name': 'Service',
              'service_source_city_id': route['source_city_id'],
              'service_dest_city_id': route['destination_city_id'],
              ...fields,
            })
            .select('id')
            .single();
        serviceId = inserted['id'] as String;

        // Inserting the fare rules is what publishes the first departures (backend trigger).
        await supabase.from('fare_rules').insert(seatTypes
            .map((t) => {'service_id': inserted['id'], 'seat_type': t, 'base_fare_cents': fareRupees! * 100})
            .toList());
      }
      if (_stopsDirty || (!_editing && _stops.isNotEmpty)) {
        try {
          await supabase.rpc('save_service_stops', params: {'p_service_id': serviceId, 'p_stops': _stops.map((s) => s.toRpc()).toList()});
        } catch (e) {
          // The schedule itself is saved; don't let a retry create a duplicate service.
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Schedule saved, but stops were not: $e. Reopen the schedule to add them again.')));
            Navigator.of(context).pop(true);
          }
          return;
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Could not save schedule: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setStatus(String status) async {
    setState(() => _loading = true);
    try {
      await ref.read(supabaseProvider).rpc('set_service_schedule_status', params: {
        'p_service_id': widget.service!['id'],
        'p_status': status,
      });
      setState(() => _status = status);
      await _loadOverview();
    } catch (e) {
      setState(() => _error = 'Could not change schedule status: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _suspendDates() async {
    final today = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year, today.month, today.day),
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'Suspend service between',
    );
    if (range == null) return;
    final reasonController = TextEditingController();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Suspend service'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${DateFormat('d MMM').format(range.start)} – ${DateFormat('d MMM yyyy').format(range.end)}'),
            const SizedBox(height: 8),
            const Text(
              'No departures will run on these dates and the schedule resumes automatically afterwards. '
              'Departures that already have bookings are sent to admin as cancellation requests.',
            ),
            const SizedBox(height: 12),
            TextField(controller: reasonController, decoration: const InputDecoration(labelText: 'Reason')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Suspend')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _loading = true);
    try {
      final f = DateFormat('yyyy-MM-dd');
      await ref.read(supabaseProvider).rpc('suspend_service_dates', params: {
        'p_service_id': widget.service!['id'],
        'p_start': f.format(range.start),
        'p_end': f.format(range.end),
        'p_reason': reasonController.text.trim(),
      });
      await _loadOverview();
    } catch (e) {
      setState(() => _error = 'Could not suspend service: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeSuspension(String id) async {
    setState(() => _loading = true);
    try {
      await ref.read(supabaseProvider).rpc('remove_service_suspension', params: {'p_exception_id': id});
      await _loadOverview();
    } catch (e) {
      setState(() => _error = 'Could not remove suspension: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _section(String title, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: Text(k)),
            const SizedBox(width: 12),
            Flexible(child: Text(v, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final routesAsync = ref.watch(busRoutesProvider(widget.operatorId));
    final busesAsync = ref.watch(busesProvider(widget.operatorId));
    final dateFmt = DateFormat('EEE, d MMM yyyy');
    final windowDays = (_preview?['advance_days'] as num?)?.toInt();
    final horizon = _preview?['horizon_date'] as String?;
    final nextDate = _preview?['next_departure_date'] as String?;
    final canSetRules = _preview?['operator_can_set_booking_rules'] as bool? ?? true;
    final isPaused = _status == 'paused';

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit recurring schedule' : 'Schedule setup')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              routesAsync.when(
                data: (routes) => DropdownButtonFormField<String>(
                  initialValue: _routeId,
                  decoration: const InputDecoration(labelText: 'Route'),
                  isExpanded: true,
                  items: routes
                      .map((r) => DropdownMenuItem(
                            value: r['id'] as String,
                            child: Text('${r['source']?['name']} → ${r['destination']?['name']}', overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: _editing
                      ? null
                      : (v) {
                          setState(() => _routeId = v);
                          _loadPreview();
                        },
                ),
                loading: () => const CircularProgressIndicator(),
                error: (e, st) => Text('Error loading routes: $e'),
              ),
              const SizedBox(height: 16),
              busesAsync.when(
                data: (buses) => DropdownButtonFormField<String>(
                  initialValue: _busId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Bus'),
                  items: buses.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['registration_number'] as String))).toList(),
                  onChanged: (v) => setState(() => _busId = v),
                ),
                loading: () => const CircularProgressIndicator(),
                error: (e, st) => Text('Error loading buses: $e'),
              ),
              const SizedBox(height: 24),

              // 1. Journey timing
              _section(
                'Journey timing',
                Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Departure time'),
                      subtitle: Text(_departureTime.format(context)),
                      trailing: const Icon(Icons.access_time),
                      onTap: _pickDeparture,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Arrival time'),
                      subtitle: Text(_arrivalLabel()),
                      trailing: const Icon(Icons.access_time_filled),
                      onTap: _pickArrival,
                    ),
                    _kv('Journey duration', _durationLabel()),
                  ],
                ),
              ),

              // Route & stops
              _section(
                'Route & stops',
                ref.watch(citiesProvider).when(
                      data: (cities) => StopsEditor(
                        stops: _stops,
                        cities: _stopCities(cities, routesAsync.value ?? const []),
                        totalMinutes: _durationMinutes,
                        departureMinuteOfDay: _departureTime.hour * 60 + _departureTime.minute,
                        onChanged: (stops) => setState(() {
                          _stops = stops;
                          _stopsDirty = true;
                        }),
                      ),
                      loading: () => const LinearProgressIndicator(),
                      error: (e, st) => Text('Could not load cities: $e'),
                    ),
              ),

              // 2. Operating days
              _section(
                'Operating days',
                Wrap(
                  spacing: 8,
                  children: List.generate(7, (i) {
                    final iso = i + 1;
                    return FilterChip(
                      label: Text(_dayLabels[i]),
                      selected: _days.contains(iso),
                      onSelected: (on) {
                        setState(() => on ? _days.add(iso) : _days.remove(iso));
                        _loadPreview();
                      },
                    );
                  }),
                ),
              ),

              if (!_editing)
                _section(
                  'Fare',
                  AppTextField(
                    controller: _fareController,
                    keyboardType: TextInputType.number,
                    label: 'Fare per seat (₹)',
                  ),
                ),

              // 3. Automatic schedule generation (read-only, from the backend)
              _section(
                'Automatic schedule generation',
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Your bus departures will be generated automatically based on your selected operating days.'),
                      const SizedBox(height: 8),
                      _kv('Schedule automation', isPaused ? 'Paused' : 'Enabled'),
                      _kv('Effective advance booking window', windowDays == null ? '…' : '$windowDays days'),
                      _kv('Next eligible departure', nextDate == null ? '—' : dateFmt.format(DateTime.parse(nextDate))),
                      _kv('Booking availability horizon', horizon == null ? '—' : dateFmt.format(DateTime.parse(horizon))),
                      if (_preview != null) _kv('Departures in window', '${_preview!['departures_in_window']}'),
                    ],
                  ),
                ),
              ),

              // 4. Booking rules
              _section(
                'Booking rules',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('Advance booking', windowDays == null ? '…' : '$windowDays days'),
                    const SizedBox(height: 4),
                    Text(
                      'Configured by thirty8 administration. Future departures will be published automatically.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (canSetRules) ...[
                      const SizedBox(height: 16),
                      AppTextField(
                        controller: _closeController,
                        keyboardType: TextInputType.number,
                        label: 'Booking closes (minutes before departure)',
                        hint: 'Platform default: ${_preview?['booking_close_minutes_default'] ?? 0}, max ${_preview?['booking_close_minutes_max'] ?? '—'}',
                      ),
                      const SizedBox(height: 12),
                      AppTextField(
                        controller: _cutoffController,
                        keyboardType: TextInputType.number,
                        label: 'Boarding cut-off (minutes before departure)',
                        hint: 'Platform default: ${_preview?['boarding_cutoff_minutes_default'] ?? 0}, max ${_preview?['boarding_cutoff_minutes_max'] ?? '—'}',
                      ),
                    ],
                  ],
                ),
              ),

              // 5. Schedule status (edit mode)
              if (_editing)
                _section(
                  'Schedule status',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        AppBadge(status: _status),
                        const SizedBox(width: 12),
                        if (_overview?['next_departure_at'] != null)
                          Expanded(
                            child: Text(
                              'Next departure ${DateFormat('EEE, d MMM · h:mm a').format(DateTime.parse(_overview!['next_departure_at'] as String).toLocal())}',
                            ),
                          ),
                      ]),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        if (isPaused)
                          AppButton(label: 'Resume schedule', icon: Icons.play_arrow, onPressed: _loading ? null : () => _setStatus('active'))
                        else
                          AppButton(
                            label: 'Pause future departures',
                            icon: Icons.pause,
                            variant: AppButtonVariant.outline,
                            onPressed: _loading ? null : () => _setStatus('paused'),
                          ),
                        AppButton(
                          label: 'Temporary suspension',
                          icon: Icons.event_busy,
                          variant: AppButtonVariant.outline,
                          onPressed: _loading ? null : _suspendDates,
                        ),
                      ]),
                      if (isPaused)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('Paused: no new departures are published. Existing departures and bookings are unaffected.'),
                        ),
                      for (final e in (_overview?['suspensions'] as List<dynamic>? ?? const []))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.event_busy),
                          title: Text(
                            '${DateFormat('d MMM').format(DateTime.parse((e as Map)['start_date'] as String))} – '
                            '${DateFormat('d MMM yyyy').format(DateTime.parse(e['end_date'] as String))}',
                          ),
                          subtitle: Text((e['reason'] as String?) ?? 'Suspended'),
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'End suspension',
                            onPressed: _loading ? null : () => _removeSuspension(e['id'] as String),
                          ),
                        ),
                      for (final err in (_overview?['recent_errors'] as List<dynamic>? ?? const []).take(1))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Setup issue: ${(err as Map)['message']}',
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                        ),
                    ],
                  ),
                ),

              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 12),
              ],
              AppButton(
                label: _editing ? 'Save changes' : 'Confirm schedule',
                onPressed: _loading ? null : _save,
                loading: _loading,
                expand: true,
              ),
              if (_editing)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Changes apply to future departures that have no bookings yet. Departures with bookings keep their original time.',
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
