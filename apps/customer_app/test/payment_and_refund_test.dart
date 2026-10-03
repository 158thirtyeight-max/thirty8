import 'package:customer_app/features/booking/payment_outcome.dart';
import 'package:customer_app/features/bookings/refund_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('payment outcomes (the checkout callback alone never confirms a ticket)', () {
    test('only an explicit ok from the backend confirms', () {
      expect(interpretVerifyResponse(200, {'ok': true, 'status': 'confirmed'}), PaymentOutcome.confirmed);
      expect(interpretVerifyResponse(200, {'ok': false}), PaymentOutcome.unreachable);
      expect(interpretVerifyResponse(200, null), PaymentOutcome.unreachable);
    });

    test('a payment still being captured is "processing", never a failure', () {
      expect(interpretVerifyResponse(202, {'ok': false, 'code': 'payment_pending'}), PaymentOutcome.processing);
      expect(interpretVerifyResponse(202, null), PaymentOutcome.processing);
    });

    test('money received but booking not confirmed is its own outcome (refund requested)', () {
      expect(interpretVerifyResponse(409, {'ok': false, 'code': 'payment_not_applied'}), PaymentOutcome.notApplied);
      expect(paymentOutcomeMessage(PaymentOutcome.notApplied), contains('refund has been requested'));
    });

    test('a failed payment may be retried; a mismatch may not', () {
      expect(interpretVerifyResponse(402, {'code': 'payment_failed'}), PaymentOutcome.failed);
      expect(interpretVerifyResponse(400, {'code': 'payment_rejected'}), PaymentOutcome.rejected);
      expect(interpretVerifyResponse(400, {'error': 'Invalid payment signature'}), PaymentOutcome.rejected);
    });

    test('network or server trouble is "unknown, check again", and tells the customer not to pay twice', () {
      expect(interpretVerifyResponse(null, null), PaymentOutcome.unreachable);
      expect(interpretVerifyResponse(502, {'code': 'provider_unavailable'}), PaymentOutcome.unreachable);
      expect(interpretVerifyResponse(500, {'error': 'x'}), PaymentOutcome.unreachable);
      expect(paymentOutcomeMessage(PaymentOutcome.unreachable), contains('twice'));
      expect(paymentOutcomeMessage(PaymentOutcome.processing), contains('do not pay again'));
    });

    test('an order that is no longer payable is explained instead of retried', () {
      expect(orderNotPayableMessage('Order is not payable (status: paid)'), contains('already been paid'));
      expect(orderNotPayableMessage('Order is not payable (status: cancelled)'), contains('can no longer be paid'));
      expect(orderNotPayableMessage('Failed to create payment order'), isNull);
      expect(orderNotPayableMessage(null), isNull);
    });
  });

  group('refund status text', () {
    test('requested: awaiting review, no amount promised', () {
      final l = refundStatusLine({'status': 'requested', 'refund_cents': 50000});
      expect(l.title, 'Refund requested');
      expect(l.detail, contains('reviewing'));
      expect(l.title, isNot(contains('₹')));
      expect(l.tone, 'progress');
    });

    test('approved and on its way show the amount from the backend', () {
      expect(refundStatusLine({'status': 'approved', 'refund_cents': 40000, 'deduction_cents': 10000}).title, 'Refund approved: ₹400');
      expect(refundStatusLine({'status': 'approved', 'refund_cents': 40000, 'deduction_cents': 10000}).detail, contains('cancellation deduction ₹100'));
      expect(refundStatusLine({'status': 'submitted_to_provider', 'refund_cents': 40000}).title, contains('₹400'));
    });

    test('only a processed refund says "Refunded"', () {
      final done = refundStatusLine({'status': 'processed', 'refund_cents': 33300, 'processed_at': '2026-10-03T10:00:00Z'});
      expect(done.title, 'Refunded ₹333');
      expect(done.tone, 'done');
      for (final s in ['requested', 'approved', 'submitted_to_provider', 'failed']) {
        expect(refundStatusLine({'status': s, 'refund_cents': 100}).title, isNot(startsWith('Refunded')));
      }
    });

    test('failed is reassuring, rejected shows the reason', () {
      expect(refundStatusLine({'status': 'failed'}).detail, contains('retrying'));
      final r = refundStatusLine({'status': 'rejected', 'rejection_reason': 'Trip was used'});
      expect(r.title, 'Refund not approved');
      expect(r.detail, contains('Trip was used'));
    });
  });

  group('cancellation policy text', () {
    test('windows read naturally', () {
      expect(policyTierLine({'category': 'passenger_cancellation', 'refund_bps': 8000, 'min_hours': '24', 'max_hours': null}), 'Cancelling 24 hours or more before departure: 80% refund');
      expect(policyTierLine({'category': 'passenger_cancellation', 'refund_bps': 5000, 'min_hours': '0', 'max_hours': '24'}), 'Cancelling less than 24 hours before departure: 50% refund');
      expect(policyTierLine({'category': 'passenger_cancellation', 'refund_bps': 2500, 'min_hours': '6', 'max_hours': '24'}), 'Cancelling between 6 and 24 hours before departure: 25% refund');
      expect(policyTierLine({'category': 'default', 'refund_bps': 1250, 'min_hours': null, 'max_hours': null}), 'Cancelling at any time: 12.50% refund');
    });

    test('operator cancellation and system failure are labelled by situation', () {
      expect(policyTierLine({'category': 'operator_cancelled', 'refund_bps': 10000}), 'If the bus operator cancels the trip: 100% refund');
      expect(policyTierLine({'category': 'system_failure', 'refund_bps': 10000}), contains('could not confirm your booking'));
    });
  });
}
