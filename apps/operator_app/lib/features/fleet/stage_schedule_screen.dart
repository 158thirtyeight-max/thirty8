import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'fleet_providers.dart';
import 'operating_days_picker.dart';
import 'route_model.dart';
import 'schedule_model.dart';

/// Stage F — schedule of this bus's service: departure (arrival is derived from
/// the route), operating days, when booking opens and closes, and the boarding
/// cut-off. For an active bus it can also generate dated trips.
class StageScheduleScreen extends ConsumerStatefulWidget {
  const StageScheduleScreen({super.key, required this.operatorId, required this.bus});

  final String operatorId;
  final Map<String, dynamic> bus;

  @override
  ConsumerState<StageScheduleScreen> createState() => _StageScheduleScreenState();
}

class _StageScheduleScreenState extends ConsumerState<StageScheduleScreen> {
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  bool _generating = false;
  String? _error;
  List<String> _serverErrors = const [];

  int? _departureMin;
  int? _durationMin;
  Set<int> _days = {1, 2, 3, 4, 5, 6, 7};
  int _openDays = 30;
  int _cutoff = 30;
  int _boardingCutoff = 10;
  bool _configured = false;

  DateTime _genFrom = DateTime.now().add(const Duration(days: 1));
  DateTime _genTo = DateTime.now().add(const Duration(days: 14));

  bool get _editable {
    final lifecycle = widget.bus['lifecycle_status'] as String?;
    return widget.bus['is_legacy'] == true || const ['draft', 'changes_requested', 'approved', 'active'].contains(lifecycle);
  }

  bool get _canGenerate => widget.bus['lifecycle_status'] == 'active' && widget.bus['status'] == 'active';

  void _load(Map<String, dynamic> service) {
    if (_loaded) return;
    _loaded = true;
    final dep = (service['default_departure_time'] as String? ?? '06:00:00').split(':');
    _departureMin = int.parse(dep[0]) * 60 + int.parse(dep[1]);
    _durationMin = service['est_duration_min'] as int? ?? service['default_arrival_offset_minutes'] as int?;
    _days = {for (final d in (service['operating_days'] as List? ?? const [1, 2, 3, 4, 5, 6, 7])) (d as num).toInt()};
    _openDays = service['booking_open_days_before'] as int? ?? 30;
    _cutoff = service['booking_cutoff_min'] as int? ?? 30;
    _boardingCutoff = service['boarding_cutoff_min'] as int? ?? 10;
    _configured = service['schedule_configured'] == true;
    _dirty = !_configured; // unconfirmed defaults must be saved once
  }

