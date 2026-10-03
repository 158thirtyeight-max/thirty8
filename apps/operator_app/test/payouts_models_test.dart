import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/earnings/earnings_models.dart';
import 'package:operator_app/features/earnings/finance_models.dart';

void main() {
  group('settlement statuses from the weekly engine', () {
    test('backend states map to operator-friendly states', () {
      expect(SettlementStatusX.parse('approved'), SettlementStatus.approved);
      expect(SettlementStatusX.parse('exported'), SettlementStatus.sentToBank);
      expect(SettlementStatusX.parse('on_hold'), SettlementStatus.onHold);
      expect(SettlementStatusX.parse('partially_paid'), SettlementStatus.processing);
      expect(SettlementStatusX.parse('cancelled'), SettlementStatus.cancelled);
      expect(SettlementStatusX.parse('paid'), SettlementStatus.paid);
      expect(SettlementStatusX.parse('unknown-future-state'), SettlementStatus.pending);
    });

    test('summary buckets use the backend key, not the Dart name', () {
      expect(SettlementStatus.sentToBank.backendKey, 'exported');
      expect(SettlementStatus.onHold.backendKey, 'on_hold');
      expect(SettlementStatus.paid.backendKey, 'paid');
      final s = EarningsSummary.fromJson({
        'supported': true,
        'settlements_by_status': {
          'exported': {'count': 2, 'net_cents': 90000, 'paid_cents': 0},
          'paid': {'count': 1, 'net_cents': 45000, 'paid_cents': 45000},
        },
      });
      expect(s.settlements[SettlementStatus.sentToBank]!.netCents, 90000);
      expect(s.settlements[SettlementStatus.paid]!.count, 1);
      expect(s.settlements[SettlementStatus.onHold]!.count, 0);
    });

    test('labels and colours: only the engine states are new, the originals are unchanged', () {
      expect(SettlementStatus.sentToBank.label, 'Sent to bank');
      expect(SettlementStatus.approved.label, 'Approved');
      expect(SettlementStatus.paid.color, const Color(0xFF10B981));
      expect(SettlementStatus.failed.color, const Color(0xFFEF4444));
      expect(SettlementStatus.paid.isCore, isTrue);
      expect(SettlementStatus.sentToBank.isCore, isFalse);
    });

    test('settlement detail carries credits, recovery netting and the separate dates', () {
      final d = SettlementDetail.fromJson({
        'id': 'a',
        'reference': 'ST-1',
        'status': 'approved',
        'net_payable_cents': 62500,
        'paid_cents': 0,
        'outstanding_cents': 62500,
        'created_at': '2026-10-03T10:00:00Z',
        'gross_cents': 100000,
        'refunds_cents': 0,
        'commission_cents': 10000,
        'other_deductions_cents': 27500,
        'adjustment_credits_cents': 2500,
        'recovery_netted_cents': 30000,
        'approved_at': '2026-10-04T10:00:00Z',
        'exported_at': null,
        'bank_paid_at': null,
        'period_start': '2026-09-27',
        'period_end': '2026-10-03',
        'trips': 1,
      });
      expect(d.creditsCents, 2500);
      expect(d.recoveryNettedCents, 30000);
      expect(d.approvedAt, isNotNull);
      expect(d.exportedAt, isNull);
      expect(d.bankPaidAt, isNull);
      expect(d.calculationAddsUp, isTrue, reason: 'gross - commission - (recovery - credits) = net');
    });

    test('an older response without the new fields still parses', () {
      final d = SettlementDetail.fromJson({
        'id': 'a', 'reference': 'ST-0', 'status': 'paid', 'net_payable_cents': 90000, 'paid_cents': 90000, 'outstanding_cents': 0,
        'created_at': '2026-10-03T10:00:00Z', 'gross_cents': 100000, 'refunds_cents': 0, 'commission_cents': 10000, 'other_deductions_cents': 0,
        'period_start': '2026-09-27', 'period_end': '2026-10-03', 'trips': 1,
      });
      expect(d.creditsCents, 0);
      expect(d.approvedAt, isNull);
      expect(d.calculationAddsUp, isTrue);
    });
  });

  group('read-only finance models', () {
    test('earnings breakdown', () {
      final b = EarningsBreakdown.fromJson({
        'gross_cents': 100000, 'commission_cents': 10000, 'net_cents': 90000, 'pending_boarding_cents': 45000, 'eligible_cents': 45000,
        'on_hold_cents': 0, 'processing_cents': 0, 'settled_cents': 0, 'refund_adjustment_cents': 45000, 'recovery_open_cents': 35000,
        'commission_unresolved_count': 1, 'tickets': 2,
      });
      expect(b.netCents, 90000);
      expect(b.recoveryOpenCents, 35000);
      expect(b.commissionUnresolvedCount, 1);
      expect(EarningsBreakdown.fromJson({}).grossCents, 0, reason: 'missing numbers are zero, never a crash');
    });

    test('payout profile shows only what the backend sends (masked)', () {
      final p = PaymentProfile.fromJson({
        'verification_status': 'verified', 'settlement_eligible': true, 'account_masked': 'XXXXXXXX9012', 'ifsc_masked': 'SBIN*******',
        'bank_name': 'SBI', 'account_holder': 'Operator A', 'payout_method': 'manual_sbi',
      });
      expect(p.statusLabel, 'Verified');
      expect(p.hasBankDetails, isTrue);
      expect(p.accountMasked, 'XXXXXXXX9012');
      expect(p.payoutMethodLabel, 'Weekly bank transfer');
      final u = PaymentProfile.fromJson({'verification_status': 'unverified', 'settlement_eligible': false, 'required_action': 'Your bank details are awaiting verification by thirty8.'});
      expect(u.statusLabel, 'Awaiting verification');
      expect(u.hasBankDetails, isFalse);
      expect(u.requiredAction, contains('awaiting verification'));
      expect(PaymentProfile.fromJson({'verification_status': 'failed'}).statusLabel, 'Verification failed');
    });

    test('refund adjustment: net impact, status wording and after-payout flag', () {
      final r = RefundAdjustment.fromJson({
        'ticket_reference': 'TH123', 'original_amount_cents': 50000, 'refund_amount_cents': 40000, 'cancellation_deduction_cents': 10000,
        'commission_adjustment_cents': 5000, 'net_impact_cents': -42500, 'refund_status': 'processed', 'processed_at': '2026-10-03T10:00:00Z',
        'earning_status': 'clawed_back',
      });
      expect(r.netImpactCents, -42500);
      expect(r.statusLabel, 'Refunded');
      expect(r.afterPayout, isTrue);
      final pending = RefundAdjustment.fromJson({'ticket_reference': 'TH9', 'original_amount_cents': 50000, 'commission_adjustment_cents': 0, 'earning_status': 'void'});
      expect(pending.refundAmountCents, isNull);
      expect(pending.statusLabel, 'No refund requested');
      expect(pending.afterPayout, isFalse);
      expect(RefundAdjustment.fromJson({'refund_status': 'requested', 'original_amount_cents': 1, 'earning_status': 'void'}).statusLabel, 'Refund requested');
      expect(RefundAdjustment.fromJson({'refund_status': 'rejected', 'original_amount_cents': 1, 'earning_status': 'void'}).statusLabel, 'Refund declined');
    });

    test('recovery', () {
      final r = OperatorRecovery.fromJson({'amount_cents': 45000, 'recovered_cents': 10000, 'outstanding_cents': 35000, 'status': 'partially_recovered', 'reason': 'x', 'created_at': '2026-10-03T10:00:00Z'});
      expect(r.outstandingCents, 35000);
      expect(r.statusLabel, 'Partly recovered');
      expect(OperatorRecovery.fromJson({'status': 'written_off', 'created_at': '2026-10-03T10:00:00Z'}).statusLabel, 'Written off');
    });
  });
}
