import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:seat_map/seat_map.dart';

/// Occupancy of one trip, computed from the seat inventory (a booking with several
/// seats counts every seat; held seats are pending, not confirmed).
class TripOccupancyCard extends StatelessWidget {
  const TripOccupancyCard({super.key, required this.counts});

  final SeatCounts counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget stat(String label, int value, Color color) => Expanded(
          child: Column(
            children: [
              Text('$value', style: theme.textTheme.titleMedium?.copyWith(color: color)),
              Text(label, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            ],
          ),
        );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${counts.occupancyPct.toStringAsFixed(counts.occupancyPct % 1 == 0 ? 0 : 1)}%', style: theme.textTheme.headlineMedium),
              const SizedBox(width: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('occupancy · ${counts.sold} of ${counts.total} seats', style: theme.textTheme.bodySmall),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: counts.total == 0 ? 0 : counts.sold / counts.total, minHeight: 8),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              stat('Booked', counts.booked + counts.boarded, seatStatusColor(SeatStatus.booked)),
              stat('Held', counts.held, seatStatusColor(SeatStatus.held)),
              stat('Available', counts.available, seatStatusColor(SeatStatus.available)),
              stat('Blocked', counts.blocked, seatStatusColor(SeatStatus.blocked)),
            ],
          ),
        ],
      ),
    );
  }
}
