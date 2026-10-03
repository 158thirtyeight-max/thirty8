import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'fleet_providers.dart';
import 'schedule_model.dart';

/// Generates dated trips for an active bus from its saved schedule.
class CreateTripsScreen extends ConsumerStatefulWidget {
  const CreateTripsScreen({super.key, required this.operatorId, required this.bus});

  final String operatorId;
  final Map<String, dynamic> bus;

  @override
  ConsumerState<CreateTripsScreen> createState() => _CreateTripsScreenState();
}

class _CreateTripsScreenState extends ConsumerState<CreateTripsScreen> {
  bool _generating = false;
  String? _error;
  DateTime _from = DateTime.now().add(const Duration(days: 1));
  DateTime _to = DateTime.now().add(const Duration(days: 14));

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

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final iso = DateFormat('yyyy-MM-dd');
      final n = await ref.read(supabaseProvider).rpc('generate_bus_trips', params: {
        'p_bus_id': widget.bus['id'],
        'p_from': iso.format(_from),
        'p_to': iso.format(_to),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n new trip${n == 1 ? '' : 's'} created.')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() => _error = 'Could not create trips. Check that the bus and its service are active.');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busId = widget.bus['id'] as String;
    final routeAsync = ref.watch(busRouteProvider(busId));
    final theme = Theme.of(context);
    final fmt = DateFormat('dd MMM');
    return Scaffold(
      appBar: AppBar(title: const Text('Create trips')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (routeAsync.hasError) {
            return AppErrorState(message: 'Could not load the schedule.', onRetry: () => ref.invalidate(busRouteProvider(busId)));
          }
          if (!routeAsync.hasValue) return const AppLoadingState();
          final service = routeAsync.requireValue['service'] as Map<String, dynamic>?;
          if (service == null || service['schedule_configured'] != true) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Set up the route and confirm the schedule first, then come back to create trips.', textAlign: TextAlign.center),
              ),
            );
          }
          final days = {for (final d in (service['operating_days'] as List? ?? const [1, 2, 3, 4, 5, 6, 7])) (d as num).toInt()};
          final tripCount = tripDatesInRange(_from, _to, days).length;
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Text('Trips are created on your operating days and open for booking per the schedule rules.', style: theme.textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.md),
              OutlinedButton(
                onPressed: _generating ? null : _pickRange,
                child: Text('${fmt.format(_from)} – ${fmt.format(_to)}  ·  $tripCount trips'),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: 'Create trips',
                expand: true,
                loading: _generating,
                onPressed: (_generating || tripCount == 0) ? null : _generate,
              ),
            ],
          );
        }),
      ),
    );
  }
}