  Future<void> _pickDeparture() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (_departureMin ?? 360) ~/ 60, minute: (_departureMin ?? 360) % 60),
    );
    if (t != null) setState(() { _departureMin = t.hour * 60 + t.minute; _dirty = true; });
  }

  Future<void> _save() async {
    final errors = validateSchedule(
      departureMin: _departureMin,
      days: _days,
      openDaysBefore: _openDays,
      bookingCutoffMin: _cutoff,
      boardingCutoffMin: _boardingCutoff,
    );
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
      final d = _departureMin!;
      final res = await ref.read(supabaseProvider).rpc('save_bus_schedule', params: {
        'p_bus_id': widget.bus['id'],
        'p_departure_time': '${(d ~/ 60).toString().padLeft(2, '0')}:${(d % 60).toString().padLeft(2, '0')}:00',
        'p_operating_days': (_days.toList()..sort()),
        'p_booking_open_days_before': _openDays,
        'p_booking_cutoff_min': _cutoff,
        'p_boarding_cutoff_min': _boardingCutoff,
      });
      final map = Map<String, dynamic>.from(res as Map);
      ref.invalidate(busRouteProvider(widget.bus['id'] as String));
      setState(() {
        _dirty = false;
        _configured = true;
        _serverErrors = List<String>.from(map['errors'] as List);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_serverErrors.isEmpty ? 'Schedule saved.' : 'Saved — but the schedule still has issues to fix.'),
        ));
      }
    } catch (e) {
      setState(() => _error = e.toString().contains('route')
          ? 'Configure the route before the schedule.'
          : e.toString().contains('locked')
              ? 'The schedule is locked while this bus is under review.'
              : 'Could not save the schedule. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generate() async {
    if (_dirty) {
      setState(() => _error = 'Save the schedule first.');
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final iso = DateFormat('yyyy-MM-dd');
      final n = await ref.read(supabaseProvider).rpc('generate_bus_trips', params: {
        'p_bus_id': widget.bus['id'],
        'p_from': iso.format(_genFrom),
        'p_to': iso.format(_genTo),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n new trip${n == 1 ? '' : 's'} created.')));
      }
    } catch (e) {
      setState(() => _error = 'Could not generate trips. Check that the bus and its service are active.');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _genFrom, end: _genTo),
    );
    if (picked != null) {
      setState(() {
        _genFrom = picked.start;
        _genTo = picked.end.difference(picked.start).inDays > 90 ? picked.start.add(const Duration(days: 90)) : picked.end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final routeAsync = ref.watch(busRouteProvider(widget.bus['id'] as String));
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (routeAsync.hasError) {
            return AppErrorState(message: 'Could not load the schedule.', onRetry: () => ref.invalidate(busRouteProvider(widget.bus['id'] as String)));
          }
          if (!routeAsync.hasValue) return const AppLoadingState();
          final service = routeAsync.requireValue['service'] as Map<String, dynamic>?;
          if (service == null) {
            return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Set up the route first (Stage D), then come back to the schedule.')));
          }
          _load(service);
          return _form(context);
        }),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final edit = _editable && !_saving;
    final arrivalMin = (_departureMin != null && _durationMin != null) ? (_departureMin! + _durationMin!) % minutesPerDay : null;
    final arrivalNextDay = _departureMin != null && _durationMin != null && _departureMin! + _durationMin! >= minutesPerDay;

    Widget dropdown(String label, int value, List<int> presets, ValueChanged<int> onChanged) {
      final options = {...presets, value}.toList()..sort();
      return DropdownButtonFormField<int>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [for (final o in options) DropdownMenuItem(value: o, child: Text(describeMinutesBefore(o)))],
        onChanged: edit ? (v) => setState(() { onChanged(v!); _dirty = true; }) : null,
      );
    }

    final tripCount = tripDatesInRange(_genFrom, _genTo, _days).length;
    final fmt = DateFormat('dd MMM');

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        if (!_editable) const Padding(padding: EdgeInsets.only(bottom: AppSpacing.sm), child: Text('The schedule is locked while the bus is under review or suspended.')),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: edit ? _pickDeparture : null,
                child: Text('Departure ${formatClock(_departureMin)}'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'Arrival ${formatClock(arrivalMin)}${arrivalNextDay ? ' (+1 day)' : ''}\nJourney ${formatDuration(_durationMin)}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text('Operating days', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        OperatingDaysPicker(days: _days, enabled: edit, onChanged: (d) => setState(() { _days = d; _dirty = true; })),
        const SizedBox(height: AppSpacing.md),
        DropdownButtonFormField<int>(
          initialValue: _openDays,
          decoration: const InputDecoration(labelText: 'Booking opens'),
          items: [
            for (final d in {1, 3, 7, 14, 30, 45, 60, 90, _openDays}.toList()..sort())
              DropdownMenuItem(value: d, child: Text('$d day${d == 1 ? '' : 's'} before departure')),
          ],
          onChanged: edit ? (v) => setState(() { _openDays = v!; _dirty = true; }) : null,
        ),
        const SizedBox(height: AppSpacing.md),
        dropdown('Booking closes', _cutoff, cutoffPresets, (v) => _cutoff = v),
        const SizedBox(height: AppSpacing.md),
        dropdown('Boarding cut-off', _boardingCutoff, boardingCutoffPresets, (v) => _boardingCutoff = v),
        if (_serverErrors.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
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
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_editable) ...[
          const SizedBox(height: AppSpacing.md),
          AppButton(label: _configured ? 'Save schedule' : 'Confirm schedule', expand: true, loading: _saving, onPressed: (_saving || !_dirty) ? null : _save),
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
        if (_canGenerate) ...[
          const SizedBox(height: AppSpacing.lg),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Create trips', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text('Trips are created on your operating days and open for booking per the rules above.', style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(onPressed: _generating ? null : _pickRange, child: Text('${fmt.format(_genFrom)} – ${fmt.format(_genTo)}  ·  $tripCount trips')),
                const SizedBox(height: AppSpacing.sm),
                AppButton(label: 'Generate trips', loading: _generating, onPressed: (_generating || tripCount == 0) ? null : _generate),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
