import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:route_map/route_map.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

LiveFix fix(String status, {int? age, double? lat = 12.5, double? lng = 92.9, double? speed, double? heading, double? acc, DateTime? receivedAt}) =>
    LiveFix.fromJson({
      'status': status,
      'latitude': lat,
      'longitude': lng,
      'age_seconds': age,
      'speed_kmh': speed,
      'heading': heading,
      'accuracy_m': acc,
    }, receivedAt: receivedAt ?? DateTime(2026, 10, 8, 12));

void main() {
  final now = DateTime(2026, 10, 8, 12);

  group('polyline', () {
    test('decodes the reference polyline (precision 5 reference vector)', () {
      final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@', precision: 5);
      expect(pts.length, 3);
      expect(pts[0].lat, closeTo(38.5, 1e-9));
      expect(pts[0].lng, closeTo(-120.2, 1e-9));
      expect(pts[2].lat, closeTo(43.252, 1e-9));
      expect(pts[2].lng, closeTo(-126.453, 1e-9));
    });

    test('truncated input is rejected rather than guessed', () {
      expect(() => decodePolyline('_p~iF~ps|U_'), throwsFormatException);
    });
  });

  group('route progress', () {
    // 2 km due north in two legs.
    const line = [GeoPoint(12.0, 92.0), GeoPoint(12.01, 92.0), GeoPoint(12.02, 92.0)];

    test('midpoint is about half way and on route', () {
      final p = routeProgress(line, const GeoPoint(12.01, 92.0))!;
      expect(p.fraction, closeTo(0.5, 0.01));
      expect(p.offRouteM, lessThan(1));
    });

    test('a point far to the side is flagged as off route', () {
      final p = routeProgress(line, const GeoPoint(12.01, 92.05))!;
      expect(p.offRouteM, greaterThan(1000));
    });

    test('before the start / after the end clamps', () {
      expect(routeProgress(line, const GeoPoint(11.9, 92.0))!.fraction, 0);
      expect(routeProgress(line, const GeoPoint(12.5, 92.0))!.fraction, 1);
    });

    test('a single point is not a route', () {
      expect(routeProgress(const [GeoPoint(1, 1)], const GeoPoint(1, 1)), isNull);
    });
  });

  group('route map data', () {
    Map<String, dynamic> json({Map<String, dynamic>? geometry, String direction = 'outbound'}) => {
          'trip_id': 't1',
          'route_id': 'r1',
          'direction': direction,
          'trip_status': 'scheduled',
          'stops': [
            {'location_id': 'b', 'name': 'Rangat', 'latitude': 12.49, 'longitude': 92.92, 'order': 2, 'is_pickup': true, 'is_drop': true},
            {'location_id': 'a', 'name': 'Port Blair', 'latitude': 11.62, 'longitude': 92.72, 'order': 1, 'is_pickup': true, 'is_drop': false},
            {'location_id': 'c', 'name': 'No coords', 'latitude': null, 'longitude': null, 'order': 3, 'is_pickup': false, 'is_drop': true},
          ],
          'my_pickup_location_id': 'a',
          'geometry': geometry,
        };

    test('stops are sorted by travel order; stops without coordinates are not drawn', () {
      final d = RouteMapData.fromJson(json());
      expect(d.stops.map((s) => s.name), ['Port Blair', 'Rangat', 'No coords']);
      expect(d.drawableStops.length, 2);
      expect(d.title, 'Port Blair → No coords');
    });

    test('return direction is preserved', () {
      expect(RouteMapData.fromJson(json(direction: 'return')).direction, RouteDirection.returning);
      expect(RouteMapData.fromJson(json()).direction, RouteDirection.outbound);
    });

    test('no geometry: no road line is drawn, and a rebuild is wanted', () {
      final d = RouteMapData.fromJson(json());
      expect(d.roadLine, isNull);
      expect(d.needsGeometry, isTrue);
    });

    test('stale geometry is never drawn as the route', () {
      final d = RouteMapData.fromJson(json(geometry: {'polyline6': '_p~iF~ps|U_ulLnnqC', 'is_current': false}));
      expect(d.roadLine, isNull);
      expect(d.needsGeometry, isTrue);
    });

    test('current geometry is used', () {
      final d = RouteMapData.fromJson(json(geometry: {'polyline6': '_p~iF~ps|U_ulLnnqC', 'is_current': true}));
      expect(d.roadLine, isNotNull);
      expect(d.needsGeometry, isFalse);
    });

    test('a corrupt geometry degrades to no line instead of throwing', () {
      final d = RouteMapData.fromJson(json(geometry: {'polyline6': '_p~iF~ps|U_', 'is_current': true}));
      expect(d.roadLine, isNull);
    });
  });

  group('tracking presentation', () {
    test('a fresh live fix is Live with speed and age', () {
      final v = describeTracking(fix('live_tracker', age: 10, speed: 42.4), now);
      expect(v.kind, TrackingKind.live);
      expect(v.headline, 'Live');
      expect(v.detail, contains('42 km/h'));
      expect(v.showBus, isTrue);
    });

    test('Live decays with the clock even if the server said live', () {
      final received = DateTime(2026, 10, 8, 11, 55); // 5 minutes ago locally
      final v = describeTracking(fix('live_tracker', age: 10, receivedAt: received), now);
      expect(v.kind, TrackingKind.lastKnown);
      expect(v.headline, startsWith('Last updated'));
      expect(v.isLive, isFalse);
    });

    test('age uses the server clock, not the phone clock', () {
      // fix claims to be 10 min old on the server; local receive time is "now" => still 10 min old
      final v = describeTracking(fix('live_verified_fallback', age: 600), now);
      expect(v.kind, TrackingKind.lastKnown);
      expect(v.headline, 'Last updated 10 min ago');
    });

    test('very old position is temporarily unavailable, still shows last seen', () {
      final v = describeTracking(fix('offline', age: 3600), now);
      expect(v.kind, TrackingKind.offline);
      expect(v.headline, 'Live tracking temporarily unavailable');
      expect(v.showBus, isTrue);
    });

    test('stale server status is never live', () {
      expect(describeTracking(fix('stale', age: 200), now).isLive, isFalse);
    });

    test('estimate is labelled and approximate', () {
      final v = describeTracking(fix('estimated_passenger', age: 5), now);
      expect(v.kind, TrackingKind.estimated);
      expect(v.approximate, isTrue);
      expect(v.isLive, isFalse);
    });

    test('not started / not configured / ended', () {
      expect(describeTracking(fix('not_started', lat: null, lng: null), now).headline, 'Bus not started');
      expect(describeTracking(fix('not_configured', lat: null, lng: null), now).kind, TrackingKind.notAvailable);
      final ended = describeTracking(fix('ended', age: 30), now);
      expect(ended.headline, 'Trip completed');
      expect(ended.showBus, isTrue);
    });

    test('no position at all never draws a bus', () {
      final v = describeTracking(fix('live_tracker', age: 5, lat: null, lng: null), now);
      expect(v.showBus, isFalse);
      expect(v.isLive, isFalse);
    });

    test('poor accuracy is called approximate', () {
      final v = describeTracking(fix('live_tracker', age: 5, acc: 250), now);
      expect(v.approximate, isTrue);
      expect(v.detail, contains('±250 m'));
    });

    test('tracking read failure is unavailable, not live', () {
      final v = describeTracking(null, now);
      expect(v.kind, TrackingKind.unavailable);
      expect(v.showBus, isFalse);
    });

    test('heading outside 0..360 is dropped, never invented', () {
      expect(fix('live_tracker', age: 1, heading: 400).heading, isNull);
      expect(fix('live_tracker', age: 1, heading: -1).heading, isNull);
      expect(fix('live_tracker', age: 1).heading, isNull);
      expect(fix('live_tracker', age: 1, heading: 270).heading, 270);
    });
  });

  testWidgets('map load failure shows the fallback and does not throw', (tester) async {
    // An unreachable backend: every read fails.
    final client = (await tester.runAsync(() async => SupabaseClient('http://127.0.0.1:1', 'anon-key')))!;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TripMapCard(client: client, tripId: 't1'))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pump();
    expect(find.text('Map unavailable'), findsOneWidget);
    expect(find.textContaining('trip details are still available'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    // let the Realtime client's own deferred-disconnect timer fire
    await tester.pump(const Duration(seconds: 60));
  });
}
