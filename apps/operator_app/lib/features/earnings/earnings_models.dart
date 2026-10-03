import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

/// ₹ with Indian digit grouping. Whole rupees drop the decimals.
String formatMoney(num cents, {bool compact = false}) {
  final rupees = cents / 100;
  if (compact && rupees.abs() >= 100000) {
    return '${rupees < 0 ? '-' : ''}₹${NumberFormat.compact(locale: 'en_IN').format(rupees.abs())}';
  }
  final whole = cents % 100 == 0;
  return NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: whole ? 0 : 2).format(rupees);
}

int _i(Object? v) => (v as num?)?.toInt() ?? 0;

DateTime? _dt(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

/// Everything one trip earned, collected, refunded and was paid — from `get_trip_financials`.
/// Gross sales are never presented as money received: [collectedCents] is separate.
@immutable
class TripFinancials {
  const TripFinancials({
    required this.grossCents,
    required this.soldTickets,
    required this.cancelledValueCents,
    required this.collectedCents,
    required this.pendingPaymentsCents,
    required this.failedPaymentsCents,
    required this.refundsInitiatedCents,
    required this.refundsCompletedCents,
    required this.commissionCents,
    required this.commissionConfigured,
    required this.commissionIsEstimate,
    required this.refundDeductionsCents,
    required this.otherDeductionsCents,
    required this.netPayableCents,
    required this.paidCents,
    required this.remainingCents,
    required this.discrepancyCents,
  });

  final int grossCents;
  final int soldTickets;
  final int cancelledValueCents;
  final int collectedCents;
  final int pendingPaymentsCents;
  final int failedPaymentsCents;
  final int refundsInitiatedCents;
  final int refundsCompletedCents;
  final int commissionCents;
  final bool commissionConfigured;
  final bool commissionIsEstimate;
  final int refundDeductionsCents;
  final int otherDeductionsCents;
  final int netPayableCents;
  final int paidCents;
  final int remainingCents;

  /// Collected − (sold + cancelled-after-payment). Non-zero means the books need a look.
  final int discrepancyCents;

  bool get hasDiscrepancy => discrepancyCents != 0;

  /// Slices of the gross for the donut: what the operator gets, what the platform keeps,
  /// other deductions. Refunds are NOT a slice (they are money back to customers).
  int get operatorShareCents => (grossCents - commissionCents - otherDeductionsCents).clamp(0, grossCents);

  factory TripFinancials.fromJson(Map<String, dynamic> j) => TripFinancials(
        grossCents: _i(j['gross_cents']),
        soldTickets: _i(j['sold_tickets']),
        cancelledValueCents: _i(j['cancelled_value_cents']),
        collectedCents: _i(j['collected_cents']),
        pendingPaymentsCents: _i(j['pending_payments_cents']),
        failedPaymentsCents: _i(j['failed_payments_cents']),
        refundsInitiatedCents: _i(j['refunds_initiated_cents']),
        refundsCompletedCents: _i(j['refunds_completed_cents']),
        commissionCents: _i(j['commission_cents']),
        commissionConfigured: j['commission_configured'] == true,
        commissionIsEstimate: j['commission_is_estimate'] == true,
        refundDeductionsCents: _i(j['refund_deductions_cents']),
        otherDeductionsCents: _i(j['other_deductions_cents']),
        netPayableCents: _i(j['net_payable_cents']),
        paidCents: _i(j['paid_cents']),
        remainingCents: _i(j['remaining_cents']),
        discrepancyCents: _i(j['discrepancy_cents']),
      );
}

/// What the operator sees for a settlement batch. `approved`, `sentToBank`, `onHold` and `cancelled` come from the
/// weekly settlement engine (drafts are internal and never reach the operator app). The status always comes from the
/// settlement record: nothing in this app can change it.
enum SettlementStatus { paid, processing, pending, failed, reversed, approved, sentToBank, onHold, cancelled }

extension SettlementStatusX on SettlementStatus {
  /// The status string used by the backend (summary buckets are keyed by it).
  String get backendKey => switch (this) {
        SettlementStatus.sentToBank => 'exported',
        SettlementStatus.onHold => 'on_hold',
        _ => name,
      };

  static SettlementStatus parse(String? v) => switch (v) {
        'paid' => SettlementStatus.paid,
        'processing' => SettlementStatus.processing,
        'partially_paid' => SettlementStatus.processing,
        'approved' => SettlementStatus.approved,
        'exported' => SettlementStatus.sentToBank,
        'on_hold' => SettlementStatus.onHold,
        'failed' => SettlementStatus.failed,
        'reversed' => SettlementStatus.reversed,
        'cancelled' => SettlementStatus.cancelled,
        _ => SettlementStatus.pending,
      };

  String get label => switch (this) {
        SettlementStatus.paid => 'Paid',
        SettlementStatus.processing => 'Processing',
        SettlementStatus.pending => 'Pending',
        SettlementStatus.failed => 'Failed',
        SettlementStatus.reversed => 'Reversed',
        SettlementStatus.approved => 'Approved',
        SettlementStatus.sentToBank => 'Sent to bank',
        SettlementStatus.onHold => 'On hold',
        SettlementStatus.cancelled => 'Cancelled',
      };

  /// Paid green · Processing/Sent blue · Pending/Approved/On hold amber · Failed red · Reversed/Cancelled grey.
  Color get color => switch (this) {
        SettlementStatus.paid => const Color(0xFF10B981),
        SettlementStatus.processing => const Color(0xFF3B82F6),
        SettlementStatus.sentToBank => const Color(0xFF3B82F6),
        SettlementStatus.pending => const Color(0xFFF59E0B),
        SettlementStatus.approved => const Color(0xFFF59E0B),
        SettlementStatus.onHold => const Color(0xFFF59E0B),
        SettlementStatus.failed => const Color(0xFFEF4444),
        SettlementStatus.reversed => const Color(0xFF9B96AC),
        SettlementStatus.cancelled => const Color(0xFF9B96AC),
      };

  /// The five states the summary chart always shows; the engine's extra states appear only when something is in them.
  bool get isCore => const {SettlementStatus.paid, SettlementStatus.processing, SettlementStatus.pending, SettlementStatus.failed, SettlementStatus.reversed}.contains(this);
}

@immutable
class SettlementBucket {
  const SettlementBucket({required this.count, required this.netCents, required this.paidCents});

  final int count;
  final int netCents;
  final int paidCents;
  int get outstandingCents => netCents - paidCents;
}

@immutable
class EarningsSummary {
  const EarningsSummary({
    required this.supported,
    required this.grossSalesCents,
    required this.ticketsSold,
    required this.completedBookings,
    required this.cancelledBookings,
    required this.cancelledValueCents,
    required this.collectedCents,
    required this.refundsInitiatedCents,
    required this.refundsCompletedCents,
    required this.platformFeesCents,
    required this.platformFeesEstimatedCents,
    required this.commissionConfigured,
    required this.netPayableCents,
    required this.paidToOperatorCents,
    required this.pendingSettlementCents,
    required this.discrepancyCents,
    required this.settlements,
  });

  final bool supported;
  final int grossSalesCents;
  final int ticketsSold;
  final int completedBookings;
  final int cancelledBookings;
  final int cancelledValueCents;
  final int collectedCents;
  final int refundsInitiatedCents;
  final int refundsCompletedCents;
  final int platformFeesCents;
  final int platformFeesEstimatedCents;
  final bool commissionConfigured;
  final int netPayableCents;
  final int paidToOperatorCents;
  final int pendingSettlementCents;
  final int discrepancyCents;
  final Map<SettlementStatus, SettlementBucket> settlements;

  bool get hasAnySales => grossSalesCents != 0 || ticketsSold != 0 || completedBookings != 0 || cancelledBookings != 0;
  bool get hasAnySettlement => settlements.values.any((b) => b.count > 0);
  bool get feesAreEstimate => platformFeesEstimatedCents > 0 || !commissionConfigured;

  factory EarningsSummary.fromJson(Map<String, dynamic> j) {
    final by = (j['settlements_by_status'] as Map?) ?? const {};
    return EarningsSummary(
      supported: j['supported'] == true,
      grossSalesCents: _i(j['gross_sales_cents']),
      ticketsSold: _i(j['tickets_sold']),
      completedBookings: _i(j['completed_bookings']),
      cancelledBookings: _i(j['cancelled_bookings']),
      cancelledValueCents: _i(j['cancelled_value_cents']),
      collectedCents: _i(j['collected_cents']),
      refundsInitiatedCents: _i(j['refunds_initiated_cents']),
      refundsCompletedCents: _i(j['refunds_completed_cents']),
      platformFeesCents: _i(j['platform_fees_cents']),
      platformFeesEstimatedCents: _i(j['platform_fees_estimated_cents']),
      commissionConfigured: j['commission_configured'] == true,
      netPayableCents: _i(j['net_payable_cents']),
      paidToOperatorCents: _i(j['paid_to_operator_cents']),
      pendingSettlementCents: _i(j['pending_settlement_cents']),
      discrepancyCents: _i(j['discrepancy_cents']),
      settlements: {
        for (final s in SettlementStatus.values)
          s: SettlementBucket(
            count: _i((by[s.backendKey] as Map?)?['count']),
            netCents: _i((by[s.backendKey] as Map?)?['net_cents']),
            paidCents: _i((by[s.backendKey] as Map?)?['paid_cents']),
          ),
      },
    );
  }
}

@immutable
class RevenuePoint {
  const RevenuePoint({required this.bucket, required this.grossCents, required this.netPayableCents, required this.tickets});

  final DateTime bucket;
  final int grossCents;
  final int netPayableCents;
  final int tickets;

  factory RevenuePoint.fromJson(Map<String, dynamic> j) => RevenuePoint(
        bucket: DateTime.parse(j['bucket'] as String),
        grossCents: _i(j['gross_cents']),
        netPayableCents: _i(j['net_payable_cents']),
        tickets: _i(j['tickets']),
      );
}

@immutable
class SettlementRow {
  const SettlementRow({
    required this.id,
    required this.reference,
    required this.status,
    required this.netPayableCents,
    required this.paidCents,
    required this.outstandingCents,
    required this.createdAt,
    this.initiatedAt,
    this.completedAt,
    this.method,
    this.txnReference,
  });

  final String id;
  final String reference;
  final SettlementStatus status;
  final int netPayableCents;
  final int paidCents;
  final int outstandingCents;
  final DateTime createdAt;
  final DateTime? initiatedAt;
  final DateTime? completedAt;
  final String? method;
  final String? txnReference;

  factory SettlementRow.fromJson(Map<String, dynamic> j) => SettlementRow(
        id: j['id'] as String,
        reference: j['reference'] as String,
        status: SettlementStatusX.parse(j['status'] as String?),
        netPayableCents: _i(j['net_payable_cents']),
        paidCents: _i(j['paid_cents']),
        outstandingCents: _i(j['outstanding_cents']),
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
        initiatedAt: j['initiated_at'] == null ? null : DateTime.parse(j['initiated_at'] as String).toLocal(),
        completedAt: j['completed_at'] == null ? null : DateTime.parse(j['completed_at'] as String).toLocal(),
        method: j['method'] as String?,
        txnReference: j['txn_reference'] as String?,
      );
}

/// Gross eligible − refund deductions − commission − other deductions = net payable;
/// net payable − paid = outstanding.
@immutable
class SettlementDetail {
  const SettlementDetail({
    required this.row,
    required this.grossCents,
    required this.refundsCents,
    required this.commissionCents,
    required this.otherDeductionsCents,
    required this.periodStart,
    required this.periodEnd,
    required this.trips,
    this.failureReason,
    this.creditsCents = 0,
    this.recoveryNettedCents = 0,
    this.approvedAt,
    this.exportedAt,
    this.bankPaidAt,
  });

  final SettlementRow row;
  final int grossCents;
  final int refundsCents;
  final int commissionCents;
  final int otherDeductionsCents;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int trips;
  final String? failureReason;

  /// Operator share of cancellation deductions credited in this batch, and recoveries netted against it
  /// (other deductions = recovery netted − credits).
  final int creditsCents;
  final int recoveryNettedCents;
  final DateTime? approvedAt;
  final DateTime? exportedAt;
  final DateTime? bankPaidAt;

  int get netPayableCents => row.netPayableCents;
  int get paidCents => row.paidCents;
  int get outstandingCents => row.outstandingCents;

  /// True when the stored lines add up — what the screen shows is verifiable.
  bool get calculationAddsUp => grossCents - refundsCents - commissionCents - otherDeductionsCents == netPayableCents;

  factory SettlementDetail.fromJson(Map<String, dynamic> j) => SettlementDetail(
        row: SettlementRow.fromJson(j),
        grossCents: _i(j['gross_cents']),
        refundsCents: _i(j['refunds_cents']),
        commissionCents: _i(j['commission_cents']),
        otherDeductionsCents: _i(j['other_deductions_cents']),
        periodStart: DateTime.parse(j['period_start'] as String),
        periodEnd: DateTime.parse(j['period_end'] as String),
        trips: _i(j['trips']),
        failureReason: j['failure_reason'] as String?,
        creditsCents: _i(j['adjustment_credits_cents']),
        recoveryNettedCents: _i(j['recovery_netted_cents']),
        approvedAt: _dt(j['approved_at']),
        exportedAt: _dt(j['exported_at']),
        bankPaidAt: _dt(j['bank_paid_at']),
      );
}

@immutable
class TripEarningsRow {
  const TripEarningsRow({
    required this.tripId,
    required this.routeLabel,
    required this.busRegistration,
    required this.departureAt,
    required this.status,
    required this.grossCents,
    required this.soldTickets,
    required this.netPayableCents,
    required this.paidCents,
    required this.remainingCents,
  });

  final String tripId;
  final String routeLabel;
  final String busRegistration;
  final DateTime departureAt;
  final String status;
  final int grossCents;
  final int soldTickets;
  final int netPayableCents;
  final int paidCents;
  final int remainingCents;

  factory TripEarningsRow.fromJson(Map<String, dynamic> j) => TripEarningsRow(
        tripId: j['trip_id'] as String,
        routeLabel: '${j['source_name'] ?? '—'} → ${j['destination_name'] ?? '—'}',
        busRegistration: (j['bus_registration'] as String?) ?? '',
        departureAt: DateTime.parse(j['departure_at'] as String).toLocal(),
        status: j['status'] as String,
        grossCents: _i(j['gross_cents']),
        soldTickets: _i(j['sold_tickets']),
        netPayableCents: _i(j['net_payable_cents']),
        paidCents: _i(j['paid_cents']),
        remainingCents: _i(j['remaining_cents']),
      );
}

@immutable
class BookingStats {
  const BookingStats({
    required this.capacity,
    required this.confirmedSeats,
    required this.pendingReservations,
    required this.availableSeats,
    required this.blockedSeats,
    required this.cancelledBookings,
    required this.cancelledSeats,
    required this.occupancyPct,
  });

  final int capacity;
  final int confirmedSeats;
  final int pendingReservations;
  final int availableSeats;
  final int blockedSeats;
  final int cancelledBookings;
  final int cancelledSeats;
  final double occupancyPct;

  factory BookingStats.fromJson(Map<String, dynamic> j) => BookingStats(
        capacity: _i(j['capacity']),
        confirmedSeats: _i(j['confirmed_seats']),
        pendingReservations: _i(j['pending_reservations']),
        availableSeats: _i(j['available_seats']),
        blockedSeats: _i(j['blocked_seats']),
        cancelledBookings: _i(j['cancelled_bookings']),
        cancelledSeats: _i(j['cancelled_seats']),
        occupancyPct: (j['occupancy_pct'] as num?)?.toDouble() ?? 0,
      );
}

@immutable
class TrendPoint {
  const TrendPoint({required this.at, required this.cumulativeSeats, required this.daysBeforeDeparture});

  final DateTime at;
  final int cumulativeSeats;
  final double daysBeforeDeparture;

  factory TrendPoint.fromJson(Map<String, dynamic> j) => TrendPoint(
        at: DateTime.parse(j['at'] as String).toLocal(),
        cumulativeSeats: _i(j['cumulative_seats']),
        daysBeforeDeparture: (j['days_before_departure'] as num?)?.toDouble() ?? 0,
      );
}

class BookingTrend {
  const BookingTrend({required this.capacity, required this.points});

  final int capacity;
  final List<TrendPoint> points;
}

// ---------------------------------------------------------------------------------------------
// date filter
// ---------------------------------------------------------------------------------------------
enum DatePreset { today, thisWeek, thisMonth, custom }

extension DatePresetX on DatePreset {
  String get label => switch (this) {
        DatePreset.today => 'Today',
        DatePreset.thisWeek => 'This week',
        DatePreset.thisMonth => 'This month',
        DatePreset.custom => 'Custom range',
      };
}

/// Inclusive date range for a preset. Weeks start on Monday.
({DateTime from, DateTime to}) rangeFor(DatePreset preset, DateTime now, {DateTime? customFrom, DateTime? customTo}) {
  final today = DateTime(now.year, now.month, now.day);
  switch (preset) {
    case DatePreset.today:
      return (from: today, to: today);
    case DatePreset.thisWeek:
      final monday = today.subtract(Duration(days: today.weekday - 1));
      return (from: monday, to: monday.add(const Duration(days: 6)));
    case DatePreset.thisMonth:
      return (from: DateTime(today.year, today.month, 1), to: DateTime(today.year, today.month + 1, 0));
    case DatePreset.custom:
      final a = customFrom ?? today;
      final b = customTo ?? a;
      return b.isBefore(a) ? (from: b, to: a) : (from: a, to: b);
  }
}

String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

// ---------------------------------------------------------------------------------------------
// providers
// ---------------------------------------------------------------------------------------------
@immutable
class EarningsQuery {
  const EarningsQuery(this.operatorId, this.from, this.to, [this.service = 'bus']);

  final String operatorId;
  final DateTime from;
  final DateTime to;
  final String service;

  @override
  bool operator ==(Object other) =>
      other is EarningsQuery && other.operatorId == operatorId && other.from == from && other.to == to && other.service == service;

  @override
  int get hashCode => Object.hash(operatorId, from, to, service);
}

final earningsSummaryProvider = FutureProvider.autoDispose.family<EarningsSummary, EarningsQuery>((ref, q) async {
  final res = await ref.watch(supabaseProvider).rpc('get_operator_earnings_summary', params: {
    'p_operator_id': q.operatorId,
    'p_from': isoDate(q.from),
    'p_to': isoDate(q.to),
    'p_service': q.service,
  });
  return EarningsSummary.fromJson(Map<String, dynamic>.from(res as Map));
});

final revenueTrendProvider = FutureProvider.autoDispose.family<List<RevenuePoint>, EarningsQuery>((ref, q) async {
  final days = q.to.difference(q.from).inDays;
  final res = await ref.watch(supabaseProvider).rpc('get_operator_revenue_trend', params: {
    'p_operator_id': q.operatorId,
    'p_from': isoDate(q.from),
    'p_to': isoDate(q.to),
    'p_bucket': days > 62 ? 'week' : 'day',
    'p_service': q.service,
  });
  return [for (final p in ((res as Map)['points'] as List? ?? const [])) RevenuePoint.fromJson(Map<String, dynamic>.from(p as Map))];
});

final earningsByTripProvider = FutureProvider.autoDispose.family<List<TripEarningsRow>, EarningsQuery>((ref, q) async {
  final res = await ref.watch(supabaseProvider).rpc('list_operator_earnings_by_trip', params: {
    'p_operator_id': q.operatorId,
    'p_from': isoDate(q.from),
    'p_to': isoDate(q.to),
    'p_limit': 100,
  });
  return [for (final t in ((res as Map)['trips'] as List? ?? const [])) TripEarningsRow.fromJson(Map<String, dynamic>.from(t as Map))];
});

final settlementsProvider = FutureProvider.autoDispose.family<List<SettlementRow>, String>((ref, operatorId) async {
  final res = await ref.watch(supabaseProvider).rpc('list_operator_settlements', params: {'p_operator_id': operatorId, 'p_limit': 100});
  return [for (final s in ((res as Map)['settlements'] as List? ?? const [])) SettlementRow.fromJson(Map<String, dynamic>.from(s as Map))];
});

final settlementDetailProvider = FutureProvider.autoDispose.family<SettlementDetail, String>((ref, id) async {
  final res = await ref.watch(supabaseProvider).rpc('get_settlement_detail', params: {'p_settlement_id': id});
  return SettlementDetail.fromJson(Map<String, dynamic>.from(res as Map));
});

final tripFinancialsProvider = FutureProvider.autoDispose.family<TripFinancials, String>((ref, tripId) async {
  final res = await ref.watch(supabaseProvider).rpc('get_trip_financials', params: {'p_trip_id': tripId});
  return TripFinancials.fromJson(Map<String, dynamic>.from(res as Map));
});

final tripBookingStatsProvider = FutureProvider.autoDispose.family<BookingStats, String>((ref, tripId) async {
  final res = await ref.watch(supabaseProvider).rpc('get_trip_booking_stats', params: {'p_trip_id': tripId});
  return BookingStats.fromJson(Map<String, dynamic>.from(res as Map));
});

final tripBookingTrendProvider = FutureProvider.autoDispose.family<BookingTrend, String>((ref, tripId) async {
  final res = Map<String, dynamic>.from(await ref.watch(supabaseProvider).rpc('get_trip_booking_trend', params: {'p_trip_id': tripId}) as Map);
  return BookingTrend(
    capacity: _i(res['capacity']),
    points: [for (final p in (res['points'] as List? ?? const [])) TrendPoint.fromJson(Map<String, dynamic>.from(p as Map))],
  );
});
