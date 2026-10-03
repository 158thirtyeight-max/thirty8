import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

/// READ-ONLY financial information for an operator's own business.
///
/// Operators never calculate, request, approve or change refunds, commission, payouts or recoveries: all of that is
/// decided by thirty8 in the admin panel. Every figure here comes from authorised read-only RPCs
/// (`get_operator_earnings_breakdown`, `get_my_payment_profile`, `get_operator_refund_adjustments`,
/// `list_operator_recoveries`), which also enforce that an operator only ever sees its own records.

int _i(Object? v) => (v as num?)?.toInt() ?? 0;
int? _iOrNull(Object? v) => (v as num?)?.toInt();

/// Where an operator's earnings stand: boarding makes a ticket eligible, the weekly settlement pays it.
@immutable
class EarningsBreakdown {
  const EarningsBreakdown({
    required this.grossCents,
    required this.commissionCents,
    required this.netCents,
    required this.pendingBoardingCents,
    required this.eligibleCents,
    required this.onHoldCents,
    required this.processingCents,
    required this.settledCents,
    required this.refundAdjustmentCents,
    required this.recoveryOpenCents,
    required this.commissionUnresolvedCount,
    required this.tickets,
  });

  final int grossCents;
  final int commissionCents;
  final int netCents;
  final int pendingBoardingCents;
  final int eligibleCents;
  final int onHoldCents;
  final int processingCents;
  final int settledCents;
  final int refundAdjustmentCents;
  final int recoveryOpenCents;
  final int commissionUnresolvedCount;
  final int tickets;

  factory EarningsBreakdown.fromJson(Map<String, dynamic> j) => EarningsBreakdown(
        grossCents: _i(j['gross_cents']),
        commissionCents: _i(j['commission_cents']),
        netCents: _i(j['net_cents']),
        pendingBoardingCents: _i(j['pending_boarding_cents']),
        eligibleCents: _i(j['eligible_cents']),
        onHoldCents: _i(j['on_hold_cents']),
        processingCents: _i(j['processing_cents']),
        settledCents: _i(j['settled_cents']),
        refundAdjustmentCents: _i(j['refund_adjustment_cents']),
        recoveryOpenCents: _i(j['recovery_open_cents']),
        commissionUnresolvedCount: _i(j['commission_unresolved_count']),
        tickets: _i(j['tickets']),
      );
}

/// The operator's payout profile as thirty8 sees it. The account number is masked by the backend.
@immutable
class PaymentProfile {
  const PaymentProfile({
    required this.verificationStatus,
    required this.settlementEligible,
    required this.requiredAction,
    required this.bankName,
    required this.accountHolder,
    required this.accountMasked,
    required this.ifscMasked,
    required this.payoutMethod,
  });

  final String verificationStatus; // unverified | verified | failed
  final bool settlementEligible;
  final String? requiredAction;
  final String? bankName;
  final String? accountHolder;
  final String? accountMasked;
  final String? ifscMasked;
  final String payoutMethod;

  bool get hasBankDetails => accountMasked != null;

  String get statusLabel => switch (verificationStatus) {
        'verified' => 'Verified',
        'failed' => 'Verification failed',
        _ => 'Awaiting verification',
      };

  String get payoutMethodLabel => switch (payoutMethod) {
        'manual_sbi' => 'Weekly bank transfer',
        _ => payoutMethod.replaceAll('_', ' '),
      };

  factory PaymentProfile.fromJson(Map<String, dynamic> j) => PaymentProfile(
        verificationStatus: j['verification_status'] as String? ?? 'unverified',
        settlementEligible: j['settlement_eligible'] == true,
        requiredAction: j['required_action'] as String?,
        bankName: j['bank_name'] as String?,
        accountHolder: j['account_holder'] as String?,
        accountMasked: j['account_masked'] as String?,
        ifscMasked: j['ifsc_masked'] as String?,
        payoutMethod: j['payout_method'] as String? ?? 'manual_sbi',
      );
}

/// One cancelled or refunded ticket and what it did to this operator's earnings.
@immutable
class RefundAdjustment {
  const RefundAdjustment({
    required this.ticketReference,
    required this.originalAmountCents,
    required this.refundAmountCents,
    required this.cancellationDeductionCents,
    required this.commissionAdjustmentCents,
    required this.netImpactCents,
    required this.refundStatus,
    required this.processedAt,
    required this.earningStatus,
  });

