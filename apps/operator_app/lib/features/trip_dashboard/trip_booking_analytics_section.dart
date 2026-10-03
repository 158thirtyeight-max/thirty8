import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../charts/analytics_charts.dart';
import '../earnings/earnings_models.dart';

/// Bookings → analytics: capacity / confirmed / pending / available / cancelled tiles,
/// the status distribution and how bookings built up before departure.
class TripBookingAnalyticsSection extends ConsumerWidget {
  const TripBookingAnalyticsSection({super.key, required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(tripBookingStatsProvider(tripId));
    final trend = ref.watch(tripBookingTrendProvider(tripId));
    final theme = Theme.of(context);

    Widget tile(String label, String value) => Expanded(
          child: AppCard(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.xs),
            child: Column(children: [
              Text(value, style: theme.textTheme.titleMedium),
              Text(label, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            ]),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        stats.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load booking statistics.', onRetry: () => ref.invalidate(tripBookingStatsProvider(tripId))),
          data: (s) => Column(
            children: [
              Row(children: [
                tile('Capacity', '${s.capacity}'),
                const SizedBox(width: AppSpacing.xs),
                tile('Confirmed', '${s.confirmedSeats}'),
                const SizedBox(width: AppSpacing.xs),
                tile('Pending', '${s.pendingReservations}'),
              ]),
              const SizedBox(height: AppSpacing.xs),
              Row(children: [
                tile('Available', '${s.availableSeats}'),
                const SizedBox(width: AppSpacing.xs),
                tile('Cancelled', '${s.cancelledBookings}'),
                const SizedBox(width: AppSpacing.xs),
                tile('Occupancy', '${s.occupancyPct.toStringAsFixed(s.occupancyPct % 1 == 0 ? 0 : 1)}%'),
              ]),
              const SizedBox(height: AppSpacing.sm),
              BookingStatusChart(stats: s),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AsyncChart<BookingTrend>(
          value: trend,
          isEmpty: (_) => false,
          emptyMessage: '',
          onRetry: () => ref.invalidate(tripBookingTrendProvider(tripId)),
          builder: (t) => BookingTrendChart(trend: t),
        ),
      ],
    );
  }
}
