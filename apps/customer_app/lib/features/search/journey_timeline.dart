import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

/// Stops for one departure, from get_trip_stop_timeline (informational fields
/// only; the RPC never returns operator or service ids).
final tripStopsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, tripId) async {
  final rows = await ref.watch(supabaseProvider).rpc('get_trip_stop_timeline', params: {'p_trip_id': tripId});
  return List<Map<String, dynamic>>.from(rows as List);
});

List<String> _strings(dynamic v) => List<String>.from(v as List? ?? const []);

/// Journey timeline: departure, each intermediate stop with its purpose
/// labels ("Lunch Break", "Ferry Transfer", …) and facilities, then arrival.
/// Renders nothing for a non-stop service.
class JourneyTimeline extends ConsumerWidget {
  const JourneyTimeline({super.key, required this.tripId, required this.departureAt, required this.arrivalAt});

  final String tripId;
  final String departureAt;
  final String arrivalAt;

  static String _time(DateTime t, DateTime departure) {
    final days = DateTime(t.year, t.month, t.day).difference(DateTime(departure.year, departure.month, departure.day)).inDays;
    final clock = DateFormat('h:mm a').format(t);
    return days > 0 ? '$clock (+$days day${days > 1 ? 's' : ''})' : clock;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stops = ref.watch(tripStopsProvider(tripId)).value ?? const [];
    if (stops.isEmpty) return const SizedBox.shrink();

    final departure = DateTime.parse(departureAt).toLocal();
    final theme = Theme.of(context);

    Widget row({required String title, required String time, List<String> labels = const [], List<String> facilities = const [], String? note}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(padding: EdgeInsets.only(top: 2, right: AppSpacing.sm), child: Icon(Icons.circle, size: 10, color: AppColors.primary)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  Text(time, style: theme.textTheme.bodySmall),
                  if (note != null) Text(note, style: theme.textTheme.bodySmall),
                  if (labels.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: labels.map((l) => AppChip(label: l, selected: true)).toList()),
                  ],
                  if (facilities.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text('Facilities: ${facilities.join(' · ')}', style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Journey timeline', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            row(title: 'Departure', time: _time(departure, departure)),
            for (final s in stops)
              row(
                title: s['location_name'] as String,
                time: '${_time(DateTime.parse(s['arrival_at'] as String).toLocal(), departure)} · ${s['stop_duration_minutes']} min stop',
                labels: StopCatalog.customerLabels(
                  purposes: _strings(s['stop_purposes']),
                  mealTypes: _strings(s['meal_types']),
                  refreshmentTypes: _strings(s['refreshment_types']),
                ),
                facilities: StopCatalog.facilityLabels(_strings(s['facilities'])),
                note: [
                  if (s['allows_pickup'] == true) 'Pickup',
                  if (s['allows_drop'] == true) 'Drop',
                ].join(' & '),
              ),
            row(title: 'Arrival', time: _time(DateTime.parse(arrivalAt).toLocal(), departure)),
          ],
        ),
      ),
    );
  }
}