  final String ticketReference;
  final int originalAmountCents;
  final int? refundAmountCents;
  final int? cancellationDeductionCents;
  final int commissionAdjustmentCents;
  final int? netImpactCents;
  final String? refundStatus;
  final DateTime? processedAt;
  final String earningStatus;

  /// 'No refund yet' when the customer has not been refunded for this ticket.
  String get statusLabel => switch (refundStatus) {
        null => 'No refund requested',
        'requested' => 'Refund requested',
        'approved' => 'Refund approved',
        'submitted_to_provider' => 'Refund in progress',
        'processed' => 'Refunded',
        'failed' => 'Refund delayed',
        'rejected' => 'Refund declined',
        final other => other,
      };

  /// True when this ticket reduced the operator's earnings after they were already paid.
  bool get afterPayout => earningStatus == 'clawed_back';

  factory RefundAdjustment.fromJson(Map<String, dynamic> j) => RefundAdjustment(
        ticketReference: j['ticket_reference'] as String? ?? '',
        originalAmountCents: _i(j['original_amount_cents']),
        refundAmountCents: _iOrNull(j['refund_amount_cents']),
        cancellationDeductionCents: _iOrNull(j['cancellation_deduction_cents']),
        commissionAdjustmentCents: _i(j['commission_adjustment_cents']),
        netImpactCents: _iOrNull(j['net_impact_cents']),
        refundStatus: j['refund_status'] as String?,
        processedAt: j['processed_at'] == null ? null : DateTime.parse(j['processed_at'] as String).toLocal(),
        earningStatus: j['earning_status'] as String? ?? '',
      );
}

/// Money an operator owes thirty8 after a refund on an already-paid ticket. Netted from future payouts by thirty8.
@immutable
class OperatorRecovery {
  const OperatorRecovery({
    required this.amountCents,
    required this.recoveredCents,
    required this.outstandingCents,
    required this.status,
    required this.reason,
    required this.createdAt,
  });

  final int amountCents;
  final int recoveredCents;
  final int outstandingCents;
  final String status;
  final String reason;
  final DateTime createdAt;

  String get statusLabel => switch (status) {
        'open' => 'Outstanding',
        'partially_recovered' => 'Partly recovered',
        'recovered' => 'Recovered',
        'written_off' => 'Written off',
        final other => other,
      };

  factory OperatorRecovery.fromJson(Map<String, dynamic> j) => OperatorRecovery(
        amountCents: _i(j['amount_cents']),
        recoveredCents: _i(j['recovered_cents']),
        outstandingCents: _i(j['outstanding_cents']),
        status: j['status'] as String? ?? 'open',
        reason: j['reason'] as String? ?? '',
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );
}

final earningsBreakdownProvider = FutureProvider.autoDispose.family<EarningsBreakdown, String>((ref, operatorId) async {
  final res = await ref.read(supabaseProvider).rpc('get_operator_earnings_breakdown', params: {'p_operator_id': operatorId});
  return EarningsBreakdown.fromJson(Map<String, dynamic>.from(res as Map));
});

final paymentProfileProvider = FutureProvider.autoDispose.family<PaymentProfile, String>((ref, operatorId) async {
  final res = await ref.read(supabaseProvider).rpc('get_my_payment_profile', params: {'p_operator_id': operatorId});
  return PaymentProfile.fromJson(Map<String, dynamic>.from(res as Map));
});

final refundAdjustmentsProvider = FutureProvider.autoDispose.family<List<RefundAdjustment>, String>((ref, operatorId) async {
  final res = await ref.read(supabaseProvider).rpc('get_operator_refund_adjustments', params: {'p_operator_id': operatorId});
  return [for (final r in (res as List)) RefundAdjustment.fromJson(Map<String, dynamic>.from(r as Map))];
});

final operatorRecoveriesProvider = FutureProvider.autoDispose.family<List<OperatorRecovery>, String>((ref, operatorId) async {
  final res = await ref.read(supabaseProvider).rpc('list_operator_recoveries', params: {'p_operator_id': operatorId});
  return [for (final r in (res as List)) OperatorRecovery.fromJson(Map<String, dynamic>.from(r as Map))];
});
