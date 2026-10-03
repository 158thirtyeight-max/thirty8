import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../fleet/operating_days_picker.dart';
import '../fleet/route_model.dart';
import '../fleet/stop_schedule.dart';

/// Read-only stop-by-stop timeline of one journey: a dot per stop joined by a line, with the stop's
/// pickup / drop role and its arrival and departure clock times.
class JourneyTimeline extends StatelessWidget {
  const JourneyTimeline({super.key, required this.journey, required this.title});

  final JourneyDraft journey;
  final String title;

  String _clock(int? minutes) => minutes == null ? '--:--' : formatClock(minutes);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stops = journey.stops;
    final start = stops.isEmpty ? '' : stops.first.name;
    final end = stops.isEmpty ? '' : stops.last.name;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text('$start → $end', style: theme.textTheme.titleSmall),
          Text(
            'Departs ${_clock(journey.startMin)} · ${formatDuration(journey.durationMin)} · ${describeOperatingDays(journey.days)}'
            '${journey.departureDayOffset > 0 ? ' · ${journey.departureDayOffset == 1 ? 'next day' : '+${journey.departureDayOffset} days'}' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < stops.length; i++) _row(context, stops[i], i, stops.length),
        ],
      ),
    );
  }

  List<String> _times(RouteStop s, int i, int n) {
    final dur = journey.durationMin;
    if (journey.startMin == null) return const [];
    if (i == 0) return ['departs ${formatClock(journey.startMin)}'];
    if (i == n - 1) return dur == null ? const [] : ['arrives ${journey.timeLabel(dur)}'];
    final a = s.arrivalOffset;
    if (a == null) return const [];
    return ['arr ${journey.timeLabel(a)}', 'stops ${s.dwellMin} min', 'dep ${journey.timeLabel(a + s.dwellMin)}'];
  }

  Widget _row(BuildContext context, RouteStop s, int i, int n) {
    final theme = Theme.of(context);
    final role = [if (s.isBoarding) 'Boarding', if (s.isDropping) 'Dropping'].join(' · ');
    final edge = i == 0 ? 'Starting point' : (i == n - 1 ? 'Destination' : null);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 24,
            child: Column(
              children: [
                Expanded(child: Container(width: 2, color: i == 0 ? Colors.transparent : AppColors.border)),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (i == 0 || i == n - 1) ? theme.colorScheme.primary : theme.colorScheme.surface,
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                  ),
                ),
                Expanded(child: Container(width: 2, color: i == n - 1 ? Colors.transparent : AppColors.border)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.name.isEmpty ? 'Stop ${i + 1}' : s.name, style: theme.textTheme.titleSmall),
                  Text(
                    [
                      ?edge,
                      if (role.isNotEmpty) role,
                      ..._times(s, i, n),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The timelines of one revision (outbound, and the return of a round trip) from a
/// `route_revisions` row with embedded journeys and stops.
class RevisionTimelines extends StatelessWidget {
  const RevisionTimelines({super.key, required this.revision});

  final Map<String, dynamic> revision;

  @override
  Widget build(BuildContext context) {
    final journeys = List<Map<String, dynamic>>.from((revision['route_revision_journeys'] as List?) ?? const []);
    final out = journeys.where((j) => j['direction'] == 'outbound').firstOrNull;
    final ret = journeys.where((j) => j['direction'] == 'return').firstOrNull;
    final roundTrip = revision['trip_type'] == 'round_trip';
    return Column(
      children: [
        if (out != null) JourneyTimeline(journey: journeyFromRevision(out), title: roundTrip ? 'Outbound journey' : 'Journey'),
        if (ret != null) JourneyTimeline(journey: journeyFromRevision(ret), title: 'Return journey'),
        if (out == null && ret == null) const AppEmptyState(message: 'No stops configured.', icon: Icons.alt_route),
      ],
    );
  }
}
