import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/bus_ops/schedule_trip_screen.dart';
import 'package:operator_app/features/bus_ops/trip_models.dart';

Map<String, dynamic> tripJson({
  String status = 'scheduled',
  int total = 40,
  int sold = 0,
  int held = 0,
  int blocked = 0,
  String? arrival = '2026-10-05T10:00:00Z',
}) =>
    {
      'id': 't1',
      'bus_id': 'b1',
      'bus_registration': 'AN01L5656',
      'bus_name': 'Toto',
      'source_name': 'Port Blair',
      'destination_name': 'Rangat',
      'departure_at': '2026-10-05T06:00:00Z',
      'arrival_at': arrival,
      'status': status,
      'total_seats': total,
      'sold_seats': sold,
      'held_seats': held,
      'blocked_seats': blocked,
    };

void main() {
  group('trip buckets', () {
    test('status maps to the same bucket as the server', () {
      expect(TripBucketX.forStatus('scheduled'), TripBucket.upcoming);
      expect(TripBucketX.forStatus('boarding'), TripBucket.active);
      expect(TripBucketX.forStatus('departed'), TripBucket.active);
      expect(TripBucketX.forStatus('arrived'), TripBucket.completed);
      expect(TripBucketX.forStatus('cancelled'), TripBucket.cancelled);
    });
  });

  group('OperatorTrip', () {
    test('parses route, bus and times', () {
      final t = OperatorTrip.fromJson(tripJson());
      expect(t.routeLabel, 'Port Blair → Rangat');
      expect(t.busRegistration, 'AN01L5656');
      expect(t.arrivalAt, isNotNull);
      expect(t.bucket, TripBucket.upcoming);
    });

    test('arrival is optional', () {
      expect(OperatorTrip.fromJson(tripJson(arrival: null)).arrivalAt, isNull);
    });

    test('availability = total - sold - held - blocked, never negative', () {
      final t = OperatorTrip.fromJson(tripJson(total: 40, sold: 10, held: 3, blocked: 2));
      expect(t.availableSeats, 25);
      final over = OperatorTrip.fromJson(tripJson(total: 4, sold: 4, held: 2));
      expect(over.availableSeats, 0);
    });

    test('sold fraction handles empty bus and full bus', () {
      expect(OperatorTrip.fromJson(tripJson(total: 0)).soldFraction, 0);
      expect(OperatorTrip.fromJson(tripJson(total: 40, sold: 40)).soldFraction, 1);
      expect(OperatorTrip.fromJson(tripJson(total: 40, sold: 10)).soldFraction, 0.25);
    });
  });

  group('TripListResult', () {
    test('parses counts per bucket and items', () {
      final r = TripListResult.fromJson({
        'counts': {'upcoming': 3, 'active': 1, 'completed': 7, 'cancelled': 0},
        'items': [tripJson()],
      });
      expect(r.counts[TripBucket.upcoming], 3);
      expect(r.counts[TripBucket.completed], 7);
      expect(r.items, hasLength(1));
    });

    test('missing counts default to zero', () {
      final r = TripListResult.fromJson({'items': []});
      expect(r.counts.values.every((v) => v == 0), isTrue);
    });
  });

  test('TripQuery value equality keys the provider cache', () {
    expect(const TripQuery('o', TripBucket.active, 'b'), const TripQuery('o', TripBucket.active, 'b'));
    expect(const TripQuery('o', TripBucket.active), isNot(const TripQuery('o', TripBucket.upcoming)));
    expect(const TripQuery('o', TripBucket.active, 'b'), isNot(const TripQuery('o', TripBucket.active)));
  });

  group('schedule time helpers', () {
    test('parses Postgres time strings', () {
      expect(parseTimeOfDayMinutes('06:00:00'), 360);
      expect(parseTimeOfDayMinutes('18:30'), 1110);
      expect(parseTimeOfDayMinutes(null), isNull);
      expect(parseTimeOfDayMinutes('x'), isNull);
    });

    test('formats 12-hour clock including stop offsets past midnight', () {
      expect(formatMinutesOfDay(360), '6:00 AM');
      expect(formatMinutesOfDay(0), '12:00 AM');
      expect(formatMinutesOfDay(12 * 60 + 5), '12:05 PM');
      expect(formatMinutesOfDay(23 * 60 + 30 + 120), '1:30 AM');
    });
  });
}
