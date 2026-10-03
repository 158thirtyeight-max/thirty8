import 'dart:math' as math;

import 'package:design_system/design_system.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../earnings/earnings_models.dart';

// ---------------------------------------------------------------------------------------------
// Pure data builders (unit tested): what each chart actually plots.
// ---------------------------------------------------------------------------------------------
class Slice {
  const Slice(this.label, this.cents, this.color);

  final String label;
  final int cents;
  final Color color;
}

/// Donut: how the GROSS splits between the operator, the platform and other deductions.
/// Refunds are deliberately not a slice — they are money returned to customers.
List<Slice> breakdownSlices(TripFinancials f) => [
      Slice('Operator payable', f.operatorShareCents, AppColors.primary),
      Slice(f.commissionIsEstimate ? 'Platform commission (est.)' : 'Platform commission', f.commissionCents, AppColors.warning),
      if (f.otherDeductionsCents > 0) Slice('Other deductions', f.otherDeductionsCents, AppColors.textTertiary),
    ].where((s) => s.cents > 0).toList();

class BarDatum {
  const BarDatum(this.label, this.cents, this.color, this.meaning);

  final String label;
  final int cents;
  final Color color;

  /// One line saying what the number is — the chart never leaves a figure unexplained.
  final String meaning;
}

/// Bars that keep sales, money received, refunds, payable and payout apart.
List<BarDatum> collectionBars(TripFinancials f) => [
      BarDatum('Gross sales', f.grossCents, AppColors.primary, 'Value of confirmed tickets'),
      BarDatum('Collected', f.collectedCents, AppColors.success, 'Payments actually received'),
      BarDatum('Refunded', f.refundsCompletedCents, AppColors.error, 'Refunds completed to customers'),
      BarDatum('Net payable', f.netPayableCents, AppColors.info, 'Gross minus commission'),
      BarDatum('Paid', f.paidCents, AppColors.success, 'Already paid to the operator'),
      BarDatum('Pending', f.remainingCents < 0 ? 0 : f.remainingCents, AppColors.warning, 'Still to be paid out'),
    ];

class StatusSlice {
  const StatusSlice(this.label, this.seats, this.color);

  final String label;
  final int seats;
  final Color color;
}

List<StatusSlice> statusDistribution(BookingStats s) => [
      StatusSlice('Confirmed', s.confirmedSeats, AppColors.primary),
      StatusSlice('Pending', s.pendingReservations, AppColors.warning),
      StatusSlice('Available', s.availableSeats, AppColors.success),
      StatusSlice('Blocked', s.blockedSeats, AppColors.textTertiary),
      StatusSlice('Cancelled', s.cancelledSeats, AppColors.error),
    ].where((e) => e.seats > 0).toList();

/// Upper bound for a money axis with a little headroom (never 0).
double niceMax(num value) => value <= 0 ? 100 : (value * 1.15).ceilToDouble();

/// Trend points → (x = days before departure, y = confirmed seats), earliest booking first.
List<FlSpot> bookingTrendSpots(BookingTrend t) => [for (final p in t.points) FlSpot(p.daysBeforeDeparture, p.cumulativeSeats.toDouble())];

// ---------------------------------------------------------------------------------------------
// shell with loading / empty / error states
// ---------------------------------------------------------------------------------------------
class ChartCard extends StatelessWidget {
  const ChartCard({super.key, required this.title, this.subtitle, required this.child});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          if (subtitle != null) Text(subtitle!, style: theme.textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// Renders an AsyncValue as a chart, with real loading / error / empty states (never fake data).
class AsyncChart<T> extends StatelessWidget {
  const AsyncChart({
    super.key,
    required this.value,
    required this.isEmpty,
    required this.emptyMessage,
    required this.builder,
    this.onRetry,
  });

  final AsyncValue<T> value;
  final bool Function(T data) isEmpty;
  final String emptyMessage;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
      error: (e, _) => AppErrorState(message: 'Could not load this chart.', onRetry: onRetry),
      data: (d) => isEmpty(d)
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(child: Text(emptyMessage, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall)),
            )
          : builder(d),
    );
  }
}

