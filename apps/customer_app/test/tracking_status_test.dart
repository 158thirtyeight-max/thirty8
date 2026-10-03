import 'package:customer_app/features/bookings/tracking_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps every backend status', () {
    expect(VehicleLocationStatusX.parse('live_tracker'), VehicleLocationStatus.liveTracker);
    expect(VehicleLocationStatusX.parse('live_verified_fallback'), VehicleLocationStatus.liveFallback);
    expect(VehicleLocationStatusX.parse('estimated_passenger'), VehicleLocationStatus.estimatedPassenger);
    expect(VehicleLocationStatusX.parse('stale'), VehicleLocationStatus.stale);
    expect(VehicleLocationStatusX.parse('offline'), VehicleLocationStatus.offline);
    expect(VehicleLocationStatusX.parse('not_started'), VehicleLocationStatus.notStarted);
    expect(VehicleLocationStatusX.parse('???'), VehicleLocationStatus.notConfigured);
  });

  test('only a tracker or verified fallback is live; an estimate is never live and says it is an estimate', () {
    for (final s in VehicleLocationStatus.values) {
      expect(s.isLive, s == VehicleLocationStatus.liveTracker || s == VehicleLocationStatus.liveFallback);
    }
    expect(VehicleLocationStatus.estimatedPassenger.isLive, isFalse);
    expect(VehicleLocationStatus.estimatedPassenger.title.toLowerCase(), contains('estimate'));
    expect(VehicleLocationStatus.estimatedPassenger.explanation.toLowerCase(), contains('may not be exact'));
  });

  test('stale and offline never claim the bus is there now', () {
    expect(VehicleLocationStatus.stale.title, 'Last known location');
    expect(VehicleLocationStatus.stale.explanation, contains('not where it is now'));
    expect(VehicleLocationStatus.offline.title, 'Location unavailable');
  });

  test('no marker before tracking starts or when it is not configured', () {
    expect(VehicleLocation.fromJson({'status': 'not_configured', 'latitude': 1.0, 'longitude': 2.0}).hasPoint, isFalse);
    expect(VehicleLocation.fromJson({'status': 'not_started'}).hasPoint, isFalse);
    expect(VehicleLocation.fromJson({'status': 'live_tracker', 'latitude': 11.7, 'longitude': 92.8, 'recorded_at': '2026-10-03T10:00:00Z'}).hasPoint, isTrue);
    expect(VehicleLocation.fromJson({'status': 'stale', 'latitude': null, 'longitude': null}).hasPoint, isFalse);
  });
}
