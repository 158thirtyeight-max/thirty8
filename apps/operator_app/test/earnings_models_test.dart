import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/earnings/earnings_models.dart';

Map<String, dynamic> fin({
  int gross = 100000,
  int sold = 2,
  int cancelled = 0,
  int collected = 100000,
  int pending = 0,
  int failed = 0,
  int rInit = 0,
  int rDone = 0,
  int commission = 10000,
  bool configured = true,
  bool estimate = true,
  int refundDed = 0,
  int net = 90000,
  int paid = 0,
  int remaining = 90000,
  int discrepancy = 0,
}) =>
    {
      'gross_cents': gross,
      'sold_tickets': sold,
      'cancelled_value_cents': cancelled,
      'collected_cents': collected,
      'pending_payments_cents': pending,
      'failed_payments_cents': failed,
      'refunds_initiated_cents': rInit,
      'refunds_completed_cents': rDone,
      'commission_cents': commission,
      'commission_configured': configured,
      'commission_is_estimate': estimate,
      'refund_deductions_cents': refundDed,
      'other_deductions_cents': 0,
      'net_payable_cents': net,
      'paid_cents': paid,
      'remaining_cents': remaining,
      'discrepancy_cents': discrepancy,
    };

void main() {
  group('formatMoney', () {
    test('whole rupees drop decimals, paise are kept, Indian grouping', () {
      expect(formatMoney(50000), '₹500');
      expect(formatMoney(50050), '₹500.50');
      expect(formatMoney(12345678), '₹1,23,456.78');
      expect(formatMoney(0), '₹0');
    });

    test('negative amounts keep their sign', () {
      expect(formatMoney(-4500000), contains('45,000'));
      expect(formatMoney(-4500000), contains('-'));
    });

    test('compact form for axis labels', () {
      expect(formatMoney(100000000, compact: true), startsWith('₹'));
      expect(formatMoney(100000, compact: true), '₹1,000');
    });
  });

  group('TripFinancials', () {
    test('keeps sales, collected money, refunds and payout separate', () {
      final f = TripFinancials.fromJson(fin(gross: 100000, collected: 90000, pending: 10000, rInit: 5000, rDone: 20000, paid: 30000, remaining: 60000, net: 90000));
      expect(f.grossCents, 100000);
      expect(f.collectedCents, 90000, reason: 'gross sales are not money received');
      expect(f.refundsInitiatedCents, 5000);
      expect(f.refundsCompletedCents, 20000, reason: 'a refund request is not a completed refund');
      expect(f.paidCents, 30000);
      expect(f.remainingCents, 60000);
    });

    test('donut shares exclude refunds and sum to the gross', () {
      final f = TripFinancials.fromJson(fin(gross: 100000, commission: 10000, rDone: 20000));
      expect(f.operatorShareCents + f.commissionCents + f.otherDeductionsCents, f.grossCents);
    });

    test('discrepancy is flagged', () {
      expect(TripFinancials.fromJson(fin()).hasDiscrepancy, isFalse);
      expect(TripFinancials.fromJson(fin(discrepancy: -50000)).hasDiscrepancy, isTrue);
    });

    test('estimated vs not-configured commission flags', () {
      final f = TripFinancials.fromJson(fin(configured: false, estimate: true, commission: 0));
      expect(f.commissionConfigured, isFalse);
      expect(f.commissionIsEstimate, isTrue);
    });
  });

  group('EarningsSummary', () {
    final json = {
      'supported': true,
      'gross_sales_cents': 50000,
      'tickets_sold': 1,
      'completed_bookings': 1,
      'cancelled_bookings': 1,
      'refunds_completed_cents': 50000,
      'platform_fees_cents': 5000,
      'platform_fees_estimated_cents': 0,
      'commission_configured': true,
      'net_payable_cents': 45000,
      'paid_to_operator_cents': 90000,
      'pending_settlement_cents': -45000,
      'settlements_by_status': {
        'paid': {'count': 1, 'net_cents': 90000, 'paid_cents': 90000, 'outstanding_cents': 0},
        'processing': {'count': 0, 'net_cents': 0, 'paid_cents': 0, 'outstanding_cents': 0},
      },
    };

    test('parses money, counts and per-status settlement amounts', () {
      final s = EarningsSummary.fromJson(json);
      expect(s.grossSalesCents, 50000);
      expect(s.paidToOperatorCents, 90000);
      expect(s.settlements[SettlementStatus.paid]!.netCents, 90000);
      expect(s.settlements[SettlementStatus.failed]!.count, 0, reason: 'missing states default to zero');
      expect(s.hasAnySettlement, isTrue);
      expect(s.hasAnySales, isTrue);
      expect(s.feesAreEstimate, isFalse);
    });

    test('an empty period has no sales and no settlements', () {
      final s = EarningsSummary.fromJson({'supported': true});
      expect(s.hasAnySales, isFalse);
      expect(s.hasAnySettlement, isFalse);
    });
  });

  group('settlements', () {
    test('status colours follow the product spec', () {
      expect(SettlementStatus.paid.color, const Color(0xFF10B981));
      expect(SettlementStatus.processing.color, const Color(0xFF3B82F6));
      expect(SettlementStatus.pending.color, const Color(0xFFF59E0B));
      expect(SettlementStatus.failed.color, const Color(0xFFEF4444));
      expect(SettlementStatusX.parse('weird'), SettlementStatus.pending);
    });

    Map<String, dynamic> row({int net = 90000, int paid = 45000, String status = 'processing'}) => {
          'id': 's1',
          'reference': 'ST-ABCD1234',
          'status': status,
          'net_payable_cents': net,
          'paid_cents': paid,
          'outstanding_cents': net - paid,
          'created_at': '2026-10-03T10:00:00Z',
          'period_start': '2026-10-01',
          'period_end': '2026-10-07',
          'gross_cents': 100000,
          'refunds_cents': 0,
          'commission_cents': 10000,
          'other_deductions_cents': 0,
          'trips': 3,
        };

    test('detail: gross - refunds - commission - other = net; net - paid = outstanding', () {
      final d = SettlementDetail.fromJson(row());
      expect(d.calculationAddsUp, isTrue);
      expect(d.netPayableCents - d.paidCents, d.outstandingCents);
      expect(d.row.status, SettlementStatus.processing);
    });

    test('inconsistent figures are detected, not hidden', () {
      final bad = row()..['commission_cents'] = 99;
      expect(SettlementDetail.fromJson(bad).calculationAddsUp, isFalse);
    });

    test('failed settlement keeps its reason', () {
      final j = row(status: 'failed', paid: 0)..['failure_reason'] = 'Bank rejected';
      expect(SettlementDetail.fromJson(j).failureReason, 'Bank rejected');
    });
  });

  group('date filter', () {
    final wed = DateTime(2026, 10, 7); // Wednesday

    test('today', () {
      final r = rangeFor(DatePreset.today, wed);
      expect(r.from, DateTime(2026, 10, 7));
      expect(r.to, DateTime(2026, 10, 7));
    });

    test('this week runs Monday to Sunday', () {
      final r = rangeFor(DatePreset.thisWeek, wed);
      expect(r.from, DateTime(2026, 10, 5));
      expect(r.to, DateTime(2026, 10, 11));
    });

    test('this month covers the whole month', () {
      final r = rangeFor(DatePreset.thisMonth, wed);
      expect(r.from, DateTime(2026, 10, 1));
      expect(r.to, DateTime(2026, 10, 31));
      expect(rangeFor(DatePreset.thisMonth, DateTime(2026, 2, 10)).to, DateTime(2026, 2, 28));
    });

    test('custom range is ordered even if picked backwards', () {
      final r = rangeFor(DatePreset.custom, wed, customFrom: DateTime(2026, 10, 9), customTo: DateTime(2026, 10, 2));
      expect(r.from, DateTime(2026, 10, 2));
      expect(r.to, DateTime(2026, 10, 9));
    });

    test('query equality and iso formatting', () {
      expect(EarningsQuery('o', DateTime(2026, 1, 1), DateTime(2026, 1, 2)), EarningsQuery('o', DateTime(2026, 1, 1), DateTime(2026, 1, 2)));
      expect(isoDate(DateTime(2026, 3, 4)), '2026-03-04');
    });
  });

  test('booking stats and trend parse', () {
    final s = BookingStats.fromJson({'capacity': 40, 'confirmed_seats': 12, 'pending_reservations': 3, 'available_seats': 24, 'blocked_seats': 1, 'cancelled_bookings': 2, 'cancelled_seats': 3, 'occupancy_pct': 30.0});
    expect(s.confirmedSeats, 12);
    expect(s.occupancyPct, 30.0);
    final p = TrendPoint.fromJson({'at': '2026-10-01T10:00:00Z', 'cumulative_seats': 5, 'days_before_departure': 4.5});
    expect(p.cumulativeSeats, 5);
    expect(p.daysBeforeDeparture, 4.5);
  });
}
