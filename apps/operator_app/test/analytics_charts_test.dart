import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/charts/analytics_charts.dart';
import 'package:operator_app/features/earnings/earnings_models.dart';

TripFinancials fin({
  int gross = 100000,
  int collected = 100000,
  int rDone = 0,
  int rInit = 0,
  int commission = 10000,
  int net = 90000,
  int paid = 0,
  int remaining = 90000,
  int discrepancy = 0,
  bool configured = true,
}) =>
    TripFinancials.fromJson({
      'gross_cents': gross,
      'sold_tickets': 2,
      'collected_cents': collected,
      'refunds_completed_cents': rDone,
      'refunds_initiated_cents': rInit,
      'commission_cents': commission,
      'commission_configured': configured,
      'commission_is_estimate': true,
      'net_payable_cents': net,
      'paid_cents': paid,
      'remaining_cents': remaining,
      'discrepancy_cents': discrepancy,
    });

Widget host(Widget child, {double width = 360}) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: width, child: SingleChildScrollView(child: child))))),
    );

void main() {
  group('chart data builders', () {
    test('revenue distribution: operator + platform (+ other) = gross, refunds are not a slice', () {
      final f = fin(gross: 100000, commission: 10000, rDone: 20000);
      final slices = breakdownSlices(f);
      expect(slices.fold<int>(0, (s, e) => s + e.cents), f.grossCents);
      expect(slices.any((s) => s.label.toLowerCase().contains('refund')), isFalse);
    });

    test('commission slice is labelled as an estimate when it is one', () {
      expect(breakdownSlices(fin()).any((s) => s.label.contains('est.')), isTrue);
    });

    test('zero slices are dropped (no commission configured)', () {
      expect(breakdownSlices(fin(commission: 0)).length, 1);
    });

    test('collection bars keep each concept separate and explained', () {
      final bars = collectionBars(fin(gross: 100000, collected: 90000, rDone: 20000, net: 90000, paid: 30000, remaining: 60000));
      expect(bars.map((b) => b.label), ['Gross sales', 'Collected', 'Refunded', 'Net payable', 'Paid', 'Pending']);
      expect(bars[0].cents, 100000);
      expect(bars[1].cents, 90000, reason: 'collected is not gross');
      expect(bars.every((b) => b.meaning.isNotEmpty), isTrue);
    });

    test('a negative remaining balance is not drawn as a negative bar', () {
      final bars = collectionBars(fin(remaining: -45000));
      expect(bars.last.cents, 0);
    });

    test('status distribution drops empty states', () {
      final parts = statusDistribution(const BookingStats(
        capacity: 4, confirmedSeats: 2, pendingReservations: 0, availableSeats: 1, blockedSeats: 0, cancelledBookings: 1, cancelledSeats: 1, occupancyPct: 50));
      expect(parts.map((p) => p.label), ['Confirmed', 'Available', 'Cancelled']);
    });

    test('axis maximum always has headroom and is never zero', () {
      expect(niceMax(0), 100);
      expect(niceMax(1000), greaterThan(1000));
    });

    test('booking trend plots real points', () {
      final spots = bookingTrendSpots(BookingTrend(capacity: 4, points: [
        TrendPoint(at: DateTime(2026, 10, 1), cumulativeSeats: 2, daysBeforeDeparture: 5),
        TrendPoint(at: DateTime(2026, 10, 2), cumulativeSeats: 3, daysBeforeDeparture: 4),
      ]));
      expect(spots.map((s) => s.y), [2, 3]);
      expect(spots.map((s) => s.x), [5, 4]);
    });
  });

  group('chart widgets render every state without fake data', () {
    testWidgets('revenue breakdown with sales', (tester) async {
      await tester.pumpWidget(host(RevenueBreakdownChart(financials: fin(rDone: 5000, rInit: 1000))));
      expect(find.text('Revenue distribution'), findsOneWidget);
      expect(find.textContaining('Refunds completed'), findsOneWidget);
      expect(find.textContaining('Refunds initiated'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('revenue breakdown empty state', (tester) async {
      await tester.pumpWidget(host(RevenueBreakdownChart(financials: fin(gross: 0, commission: 0, net: 0, collected: 0, remaining: 0))));
      expect(find.text('No confirmed sales yet.'), findsOneWidget);
    });

    testWidgets('collection chart lists labelled figures and flags a discrepancy', (tester) async {
      await tester.pumpWidget(host(CollectionVsSettlementChart(financials: fin(discrepancy: -50000, collected: 50000))));
      expect(find.textContaining('Payments actually received'), findsOneWidget);
      expect(find.textContaining('flagged for review'), findsOneWidget);
    });

    testWidgets('booking trend and status empty states', (tester) async {
      await tester.pumpWidget(host(const BookingTrendChart(trend: BookingTrend(capacity: 4, points: []))));
      expect(find.text('No confirmed bookings yet.'), findsOneWidget);
      await tester.pumpWidget(host(const BookingStatusChart(
        stats: BookingStats(capacity: 0, confirmedSeats: 0, pendingReservations: 0, availableSeats: 0, blockedSeats: 0, cancelledBookings: 0, cancelledSeats: 0, occupancyPct: 0))));
      expect(find.text('No seats on this trip.'), findsOneWidget);
    });

    testWidgets('revenue trend empty state and with data', (tester) async {
      await tester.pumpWidget(host(const RevenueTrendChart(points: [])));
      expect(find.text('No sales in this period.'), findsOneWidget);
      await tester.pumpWidget(host(RevenueTrendChart(points: [
        RevenuePoint(bucket: DateTime(2026, 10, 1), grossCents: 100000, netPayableCents: 90000, tickets: 2),
        RevenuePoint(bucket: DateTime(2026, 10, 2), grossCents: 50000, netPayableCents: 45000, tickets: 1),
      ])));
      expect(find.text('Revenue trend'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('settlement status chart shows amounts per state, and an empty state', (tester) async {
      await tester.pumpWidget(host(SettlementStatusChart(buckets: {for (final s in SettlementStatus.values) s: const SettlementBucket(count: 0, netCents: 0, paidCents: 0)})));
      expect(find.text('No settlements in this period.'), findsOneWidget);
      await tester.pumpWidget(host(SettlementStatusChart(buckets: {
        for (final s in SettlementStatus.values)
          s: s == SettlementStatus.paid ? const SettlementBucket(count: 2, netCents: 90000, paidCents: 90000) : const SettlementBucket(count: 0, netCents: 0, paidCents: 0),
      })));
      expect(find.text('Paid · 2'), findsOneWidget);
      expect(find.text('₹900'), findsOneWidget);
    });

    testWidgets('all charts fit a 320 dp phone', (tester) async {
      await tester.pumpWidget(host(
        Column(children: [
          RevenueBreakdownChart(financials: fin(rDone: 5000)),
          CollectionVsSettlementChart(financials: fin()),
          RevenueTrendChart(points: [
            RevenuePoint(bucket: DateTime(2026, 10, 1), grossCents: 100000, netPayableCents: 90000, tickets: 2),
            RevenuePoint(bucket: DateTime(2026, 10, 2), grossCents: 150000, netPayableCents: 90000, tickets: 2),
          ]),
        ]),
        width: 320,
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('AsyncChart shows loading, error and empty states', (tester) async {
      await tester.pumpWidget(host(AsyncChart<int>(value: const AsyncLoading(), isEmpty: (_) => false, emptyMessage: 'none', builder: (_) => const Text('data'))));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpWidget(host(AsyncChart<int>(value: AsyncError(Exception('x'), StackTrace.empty), isEmpty: (_) => false, emptyMessage: 'none', builder: (_) => const Text('data'))));
      expect(find.text('Could not load this chart.'), findsOneWidget);
      await tester.pumpWidget(host(AsyncChart<int>(value: const AsyncData(0), isEmpty: (d) => d == 0, emptyMessage: 'nothing here', builder: (_) => const Text('data'))));
      expect(find.text('nothing here'), findsOneWidget);
    });
  });
}
