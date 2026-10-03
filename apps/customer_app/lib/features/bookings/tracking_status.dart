import 'package:flutter/material.dart';

/// What the customer is told about the bus location. Mirrors `get_trip_tracking`.
/// An estimate is never described as live, and stale/offline positions say so.
enum VehicleLocationStatus { liveTracker, liveFallback, estimatedPassenger, stale, offline, notStarted, notConfigured, ended }

extension VehicleLocationStatusX on VehicleLocationStatus {
  static VehicleLocationStatus parse(String? v) => switch (v) {
        'live_tracker' => VehicleLocationStatus.liveTracker,
        'live_verified_fallback' => VehicleLocationStatus.liveFallback,
        'estimated_passenger' => VehicleLocationStatus.estimatedPassenger,
        'stale' => VehicleLocationStatus.stale,
        'offline' => VehicleLocationStatus.offline,
        'not_started' => VehicleLocationStatus.notStarted,
        'ended' => VehicleLocationStatus.ended,
        _ => VehicleLocationStatus.notConfigured,
      };

  String get title => switch (this) {
        VehicleLocationStatus.liveTracker => 'Live — GPS tracker',
        VehicleLocationStatus.liveFallback => 'Live',
        VehicleLocationStatus.estimatedPassenger => 'Estimated location',
        VehicleLocationStatus.stale => 'Last known location',
        VehicleLocationStatus.offline => 'Location unavailable',
        VehicleLocationStatus.notStarted => 'Tracking has not started',
        VehicleLocationStatus.notConfigured => 'Live tracking is not available for this bus',
        VehicleLocationStatus.ended => 'Trip ended',
      };

  String get explanation => switch (this) {
        VehicleLocationStatus.liveTracker => 'The bus’s GPS tracker is reporting.',
        VehicleLocationStatus.liveFallback => 'The bus location is being reported from the driver’s device.',
        VehicleLocationStatus.estimatedPassenger =>
          'This is an estimate based on passengers who chose to share their location. It may not be exact.',
        VehicleLocationStatus.stale => 'No recent update — this is where the bus was last seen, not where it is now.',
        VehicleLocationStatus.offline => 'We cannot see the bus right now. This may be a network gap.',
        VehicleLocationStatus.notStarted => 'The location will appear once the trip is under way.',
        VehicleLocationStatus.notConfigured => 'You can still follow the stops below as the bus reaches them.',
        VehicleLocationStatus.ended => 'This trip has finished.',
      };

  bool get isLive => this == VehicleLocationStatus.liveTracker || this == VehicleLocationStatus.liveFallback;
  bool get isEstimate => this == VehicleLocationStatus.estimatedPassenger;
  bool get showsPosition => this != VehicleLocationStatus.notStarted && this != VehicleLocationStatus.notConfigured;

  Color get color => switch (this) {
        VehicleLocationStatus.liveTracker || VehicleLocationStatus.liveFallback => const Color(0xFF10B981),
        VehicleLocationStatus.estimatedPassenger => const Color(0xFF3B82F6),
        VehicleLocationStatus.stale => const Color(0xFFF59E0B),
        _ => const Color(0xFF9B96AC),
      };
}

class VehicleLocation {
  const VehicleLocation({required this.status, this.latitude, this.longitude, this.recordedAt});

  final VehicleLocationStatus status;
  final double? latitude;
  final double? longitude;
  final DateTime? recordedAt;

  bool get hasPoint => status.showsPosition && latitude != null && longitude != null;

  factory VehicleLocation.fromJson(Map<String, dynamic> j) => VehicleLocation(
        status: VehicleLocationStatusX.parse(j['status'] as String?),
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        recordedAt: j['recorded_at'] == null ? null : DateTime.parse(j['recorded_at'] as String).toLocal(),
      );
}
