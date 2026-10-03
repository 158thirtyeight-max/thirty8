import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/bus_ops/route_summary.dart';
import 'package:operator_app/features/fleet/route_model.dart';
import 'package:operator_app/features/fleet/stop_schedule.dart';

JourneyDraft _outbound() => JourneyDraft(
      sourceId: 'A',
      destId: 'C',
      startMin: 6 * 60,
      durationMin: 240,
      stops: [
        RouteStop(name: 'A', cityId: 'A', isBoarding: true),
        RouteStop(name: 'B', cityId: 'B', isBoarding: true, isDropping: true, arrivalOffset: 120, dwellMin: 5, manualTime: true),
        RouteStop(name: 'C', cityId: 'C', isDropping: true),
      ],
      days: {1, 2, 3},
    );

Map<String, dynamic> _row(String city, int seq, int arr, int dep, {bool b = true, bool d = true}) => {
      'sequence_no': seq,
      'city_id': city,
      'is_boarding': b,
      'is_dropping': d,
      'arrival_offset_min': arr,
      'departure_offset_min': dep,
      'location': {'name': city},
    };

void main() {
  group('journeyToPayload', () {
    test('stores offsets from the departure (departure = arrival + stop time) and sorted days', () {
      final p = journeyToPayload(_outbound());
      expect(p['departure_time'], '06:00:00');
      expect(p['duration_min'], 240);
      expect(p['operating_days'], [1, 2, 3]);
      final stops = p['stops'] as List;
      expect(stops.map((s) => s['arrival_offset_min']), [0, 120, 240]);
      expect(stops.map((s) => s['departure_offset_min']), [0, 125, 240]);
    });

    test('a draft stop without a location is left out, offsets stay relative to the start', () {
      final j = _outbound()..stops.insert(1, RouteStop(name: '', isBoarding: true, arrivalOffset: 60));
      final stops = journeyToPayload(j)['stops'] as List;
      expect(stops.length, 3);
      expect(stops[1]['arrival_offset_min'], 120);
    });
  });

  group('journeyFromRevision', () {
    test('turns stored offsets back into arrival offsets and stop times and pads missing ends', () {
      final j = journeyFromRevision({
        'source_city_id': 'A',
        'destination_city_id': 'C',
        'departure_time': '06:00:00',
        'est_duration_min': 240,
        'operating_days': [1, 5],
        'departure_day_offset': 1,
        'reverse_generated': true,
        'route_revision_stops': [
          _row('C', 3, 240, 240, b: false),
          _row('B', 2, 120, 130),
          _row('A', 1, 0, 0, d: false),
        ],
      });
      expect(j.stops.map((s) => s.name), ['A', 'B', 'C']);
      expect(j.startMin, 360);
      expect(j.durationMin, 240);
      expect(j.stops[1].arrivalOffset, 120);
      expect(j.stops[1].dwellMin, 10);
      expect(j.stops[1].manualTime, true);
      expect(j.days, {1, 5});
      expect(j.departureDayOffset, 1);
      expect(j.reverseGenerated, true);
      expect(j.validate(), isEmpty);
    });

    test('an empty draft journey is padded to a starting point and a destination', () {
      final j = journeyFromRevision({'source_city_id': 'A', 'destination_city_id': 'B', 'departure_time': null, 'route_revision_stops': []});
      expect(j.stops.length, 2);
      expect(j.stops.first.cityId, 'A');
      expect(j.stops.last.cityId, 'B');
    });

    test('a journey without a departure keeps its stops as automatic estimates', () {
      final j = journeyFromRevision({
        'source_city_id': 'A',
        'destination_city_id': 'C',
        'departure_time': null,
        'est_duration_min': 240,
        'route_revision_stops': [_row('A', 1, 0, 0, d: false), _row('B', 2, 115, 120), _row('C', 3, 240, 240, b: false)],
      });
      expect(j.startMin, isNull);
      expect(j.stops[1].manualTime, false);
      expect(j.validate(), contains('Set the departure time at the starting point'));
    });
  });

  group('reverseJourney (mirrors generate_reverse_route in SQL)', () {
    test('reverses stops, swaps pickup / drop, keeps stop times and does not copy clock times', () {
      final r = reverseJourney(_outbound());
      expect(r.sourceId, 'C');
      expect(r.destId, 'A');
      expect(r.stops.map((s) => s.cityId), ['C', 'B', 'A']);
      expect(r.reverseGenerated, true);
      expect(r.stops.first.isBoarding, true);
      expect(r.stops.last.isDropping, true);
      // B: outbound arrives +120 and stops 5 min -> return arrives +115 (mirrored), still stops 5 min
      expect(r.stops[1].arrivalOffset, 115);
      expect(r.stops[1].dwellMin, 5);
      expect(r.stops[1].manualTime, false);
      expect(r.durationMin, 240);
      expect(r.startMin, isNull, reason: 'the return has its own departure');
    });

    test('once the return window is set the stops are placed inside it and the journey validates', () {
      final r = reverseJourney(_outbound())
        ..startMin = 15 * 60 + 30
        ..autoSchedule();
      expect(r.stops[1].arrivalOffset, inInclusiveRange(1, 239));
      expect(r.validate(), isEmpty);
    });
  });

  group('buildRouteSummaries', () {
    final bus = {'id': 'b1', 'name': 'Express', 'registration_number': 'AN01', 'lifecycle_status': 'active', 'active_route_revision_id': 'r1'};
    Map<String, dynamic> route(String dir) => {
          'id': 'route-$dir',
          'bus_id': 'b1',
          'direction': dir,
          'active': true,
          'created_at': '2026-10-01T00:00:00Z',
          'source': {'name': 'Diglipur'},
          'destination': {'name': 'Sri Vijaya Puram'},
        };
    Map<String, dynamic> rev(String id, int no, String status, {String? reason}) => {
          'id': id,
          'bus_id': 'b1',
          'revision_no': no,
          'status': status,
          'name': 'Diglipur to Sri Vijaya Puram',
          'rejection_reason': reason,
          'reviewed_at': '2026-10-02T00:00:00Z',
          'route_revision_journeys': [
            {'direction': 'outbound', 'route_revision_stops': [{'count': 6}]},
          ],
        };

    test('an approved one-way route with no pending change', () {
      final s = buildRouteSummaries(buses: [bus], routes: [route('outbound')], revisions: [rev('r1', 1, 'approved')]).single;
      expect(s.approvalStatus, 'approved');
      expect(s.routeStatus, 'Live');
      expect(s.tripType, 'one_way');
      expect(s.intermediateStops, 4);
      expect(s.source, 'Diglipur');
    });

    test('a return route makes it a round trip', () {
      final s = buildRouteSummaries(buses: [bus], routes: [route('outbound'), route('return')], revisions: [rev('r1', 1, 'approved')]).single;
      expect(s.isRoundTrip, true);
    });

    test('a pending revision shows pending while the live route is unchanged', () {
      final s = buildRouteSummaries(buses: [bus], routes: [route('outbound')], revisions: [rev('r1', 1, 'approved'), rev('r2', 2, 'pending_approval')]).single;
      expect(s.approvalStatus, 'pending');
      expect(s.isPending, true);
      expect(s.activeRevisionId, 'r1');
      expect(s.openRevisionId, 'r2');
    });

    test('an unsubmitted draft is a draft', () {
      final s = buildRouteSummaries(buses: [bus], routes: [route('outbound')], revisions: [rev('r1', 1, 'approved'), rev('r2', 2, 'draft')]).single;
      expect(s.approvalStatus, 'draft');
      expect(s.hasDraft, true);
    });

    test('a rejection stays visible with its reason until a newer revision exists', () {
      final rejected = buildRouteSummaries(buses: [bus], routes: [route('outbound')], revisions: [rev('r1', 1, 'approved'), rev('r2', 2, 'rejected', reason: 'Times overlap')]).single;
      expect(rejected.approvalStatus, 'rejected');
      expect(rejected.rejectionReason, 'Times overlap');
      expect(rejected.rejectedRevisionId, 'r2');
      final resubmitted = buildRouteSummaries(
        buses: [bus],
        routes: [route('outbound')],
        revisions: [rev('r1', 1, 'approved'), rev('r2', 2, 'rejected', reason: 'x'), rev('r3', 3, 'draft')],
      ).single;
      expect(resubmitted.approvalStatus, 'draft');
      expect(resubmitted.rejectionReason, isNull);
    });

    test('a bus that is not active yet is "set up (not live yet)"; a bus with nothing configured is omitted', () {
      final setup = {...bus, 'lifecycle_status': 'draft', 'active_route_revision_id': null};
      expect(buildRouteSummaries(buses: [setup], routes: [route('outbound')], revisions: []).single.routeStatus, 'Set up (not live yet)');
      expect(buildRouteSummaries(buses: [setup], routes: [], revisions: []), isEmpty);
    });
  });
}
