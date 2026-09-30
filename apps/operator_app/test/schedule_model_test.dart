import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/schedule_model.dart';

void main() {
  group('validateSchedule', () {
    List<String> run({int? dep = 480, Set<int> days = const {1, 2}, int open = 30, int cutoff = 30, int boarding = 10}) =>
        validateSchedule(
          departureMin: dep,
          days: days,
          openDaysBefore: open,
          bookingCutoffMin: cutoff,
          boardingCutoffMin: boarding,
        );

    test('valid', () => expect(run(), isEmpty));
    test('missing departure / days', () {
      expect(run(dep: null), contains('Choose the departure time'));
      expect(run(days: {}), contains('Select at least one operating day'));
      expect(run(days: {0, 8}), contains('Operating days must be Monday to Sunday'));
    });
    test('window bounds', () {
      expect(run(open: 0), isNotEmpty);
      expect(run(open: 366), isNotEmpty);
      expect(run(cutoff: -1), isNotEmpty);
      expect(run(cutoff: 10081), isNotEmpty);
      expect(run(boarding: 10081), isNotEmpty);
    });
    test('boarding cut-off cannot be absurdly earlier than the booking cut-off', () {
      expect(run(cutoff: 0, boarding: 1500), isNotEmpty);
      expect(run(cutoff: 0, boarding: 60), isEmpty);
    });
  });

  test('tripDatesInRange follows operating days (ISO weekdays)', () {
    // 2026-06-01 is a Monday.
    final dates = tripDatesInRange(DateTime(2026, 6, 1), DateTime(2026, 6, 14), {1, 2, 3, 4, 5});
    expect(dates.length, 10);
    expect(dates.every((d) => d.weekday <= 5), isTrue);
    expect(tripDatesInRange(DateTime(2026, 6, 6), DateTime(2026, 6, 7), {6, 7}).length, 2);
    expect(tripDatesInRange(DateTime(2026, 6, 8), DateTime(2026, 6, 1), {1}), isEmpty);
    expect(tripDatesInRange(DateTime(2026, 6, 1), DateTime(2026, 6, 1), {1}).length, 1);
  });

  test('describeMinutesBefore', () {
    expect(describeMinutesBefore(0), 'At departure');
    expect(describeMinutesBefore(30), '30 min before');
    expect(describeMinutesBefore(60), '1 hour before');
    expect(describeMinutesBefore(180), '3 hours before');
    expect(describeMinutesBefore(1440), '1 day before');
  });
}