Widget _legendRow(BuildContext context, Color color, String label, String value) {
  final style = Theme.of(context).textTheme.bodySmall;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: style)),
        Text(value, style: style?.copyWith(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------------------------
// charts
// ---------------------------------------------------------------------------------------------
/// Donut of the gross, with refunds shown separately underneath.
class RevenueBreakdownChart extends StatelessWidget {
  const RevenueBreakdownChart({super.key, required this.financials});

  final TripFinancials financials;

  @override
  Widget build(BuildContext context) {
    final f = financials;
    final slices = breakdownSlices(f);
    final theme = Theme.of(context);
    return ChartCard(
      title: 'Revenue distribution',
      subtitle: 'How the gross ticket value of ${formatMoney(f.grossCents)} is shared',
      child: f.grossCents == 0
          ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Center(child: Text('No confirmed sales yet.', style: theme.textTheme.bodySmall)))
          : Column(
              children: [
                SizedBox(
                  height: 170,
                  child: PieChart(PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 44,
                    sections: [
                      for (final s in slices)
                        PieChartSectionData(
                          value: s.cents.toDouble(),
                          color: s.color,
                          radius: 36,
                          title: '${(s.cents * 100 / f.grossCents).round()}%',
                          titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                    ],
                  )),
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final s in slices) _legendRow(context, s.color, s.label, formatMoney(s.cents)),
                const Divider(height: AppSpacing.md),
                _legendRow(context, AppColors.error, 'Refunds completed (money back to customers)', formatMoney(f.refundsCompletedCents)),
                _legendRow(context, AppColors.warning, 'Refunds initiated, not yet completed', formatMoney(f.refundsInitiatedCents)),
              ],
            ),
    );
  }
}

/// Gross vs collected vs refunds vs payable vs paid vs pending, each labelled.
class CollectionVsSettlementChart extends StatelessWidget {
  const CollectionVsSettlementChart({super.key, required this.financials});

  final TripFinancials financials;

  @override
  Widget build(BuildContext context) {
    final bars = collectionBars(financials);
    final maxY = niceMax(bars.map((b) => b.cents).fold<int>(0, math.max));
    final theme = Theme.of(context);
    return ChartCard(
      title: 'Collection vs settlement',
      subtitle: 'Sales, money received and what has been paid out',
      child: Column(
        children: [
          SizedBox(
            height: 190,
            child: BarChart(BarChartData(
              maxY: maxY,
              alignment: BarChartAlignment.spaceAround,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              barTouchData: BarTouchData(enabled: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 46,
                    getTitlesWidget: (v, meta) => v == meta.max
                        ? const SizedBox.shrink()
                        : Text(formatMoney(v, compact: true), style: const TextStyle(fontSize: 9)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (v, meta) => SideTitleWidget(
                      meta: meta,
                      child: Text(bars[v.toInt()].label.replaceFirst(' ', '\n'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 8.5)),
                    ),
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < bars.length; i++)
                  BarChartGroupData(x: i, barRods: [
                    BarChartRodData(toY: bars[i].cents.toDouble(), color: bars[i].color, width: 16, borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
                  ]),
              ],
            )),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final b in bars) _legendRow(context, b.color, '${b.label} — ${b.meaning}', formatMoney(b.cents)),
          if (financials.hasDiscrepancy)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Money received differs from sales by ${formatMoney(financials.discrepancyCents)} — this is flagged for review, not hidden.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning),
              ),
            ),
        ],
      ),
    );
  }
}

/// Seat status distribution of a trip as a donut.
class BookingStatusChart extends StatelessWidget {
  const BookingStatusChart({super.key, required this.stats});

  final BookingStats stats;

  @override
  Widget build(BuildContext context) {
    final parts = statusDistribution(stats);
    return ChartCard(
      title: 'Booking status',
      subtitle: 'Seats by state · capacity ${stats.capacity}',
      child: parts.isEmpty
          ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Center(child: Text('No seats on this trip.', style: Theme.of(context).textTheme.bodySmall)))
          : Row(
              children: [
                SizedBox(
                  width: 130,
                  height: 130,
                  child: PieChart(PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 30,
                    sections: [for (final p in parts) PieChartSectionData(value: p.seats.toDouble(), color: p.color, radius: 26, showTitle: false)],
                  )),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(children: [for (final p in parts) _legendRow(context, p.color, p.label, '${p.seats}')]),
                ),
              ],
            ),
    );
  }
}

/// Cumulative confirmed seats against days before departure (from real booking timestamps).
class BookingTrendChart extends StatelessWidget {
  const BookingTrendChart({super.key, required this.trend});

  final BookingTrend trend;

