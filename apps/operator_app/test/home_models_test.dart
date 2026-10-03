import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/home/home_models.dart';

Map<String, dynamic> trip({String status = 'scheduled', int sold = 12, int total = 40}) => {
      'id': 't1',
      'status': status,
      'departure_at': '2026-10-05T06:00:00Z',
      'bus_registration': 'AN01L5656',
      'source_name': 'Port Blair',
      'destination_name': 'Rangat',
      'sold_seats': sold,
      'total_seats': total,
    };

void main() {
  test('parses the summary the server returns for an owner', () {
    final s = HomeSummary.fromJson({
      'financials_visible': true,
      'todays_trips': 2,
      'active_trips': 1,
      'tickets_sold_today': 27,
      'todays_ticket_sales_cents': 1350000,
      'pending_payout_cents': 450000,
      'today': [trip(status: 'boarding')],
      'upcoming': [trip(), trip()],
    });
    expect(s.todaysTrips, 2);
    expect(s.ticketsSoldToday, 27);
    expect(s.todaysTicketSalesCents, 1350000);
    expect(s.pendingPayoutCents, 450000);
    expect(s.today.single.routeLabel, 'Port Blair → Rangat');
    expect(s.today.single.soldSeats, 12);
    expect(s.upcoming, hasLength(2));
    expect(s.isQuiet, isFalse);
  });

  test('staff do not receive money fields (they stay null, never 0)', () {
    final s = HomeSummary.fromJson({
      'financials_visible': false,
      'todays_trips': 1,
      'active_trips': 0,
      'tickets_sold_today': 5,
      'todays_ticket_sales_cents': null,
      'pending_payout_cents': null,
      'today': [],
      'upcoming': [],
    });
    expect(s.financialsVisible, isFalse);
    expect(s.todaysTicketSalesCents, isNull);
    expect(s.pendingPayoutCents, isNull);
  });

  test('a quiet day has nothing scheduled', () {
    final s = HomeSummary.fromJson({'financials_visible': true, 'today': [], 'upcoming': []});
    expect(s.isQuiet, isTrue);
    expect(s.todaysTrips, 0);
  });

  test('upcoming list is bounded by the server (3), the model does not invent more', () {
    final s = HomeSummary.fromJson({
      'financials_visible': true,
      'today': [],
      'upcoming': [trip(), trip(), trip()],
    });
    expect(s.upcoming.length, lessThanOrEqualTo(3));
  });
}
