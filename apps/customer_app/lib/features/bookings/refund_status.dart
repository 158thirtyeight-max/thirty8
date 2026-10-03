/// Plain-language text for a booking's refund and cancellation terms.
///
/// The customer only ever READS these: refunds are requested by cancelling, then reviewed, approved and executed by
/// thirty8 in the admin panel. Amounts come from the backend (`get_my_refund_status`, `get_booking_cancellation_policy`);
/// nothing here calculates or changes money.
library;

import 'package:intl/intl.dart';

String _rupees(num? cents) {
  if (cents == null) return '-';
  final c = cents.round();
  return '₹${(c / 100).toStringAsFixed(c % 100 == 0 ? 0 : 2)}';
}

class RefundLine {
  const RefundLine({required this.title, required this.detail, required this.tone});
  final String title;
  final String detail;

  /// 'progress' | 'done' | 'problem' | 'neutral'
  final String tone;
}

RefundLine refundStatusLine(Map<String, dynamic> r) {
  final status = r['status'] as String? ?? '';
  final refund = r['refund_cents'] as num?;
  final deduction = r['deduction_cents'] as num?;
  final deductionText = (deduction != null && deduction > 0) ? ' (cancellation deduction ${_rupees(deduction)})' : '';
  switch (status) {
    case 'requested':
      return const RefundLine(
        title: 'Refund requested',
        detail: 'thirty8 is reviewing your request under the cancellation policy. You will see the amount once it is approved.',
        tone: 'progress',
      );
    case 'approved':
      return RefundLine(
        title: 'Refund approved: ${_rupees(refund)}',
        detail: 'Approved$deductionText. It will be sent to your original payment method shortly.',
        tone: 'progress',
      );
    case 'submitted_to_provider':
      return RefundLine(
        title: 'Refund on its way: ${_rupees(refund)}',
        detail: 'Sent to your payment provider. Banks usually take 5 to 7 working days to show it.',
        tone: 'progress',
      );
    case 'processed':
      final when = r['processed_at'] as String?;
      final date = when == null ? '' : ' on ${DateFormat('d MMM yyyy').format(DateTime.parse(when).toLocal())}';
      return RefundLine(
        title: 'Refunded ${_rupees(refund)}',
        detail: 'Your payment provider processed the refund$date$deductionText.',
        tone: 'done',
      );
    case 'failed':
      return const RefundLine(
        title: 'Refund delayed',
        detail: 'The refund could not be completed yet. thirty8 is retrying it; you do not need to do anything.',
        tone: 'problem',
      );
    case 'rejected':
      final reason = (r['rejection_reason'] as String?)?.trim();
      return RefundLine(
        title: 'Refund not approved',
        detail: reason == null || reason.isEmpty ? 'Your refund request was declined. Contact support if you disagree.' : 'Your refund request was declined: $reason',
        tone: 'problem',
      );
    default:
      return RefundLine(title: 'Refund: $status', detail: '', tone: 'neutral');
  }
}

/// "Cancel 24 hours or more before departure: 80% refund".
String policyTierLine(Map<String, dynamic> tier) {
  final bps = (tier['refund_bps'] as num?)?.toInt() ?? 0;
  final pct = bps % 100 == 0 ? '${bps ~/ 100}%' : '${(bps / 100).toStringAsFixed(2)}%';
  final min = double.tryParse('${tier['min_hours'] ?? ''}');
  final max = double.tryParse('${tier['max_hours'] ?? ''}');
  String hours(double h) => h == h.roundToDouble() ? '${h.round()}' : h.toStringAsFixed(1);
  final String when;
  if (min == null && max == null) {
    when = 'Cancelling at any time';
  } else if (max == null) {
    when = 'Cancelling ${hours(min!)} hours or more before departure';
  } else if (min == null || min == 0) {
    when = 'Cancelling less than ${hours(max)} hours before departure';
  } else {
    when = 'Cancelling between ${hours(min)} and ${hours(max)} hours before departure';
  }
  final category = (tier['category'] as String?) ?? '';
  final label = category == 'operator_cancelled' ? 'If the bus operator cancels the trip' : category == 'system_failure' ? 'If we could not confirm your booking' : when;
  return '$label: $pct refund';
}