  @override
  Widget build(BuildContext context) {
    final spots = bookingTrendSpots(trend);
    return ChartCard(
      title: 'Booking progress',
      subtitle: 'Confirmed seats as departure approached',
      child: spots.isEmpty
          ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Center(child: Text('No confirmed bookings yet.', style: Theme.of(context).textTheme.bodySmall)))
          : SizedBox(
              height: 180,
              child: LineChart(LineChartData(
                minY: 0,
                maxY: math.max(trend.capacity.toDouble(), 1),
                // earliest bookings are far from departure: x runs from "N days before" down to 0
                minX: 0,
                maxX: math.max(spots.map((s) => s.x).fold<double>(0, math.max).ceilToDouble(), 1),
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 28, getTitlesWidget: (v, m) => Text(v.toInt().toString(), style: const TextStyle(fontSize: 9)))),
                  bottomTitles: AxisTitles(
                    axisNameWidget: const Text('days before departure', style: TextStyle(fontSize: 9)),
                    sideTitles: SideTitles(showTitles: true, reservedSize: 22, getTitlesWidget: (v, m) => SideTitleWidget(meta: m, child: Text(v.toStringAsFixed(v % 1 == 0 ? 0 : 1), style: const TextStyle(fontSize: 9)))),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots.reversed.toList(),
                    isCurved: false,
                    color: AppColors.primary,
                    barWidth: 3,
                    dotData: const FlDotData(show: true),
                    belowBarData: BarAreaData(show: true, color: AppColors.primary.withValues(alpha: 0.12)),
                  ),
                ],
              )),
            ),
    );
  }
}

/// Gross sales by day/week for the selected range.
class RevenueTrendChart extends StatelessWidget {
  const RevenueTrendChart({super.key, required this.points});

  final List<RevenuePoint> points;

  @override
  Widget build(BuildContext context) {
    final spots = [for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].grossCents.toDouble())];
    final maxY = niceMax(points.map((p) => p.grossCents).fold<int>(0, math.max));
    final fmt = DateFormat('d MMM');
    return ChartCard(
      title: 'Revenue trend',
      subtitle: 'Gross ticket sales by travel date',
      child: points.isEmpty || points.every((p) => p.grossCents == 0)
          ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Center(child: Text('No sales in this period.', style: Theme.of(context).textTheme.bodySmall)))
          : SizedBox(
              height: 180,
              child: LineChart(LineChartData(
                minY: 0,
                maxY: maxY,
                minX: 0,
                maxX: math.max(points.length - 1, 1).toDouble(),
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 46, getTitlesWidget: (v, m) => v == m.max ? const SizedBox.shrink() : Text(formatMoney(v, compact: true), style: const TextStyle(fontSize: 9)))),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: math.max((points.length / 4).ceil(), 1).toDouble(),
                      getTitlesWidget: (v, m) {
                        final i = v.toInt();
                        if (i < 0 || i >= points.length) return const SizedBox.shrink();
                        return SideTitleWidget(meta: m, child: Text(fmt.format(points[i].bucket), style: const TextStyle(fontSize: 9)));
                      },
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: false,
                    color: AppColors.primary,
                    barWidth: 3,
                    dotData: FlDotData(show: points.length <= 14),
                    belowBarData: BarAreaData(show: true, color: AppColors.primary.withValues(alpha: 0.12)),
                  ),
                ],
              )),
            ),
    );
  }
}

/// Amount per settlement state (not just counts): Paid / Processing / Pending / Failed / Reversed.
class SettlementStatusChart extends StatelessWidget {
  const SettlementStatusChart({super.key, required this.buckets});

  final Map<SettlementStatus, SettlementBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxNet = buckets.values.fold<int>(0, (m, b) => math.max(m, b.netCents));
    final any = buckets.values.any((b) => b.count > 0);
    return ChartCard(
      title: 'Settlement status',
      subtitle: 'Amount per state',
      child: !any
          ? Padding(padding: const EdgeInsets.all(AppSpacing.md), child: Center(child: Text('No settlements in this period.', style: theme.textTheme.bodySmall)))
          : Column(
              children: [
                for (final s in SettlementStatus.values.where((s) => s.isCore || (buckets[s]?.count ?? 0) > 0))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                            const SizedBox(width: 8),
                            Expanded(child: Text('${s.label} · ${buckets[s]!.count}', style: theme.textTheme.bodySmall)),
                            Text(formatMoney(buckets[s]!.netCents), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 3),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: maxNet == 0 ? 0 : buckets[s]!.netCents / maxNet,
                            minHeight: 6,
                            color: s.color,
                            backgroundColor: s.color.withValues(alpha: 0.12),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
