import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/route_model.dart';

RouteStop s(String name, {bool b = false, bool d = false, int? arr, int? dep}) =>
    RouteStop(name: name, isBoarding: b, isDropping: d, arrivalMin: arr, departureMin: dep);

int hm(int h, int m) => h * 60 + m;

void main() {
  final good = [
    s('Vijayapuram Bus Stand', b: true, dep: hm(6, 0)),
    s('Bambooflat', b: true, d: true, arr: hm(7, 0), dep: hm(7, 5)),
    s('Rangat', b: true, d: true, arr: hm(9, 0), dep: hm(9, 10)),
    s('Mayabunder', b: true, d: true, arr: hm(11, 0), dep: hm(11, 5)),
    s('Diglipur', d: true, arr: hm(14, 0)),
  ];

  test('offsets are relative to origin departure; destination departs on arrival', () {
    final o = computeOffsets(good);
    expect(o[0], (arrival: 0, departure: 0));
    expect(o[1], (arrival: 60, departure: 65));
    expect(o[4], (arrival: 480, departure: 480));
    expect(journeyDurationMin(good), 480);
  });

  test('overnight journey unwraps past midnight', () {
    final stops = [
      s('A', b: true, dep: hm(22, 0)),
      s('B', b: true, d: true, arr: hm(23, 30), dep: hm(23, 40)),
      s('C', d: true, arr: hm(2, 15)),
    ];
    final o = computeOffsets(stops);
    expect(o[1].arrival, 90);
    expect(o[2].arrival, 4 * 60 + 15);
    expect(journeyDurationMin(stops), 255);
    expect(clockFromOffset(hm(22, 0), 255), hm(2, 15));
  });

  test('missing origin departure gives no offsets', () {
    final o = computeOffsets([s('A', b: true), s('B', d: true, arr: 60)]);
    expect(o.every((e) => e.arrival == null && e.departure == null), isTrue);
  });

  group('validation', () {
    List<String> run(List<RouteStop> stops, {String? src = 'a', String? dst = 'b', Set<int> days = const {1}}) =>
        validateRoute(sourceCityId: src, destinationCityId: dst, stops: stops, operatingDays: days);

    test('valid route', () => expect(run(good), isEmpty));

    test('cities and days', () {
      expect(run(good, src: null), isNotEmpty);
      expect(run(good, src: 'a', dst: 'a').single, 'Origin and destination must be different');
      expect(run(good, days: {}), contains('Select at least one operating day'));
    });

    test('needs origin boarding, destination dropping, 2+ stops', () {
      expect(run([s('A', b: true, dep: 0)]), contains('A route needs at least an origin and a destination stop'));
      final noBoard = [s('A', dep: 0), s('B', d: true, arr: 60)];
      expect(run(noBoard), contains('The origin must be a boarding point'));
      final noDrop = [s('A', b: true, dep: 0), s('B', arr: 60)];
      expect(run(noDrop), contains('The destination must be a dropping point'));
    });

    test('blank names and missing times', () {
      final stops = [s('A', b: true, dep: 0), s(' ', b: true, d: true, arr: 30), s('C', d: true)];
      final e = run(stops).join('|');
      expect(e, contains('1 stop(s) have no name'));
      expect(e, contains('departure time is missing'));
      expect(e, contains('C: arrival time is missing'));
    });

    test('a stop that departs before it arrives after unwrapping', () {
      // arrives 07:00, departs 06:30 -> unwrapped to next day is > 24h, allowed only if monotonic;
      // here dep < arr on the same day wraps forward, so build an explicit bad case via offsets.
      final stops = [
        s('A', b: true, dep: hm(6, 0)),
        s('B', b: true, d: true, arr: hm(7, 0), dep: hm(7, 0)),
        s('C', d: true, arr: hm(7, 0)),
      ];
      expect(run(stops), isEmpty); // equal times are allowed
    });

    test('a departure earlier than arrival is caught as an unrealistic wait', () {
      final stops = [
        s('A', b: true, dep: hm(6, 0)),
        s('B', b: true, d: true, arr: hm(7, 0), dep: hm(6, 30)),
        s('C', d: true, arr: hm(9, 0)),
      ];
      expect(run(stops).join(), contains('waits over 6 hours'));
    });

    test('duration must be positive', () {
      final stops = [s('A', b: true, dep: hm(6, 0)), s('B', d: true, arr: hm(6, 0))];
      expect(run(stops), contains('Estimated journey duration must be greater than zero'));
    });
  });

  test('stopsToJson orders offsets and carries point ids', () {
    final stops = [
      s('A', b: true, dep: hm(6, 0))..boardingPointId = 'bp1',
      s('B', d: true, arr: hm(8, 0))..droppingPointId = 'dp2',
    ];
    final j = stopsToJson(stops);
    expect(j[0]['boarding_point_id'], 'bp1');
    expect(j[1]['arrival_offset_min'], 120);
    expect(j[1]['departure_offset_min'], 120);
    expect(j[1]['dropping_point_id'], 'dp2');
  });

  test('stopsFromPoints merges boarding + dropping rows by sequence and ignores inactive', () {
    final stops = stopsFromPoints(
      departureMin: hm(6, 0),
      boarding: [
        {'id': 'b1', 'sequence_no': 1, 'name': 'Origin', 'arrival_offset_min': 0, 'departure_offset_min': 0, 'is_active': true},
        {'id': 'b2', 'sequence_no': 2, 'name': 'Mid', 'arrival_offset_min': 60, 'departure_offset_min': 65, 'is_active': true},
        {'id': 'bx', 'sequence_no': -1, 'name': 'Old', 'is_active': false},
      ],
      dropping: [
        {'id': 'd2', 'sequence_no': 2, 'name': 'Mid', 'arrival_offset_min': 60, 'departure_offset_min': 65, 'is_active': true},
        {'id': 'd3', 'sequence_no': 3, 'name': 'End', 'arrival_offset_min': 120, 'departure_offset_min': 120, 'is_active': true},
      ],
    );
    expect(stops.map((e) => e.name), ['Origin', 'Mid', 'End']);
    expect(stops[1].isBoarding && stops[1].isDropping, isTrue);
    expect(stops[1].boardingPointId, 'b2');
    expect(stops[1].droppingPointId, 'd2');
    expect(stops[0].departureMin, hm(6, 0));
    expect(stops[2].arrivalMin, hm(8, 0));
  });

  test('formatters', () {
    expect(formatClock(hm(6, 5)), '06:05');
    expect(formatClock(null), '--:--');
    expect(formatDuration(480), '8h');
    expect(formatDuration(495), '8h 15m');
    expect(formatDuration(45), '45m');
  });
}
