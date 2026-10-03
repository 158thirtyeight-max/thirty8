import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import '../fleet/bus_navigation.dart';
import '../fleet/bus_validators.dart';
import '../fleet/fleet_providers.dart';
import '../fleet/fleet_status.dart';
import '../fleet/operating_days_picker.dart';
import '../fleet/schedule_model.dart';
import 'route_summary.dart';

/// Minutes since midnight from a Postgres `time` string ("06:00:00").
int? parseTimeOfDayMinutes(String? hhmmss) {
  if (hhmmss == null) return null;
  final parts = hhmmss.split(':');
  if (parts.length < 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

String formatMinutesOfDay(int minutes) {
  final m = minutes % (24 * 60);
  final h = m ~/ 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${(m % 60).toString().padLeft(2, '0')} ${h < 12 ? 'AM' : 'PM'}';
}

/// Schedule Trip: bus → its configured route → dates → departure → stop timings →
/// seats & fares → booking availability → confirm. The route is configured once,
/// per bus; trips never ask for it again. Creating is idempotent on the server
/// (`generate_bus_trips` skips dates that already have a trip).
class ScheduleTripScreen extends ConsumerStatefulWidget {
  const ScheduleTripScreen({super.key, required this.context, this.initialBusId});

  final OperatorContext context;
  final String? initialBusId;

  @override
  ConsumerState<ScheduleTripScreen> createState() => _ScheduleTripScreenState();
}

class _ScheduleTripScreenState extends ConsumerState<ScheduleTripScreen> {
  String? _busId;
  DateTime _from = DateTime.now().add(const Duration(days: 1));
  DateTime _to = DateTime.now().add(const Duration(days: 14));
  bool _saving = false;
  String? _error;

  OperatorContext get _ctx => widget.context;

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked != null) {
      setState(() {
        _from = picked.start;
        _to = picked.end.difference(picked.start).inDays > 90 ? picked.start.add(const Duration(days: 90)) : picked.end;
      });
    }
  }

  Future<void> _create(int expected) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final iso = DateFormat('yyyy-MM-dd');
      final created = await ref.read(supabaseProvider).rpc('generate_bus_trips', params: {
        'p_bus_id': _busId,
        'p_from': iso.format(_from),
        'p_to': iso.format(_to),
      }) as int;
      if (!mounted) return;
      final skipped = (expected - created).clamp(0, expected);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$created new trip${created == 1 ? '' : 's'} created'
            '${skipped > 0 ? ' · $skipped date${skipped == 1 ? '' : 's'} already had a trip' : ''}.'),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      final msg = e is PostgrestException ? e.message : e.toString();
      setState(() => _error = msg.contains('service_inactive')
          ? 'The Bus service is not active, so trips cannot be created. Enable it in Profile → My Services.'
          : 'Could not create trips. Check that the bus and its schedule are active.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busesAsync = ref.watch(busesProvider(_ctx.operatorId));
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule Trip')),
      body: SafeArea(
        child: busesAsync.when(
          loading: () => const Center(child: AppLoadingState()),
          error: (e, _) => Center(child: AppErrorState(message: 'Could not load your buses.', onRetry: () => ref.invalidate(busesProvider(_ctx.operatorId)))),
          data: (buses) {
            final eligible = [for (final b in buses) if (effectiveBusState(b) == 'active') b];
            if (eligible.isEmpty) {
              return const Center(
                child: AppEmptyState(
                  icon: Icons.directions_bus_outlined,
                  message: 'You need an active bus to schedule trips. Finish setting up a bus under Fleet and activate it.',
                ),
              );
            }
            // Preselect when there is only one eligible bus (or the caller chose one).
            final selected = eligible.where((b) => b['id'] == (_busId ?? widget.initialBusId)).firstOrNull ??
                (eligible.length == 1 ? eligible.first : null);
            if (selected != null && _busId != selected['id']) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _busId = selected['id'] as String);
              });
            }
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                _section('1. Bus'),
                DropdownButtonFormField<String>(
                  initialValue: selected?['id'] as String?,
                  decoration: const InputDecoration(labelText: 'Bus'),
                  items: [
                    for (final b in eligible)
                      DropdownMenuItem(value: b['id'] as String, child: Text(busDisplayName(b), overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _busId = v),
                ),
                if (selected != null) _BusPlan(context: _ctx, bus: selected, from: _from, to: _to, saving: _saving, error: _error, onPickRange: _pickRange, onCreate: _create),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _BusPlan extends ConsumerWidget {
  const _BusPlan({
    required this.context,
    required this.bus,
    required this.from,
    required this.to,
    required this.saving,
    required this.error,
    required this.onPickRange,
    required this.onCreate,
  });

  final OperatorContext context;
  final Map<String, dynamic> bus;
  final DateTime from;
  final DateTime to;
  final bool saving;
  final String? error;
  final VoidCallback onPickRange;
  final void Function(int expected) onCreate;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busId = bus['id'] as String;
    final routeAsync = ref.watch(busRouteProvider(busId));
    final faresAsync = ref.watch(busFaresProvider(busId));
    final summaries = ref.watch(operatorRouteSummariesProvider(context.operatorId)).value ?? const <RouteSummary>[];
    final summary = summaries.where((s) => s.busId == busId).firstOrNull;
    final theme = Theme.of(buildContext);
    final fmt = DateFormat('d MMM');

    Widget section(String text) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
          child: Text(text, style: theme.textTheme.titleMedium),
        );

    if (routeAsync.hasError) {
      return AppErrorState(message: 'Could not load this bus’s schedule.', onRetry: () => ref.invalidate(busRouteProvider(busId)));
    }
    if (!routeAsync.hasValue) return const AppLoadingState();

    final data = routeAsync.requireValue;
    final service = data['service'] as Map<String, dynamic>?;
    if (service == null || service['schedule_configured'] != true) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.lg),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This bus has no route and schedule yet.', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              const Text('Configure the route once and every future trip uses it.'),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Configure Route',
                onPressed: () => openBusAction(buildContext, operatorId: context.operatorId, bus: bus, action: BusAction.continueSetup)
                    .then((_) => ref.invalidate(busRouteProvider(busId))),
              ),
            ],
          ),
        ),
      );
    }

    final days = {for (final d in (service['operating_days'] as List? ?? const [1, 2, 3, 4, 5, 6, 7])) (d as num).toInt()};
    final dates = tripDatesInRange(from, to, days);
    final depMin = parseTimeOfDayMinutes(service['default_departure_time'] as String?);
    final boarding = List<Map<String, dynamic>>.from(data['boarding'] as List);
    final dropping = List<Map<String, dynamic>>.from(data['dropping'] as List);
    final rules = (faresAsync.value?['rules'] as List?) ?? const [];
    final bases = [for (final r in rules) (r['base_fare_cents'] as num).toInt()]..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        section('2. Route'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary == null ? 'Configured route' : '${summary.source ?? '—'} → ${summary.destination ?? '—'}', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(summary == null ? '' : (summary.isRoundTrip ? 'Round trip' : 'One way'), style: theme.textTheme.bodySmall),
              if (summary != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => openBusAction(buildContext, operatorId: context.operatorId, bus: bus, action: BusAction.continueSetup)
                        .then((_) => ref.invalidate(busRouteProvider(busId))),
                    child: const Text('Edit route'),
                  ),
                ),
            ],
          ),
        ),
        section('3. Travel dates'),
        OutlinedButton(
          onPressed: saving ? null : onPickRange,
          child: Text('${fmt.format(from)} – ${fmt.format(to)}  ·  ${dates.length} trip${dates.length == 1 ? '' : 's'}'),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('Runs ${describeOperatingDays(days)}. Dates that already have a trip are skipped — nothing is duplicated.', style: theme.textTheme.bodySmall),
        section('4. Departure time'),
        Text(depMin == null ? 'Not set' : formatMinutesOfDay(depMin), style: theme.textTheme.titleSmall),
        section('5. Stop timings'),
        if (boarding.isEmpty && dropping.isEmpty)
          const Text('No stops configured.')
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final p in boarding)
                  AppListItem(
                    leading: const Icon(Icons.trip_origin, size: 18),
                    title: p['name'] as String,
                    subtitle: _stopTime(depMin, p['departure_offset_min'] as int?, 'Departs'),
                  ),
                for (final p in dropping.where((d) => !boarding.any((b) => b['name'] == d['name'])))
                  AppListItem(
                    leading: const Icon(Icons.flag_outlined, size: 18),
                    title: p['name'] as String,
                    subtitle: _stopTime(depMin, p['arrival_offset_min'] as int?, 'Arrives'),
                  ),
              ],
            ),
          ),
        section('6. Seats & fares'),
        Text('${bus['total_seats']} seats · ${busTypeLabel(bus['bus_type'] as String)}', style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          bases.isEmpty
              ? 'No fares configured'
              : (bases.first == bases.last ? 'Base fare ₹${bases.first / 100}' : 'Base fares ₹${bases.first / 100} – ₹${bases.last / 100}'),
          style: theme.textTheme.bodyMedium,
        ),
        section('7. Booking availability'),
        Text(
          'Bookings open ${service['booking_open_days_before']} days before departure and close '
          '${describeMinutesBefore((service['booking_cutoff_min'] as num).toInt()).toLowerCase()}.',
        ),
        if (error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: AppSpacing.lg),
        AppButton(
          label: 'Create ${dates.length} trip${dates.length == 1 ? '' : 's'}',
          expand: true,
          loading: saving,
          onPressed: (saving || dates.isEmpty || bases.isEmpty) ? null : () => onCreate(dates.length),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  String? _stopTime(int? departureMin, int? offset, String verb) {
    if (departureMin == null || offset == null) return null;
    return '$verb ${formatMinutesOfDay(departureMin + offset)}';
  }
}
