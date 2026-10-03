import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/route_model.dart';
import 'package:operator_app/features/fleet/stop_schedule.dart';

RouteStop _stop(String id, {bool manual = false, int? at, int dwell = 5}) =>
    RouteStop(name: id, cityId: id, isBoarding: true, isDropping: true, arrivalOffset: at, dwellMin: dwell, manualTime: manual);

JourneyDraft _journey({int start = 5 * 60, int duration = 8 * 60, List<RouteStop>? mid}) => JourneyDraft(
      sourceId: 'S',
      destId: 'D',
      startMin: start,
      durationMin: duration,
      stops: [_stop('S'), ...?mid, _stop('D')],
    );

void main() {
  group('autoSchedule', () {
    test('places new stops evenly inside the window, snapped to 5 minutes', () {
      final j = _journey(mid: [_stop('A'), _stop('B'), _stop('C')]);
      j.autoSchedule();
      final a = j.stops.sublist(1, 4).map((s) => s.arrivalOffset!).toList();
      expect(a.every((m) => m % 5 == 0), true);
      expect(a, orderedEquals([...a]..sort()));
      expect(a.first, greaterThan(0));
      expect(a.last + 5, lessThan(8 * 60));
      expect(j.scheduleConflicts(), isEmpty);
    });

    test('keeps manually chosen times and only estimates the others around them', () {
      final j = _journey(mid: [_stop('A'), _stop('B', manual: true, at: 120), _stop('C')]);
      j.autoSchedule();
      expect(j.stops[2].arrivalOffset, 120);
      expect(j.stops[1].arrivalOffset!, lessThan(120));
      expect(j.stops[3].arrivalOffset!, greaterThan(125));
    });

    test('does nothing until the departure and arrival are set', () {
      final j = JourneyDraft(sourceId: 'S', destId: 'D', stops: [_stop('S'), _stop('A'), _stop('D')]);
      j.autoSchedule();
      expect(j.stops[1].arrivalOffset, isNull);
    });
  });

  group('bounds and conflicts', () {
    test('a stop is limited by the previous departure and the next arrival', () {
      final j = _journey(mid: [_stop('A', manual: true, at: 60, dwell: 10), _stop('B', manual: true, at: 240), _stop('C', manual: true, at: 360)]);
      final b = j.arrivalBounds(2)!;
      expect(b.min, 70); // A leaves at 60 + 10
      expect(b.max, 360 - 5); // C arrives at 360, B stops 5 min
    });

    test('a stop outside the window or out of order is reported with its name', () {
      final j = _journey(mid: [_stop('A', manual: true, at: 200), _stop('B', manual: true, at: 100)]);
      final c = j.scheduleConflicts();
      expect(c.map((x) => x.index), containsAll([1, 2]));
      expect(c.firstWhere((x) => x.index == 2).message, contains('B'));
      final late = _journey(mid: [_stop('A', manual: true, at: 8 * 60 - 2)]);
      expect(late.scheduleConflicts().single.message, contains('after the destination'));
    });
  });

  group('window changes', () {
    test('moving the departure keeps manual stops at the same clock time and revalidates', () {
      final j = _journey(mid: [_stop('A', manual: true, at: 120)]); // 07:00
      j.setStart(5 * 60 + 30); // 05:30, destination stays 13:00
      expect(j.durationMin, 450);
      expect(j.stops[1].arrivalOffset, 90); // still 07:00
      expect(j.scheduleConflicts(), isEmpty);
      j.setStart(8 * 60); // 08:00: the 07:00 stop is now before the start
      expect(j.scheduleConflicts().single.message, contains('before the journey starts'));
    });

    test('estimates follow a changed arrival time', () {
      final j = _journey(mid: [_stop('A')]);
      j.autoSchedule();
      final before = j.stops[1].arrivalOffset!;
      j.setEnd(9 * 60); // shorter journey
      expect(j.durationMin, 240);
      expect(j.stops[1].arrivalOffset!, lessThan(before));
    });
  });

  group('overnight journeys', () {
    test('22:00 -> 02:00 with a stop at 23:30 stays chronological', () {
      final j = _journey(start: 22 * 60, duration: 240, mid: [_stop('A', manual: true, at: 90)]);
      expect(j.endMin, 2 * 60);
      expect(j.timeLabel(90), '23:30');
      expect(j.timeLabel(240), '02:00 (+1 day)');
      expect(j.scheduleConflicts(), isEmpty);
      final p = journeyToPayload(j);
      expect((p['stops'] as List).map((s) => s['arrival_offset_min']), [0, 90, 240]);
    });

    test('setting the arrival clock after midnight makes the journey run into the next day', () {
      final j = _journey(start: 22 * 60, duration: 60);
      j.setEnd(2 * 60);
      expect(j.durationMin, 240);
    });
  });

  group('validateJourney', () {
    test('a complete scheduled journey is valid', () {
      final j = _journey(mid: [_stop('A')])..autoSchedule();
      expect(validateJourney(j), isEmpty);
    });

    test('requires departure and arrival times', () {
      final j = JourneyDraft(sourceId: 'S', destId: 'D', stops: [_stop('S'), _stop('D')]);
      expect(validateJourney(j), containsAll(['Set the departure time at the starting point', 'Set the arrival time at the destination']));
    });
  });
}
