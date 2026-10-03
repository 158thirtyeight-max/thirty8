import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/notifications/notifications.dart';

void main() {
  OperatorNotification n(String type, {bool read = false}) => OperatorNotification.fromJson({
        'id': type, 'title': 't', 'body': 'b', 'type': type, 'is_read': read, 'created_at': '2026-10-03T10:00:00Z',
      });

  test('parsing tolerates missing optional fields', () {
    final x = OperatorNotification.fromJson({'id': 'a', 'created_at': '2026-10-03T10:00:00Z'});
    expect(x.title, '');
    expect(x.body, isNull);
    expect(x.isRead, isFalse);
  });

  test('unread count', () {
    expect(unreadCount([n('operator_payout_paid'), n('operator_payout_failed', read: true), n('operator_ticket_cancelled')]), 2);
    expect(unreadCount(const []), 0);
  });

  test('each kind of financial notification has its own icon, unknown ones a default', () {
    expect(n('operator_payout_paid').icon, Icons.account_balance_outlined);
    expect(n('operator_settlement_approved').icon, Icons.account_balance_outlined);
    expect(n('operator_payment_profile_failed').icon, Icons.verified_user_outlined);
    expect(n('operator_ticket_recovered').icon, Icons.confirmation_number_outlined);
    expect(n('operator_earning_eligible').icon, Icons.trending_up);
    expect(n('something_else').icon, Icons.notifications_none);
  });
}
