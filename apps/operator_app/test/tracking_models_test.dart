import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/tracking/tracking_models.dart';

Map<String, dynamic> info({
  String status = 'live_tracker',
  String? source = 'tracker',
  num? lat = 11.7,
  num? lng = 92.8,
  String? at = '2026-10-03T10:00:00Z',
  num? confidence,
  Map<String, dynamic>? device,
}) =>
    {
      'status': status,
      'label': 'x',
      'trip_status': 'departed',
      'source': source,
      'latitude': lat,
      'longitude': lng,
      'recorded_at': at,
      'confidence': confidence,
      'milestones': [
        {'point_name': 'Middle', 'point_type': 'boarding', 'recorded_at': '2026-10-03T09:30:00Z'},
      ],
      'device': device,
    };

void main() {
  group('status vocabulary', () {
    test('maps every backend status to the label the product specifies', () {
      expect(TrackingStatusX.parse('live_tracker').label, 'Live — GPS Tracker');
      expect(TrackingStatusX.parse('live_verified_fallback').label, 'Live — Verified Fallback');
      expect(TrackingStatusX.parse('estimated_passenger').label, 'Estimated — Passenger Assisted');
      expect(TrackingStatusX.parse('stale').label, 'Stale');
      expect(TrackingStatusX.parse('offline').label, 'Offline');
      expect(TrackingStatusX.parse('not_started').label, 'Not Started');
      expect(TrackingStatusX.parse('not_configured').label, 'Not Configured');
    });

    test('unknown status is treated as not configured, never as live', () {
      expect(TrackingStatusX.parse('mystery'), TrackingStatus.notConfigured);
      expect(TrackingStatusX.parse(null).isLive, isFalse);
    });

    test('only the tracker and the verified fallback are live; an estimate never is', () {
      for (final s in TrackingStatus.values) {
        expect(s.isLive, s == TrackingStatus.liveTracker || s == TrackingStatus.liveFallback, reason: s.name);
      }
      expect(TrackingStatus.estimatedPassenger.isLive, isFalse);
      expect(TrackingStatus.estimatedPassenger.isEstimate, isTrue);
      expect(TrackingStatus.stale.isLive, isFalse);
      expect(TrackingStatus.offline.isLive, isFalse);
    });

    test('confirmed, estimated and last-known positions use different colours', () {
      final colors = {TrackingStatus.liveTracker.color, TrackingStatus.estimatedPassenger.color, TrackingStatus.stale.color, TrackingStatus.offline.color};
      expect(colors.length, 4);
      expect(TrackingStatus.liveTracker.color, const Color(0xFF10B981));
    });

    test('no position is drawn when tracking has not started or is not configured', () {
      expect(TrackingStatus.notConfigured.hasPosition, isFalse);
      expect(TrackingStatus.notStarted.hasPosition, isFalse);
      expect(TrackingStatus.stale.hasPosition, isTrue);
      expect(TrackingStatus.offline.hasPosition, isTrue, reason: 'last known position stays visible, labelled offline');
    });
  });

  group('TrackingInfo', () {
    test('parses a live tracker fix', () {
      final t = TrackingInfo.fromJson(info());
      expect(t.status, TrackingStatus.liveTracker);
      expect(t.hasPosition, isTrue);
      expect(t.sourceLabel, 'GPS tracker');
      expect(t.milestones.single.pointName, 'Middle');
    });

    test('estimate keeps its confidence and is named as an estimate', () {
      final t = TrackingInfo.fromJson(info(status: 'estimated_passenger', source: 'passenger_assisted', confidence: 0.5));
      expect(t.confidence, 0.5);
      expect(t.sourceLabel, 'Passenger-assisted estimate');
      expect(t.status.isLive, isFalse);
    });

    test('driver phone fallback is labelled as a fallback', () {
      expect(TrackingInfo.fromJson(info(status: 'live_verified_fallback', source: 'driver_device')).sourceLabel, 'Driver phone (fallback)');
    });

    test('no coordinates means no position even if the status says stale', () {
      expect(TrackingInfo.fromJson(info(status: 'stale', lat: null, lng: null)).hasPosition, isFalse);
    });

    test('unconfigured bus has no position and says so', () {
      final t = TrackingInfo.fromJson(info(status: 'not_configured', source: null, lat: null, lng: null, at: null));
      expect(t.hasPosition, isFalse);
      expect(trackingExplanation(t), contains('No GPS tracker is active'));
    });

    test('device summary is parsed for staff', () {
      final t = TrackingInfo.fromJson(info(device: {'connection_status': 'online', 'activation_status': 'active', 'last_communication_at': '2026-10-03T10:00:00Z'}));
      expect(t.deviceConnection, 'online');
      expect(t.deviceActivation, 'active');
      expect(t.deviceLastCommunication, isNotNull);
    });

    test('explanations never imply an estimate is confirmed', () {
      final e = trackingExplanation(TrackingInfo.fromJson(info(status: 'estimated_passenger', source: 'passenger_assisted')));
      expect(e.toLowerCase(), contains('not a confirmed'));
    });

    test('offline without a position reads as unavailable', () {
      final t = TrackingInfo.fromJson(info(status: 'offline', source: null, lat: null, lng: null, at: null));
      expect(trackingExplanation(t), 'Vehicle location unavailable.');
    });
  });

  group('ageText', () {
    final now = DateTime(2026, 10, 3, 12);

    test('buckets', () {
      expect(ageText(now.subtract(const Duration(seconds: 3)), now), 'just now');
      expect(ageText(now.subtract(const Duration(seconds: 42)), now), '42 s ago');
      expect(ageText(now.subtract(const Duration(minutes: 5)), now), '5 min ago');
      expect(ageText(now.subtract(const Duration(hours: 2)), now), '2 h ago');
      expect(ageText(now.subtract(const Duration(days: 3)), now), '3 d ago');
      expect(ageText(null, now), '—');
    });
  });

  group('GPS device status', () {
    test('unconfigured bus: Not Configured, no device', () {
      final s = BusGpsStatus.fromJson({'configured': false, 'status_label': 'Not Configured', 'allow_driver_fallback': false});
      expect(s.configured, isFalse);
      expect(s.device, isNull);
      expect(s.statusLabel, 'Not Configured');
    });

    test('registered device is not active and not connected', () {
      final s = BusGpsStatus.fromJson({
        'configured': true,
        'status_label': 'Awaiting activation by thirty8',
        'allow_driver_fallback': false,
        'device': {'id': 'd1', 'device_identifier': 'TRK-1', 'activation_status': 'registered', 'connection_status': 'never_connected', 'provider_configured': false},
        'last_location': null,
      });
      expect(s.device!.isActive, isFalse);
      expect(s.device!.providerConfigured, isFalse);
      expect(s.device!.connection, 'never_connected');
      expect(s.lastRecordedAt, isNull);
    });

    test('parses last location and communication', () {
      final s = BusGpsStatus.fromJson({
        'configured': true,
        'status_label': 'Connected',
        'allow_driver_fallback': true,
        'device': {'id': 'd1', 'device_identifier': 'TRK-1', 'activation_status': 'active', 'connection_status': 'online', 'provider_configured': true, 'last_communication_at': '2026-10-03T10:00:00Z'},
        'last_location': {'latitude': 11.7, 'longitude': 92.8, 'recorded_at': '2026-10-03T10:00:00Z'},
      });
      expect(s.device!.isActive, isTrue);
      expect(s.lastLatitude, 11.7);
      expect(s.allowDriverFallback, isTrue);
    });
  });

  test('IMEI validation: optional, but exactly 15 digits when given', () {
    expect(validateImei(''), isNull);
    expect(validateImei(null), isNull);
    expect(validateImei('356938035643809'), isNull);
    expect(validateImei('12345'), isNotNull);
    expect(validateImei('35693803564380A'), isNotNull);
  });

  test('error messages are operator friendly', () {
    expect(gpsErrorMessage(Exception('device_already_assigned: ...')), contains('already assigned'));
    expect(gpsErrorMessage(Exception('Only the operator admin can configure tracking')), contains('account owner'));
    expect(gpsErrorMessage(Exception('boom')), contains('Could not save'));
  });
}
