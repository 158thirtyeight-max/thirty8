import 'geo.dart';

/// Server status of the bus location (mirrors `get_trip_tracking`).
enum FixStatus { liveTracker, liveFallback, estimatedPassenger, stale, offline, notStarted, notConfigured, ended }

FixStatus parseFixStatus(String? v) => switch (v) {
      'live_tracker' => FixStatus.liveTracker,
      'live_verified_fallback' => FixStatus.liveFallback,
      'estimated_passenger' => FixStatus.estimatedPassenger,
      'stale' => FixStatus.stale,
      'offline' => FixStatus.offline,
      'not_started' => FixStatus.notStarted,
      'ended' => FixStatus.ended,
      _ => FixStatus.notConfigured,
    };

/// Latest bus position as received, with the age measured on the SERVER clock (so a wrong phone
/// clock cannot make an old fix look fresh) and carried forward by the local elapsed time.
class LiveFix {
  const LiveFix({
    required this.status,
    required this.receivedAt,
    this.point,
    this.recordedAt,
    this.serverAgeSeconds,
    this.speedKmh,
    this.heading,
    this.accuracyM,
    this.tripStatus,
  });

  final FixStatus status;
  final GeoPoint? point;
  final DateTime? recordedAt;
  final int? serverAgeSeconds;
  final double? speedKmh;

  /// Degrees clockwise from north; null when the source did not report one (never invented).
  final double? heading;
  final double? accuracyM;
  final String? tripStatus;

  /// Local time this fix was received; ages are measured from here.
  final DateTime receivedAt;

  Duration? ageAt(DateTime now) => serverAgeSeconds == null ? null : Duration(seconds: serverAgeSeconds!) + now.difference(receivedAt);

  /// Identity of the actual GPS reading (not of the server status), used to skip redundant redraws.
  String get fixKey => '${point?.lat},${point?.lng},${recordedAt?.millisecondsSinceEpoch},${status.name}';

  factory LiveFix.fromJson(Map<String, dynamic> j, {DateTime? receivedAt}) {
    final lat = (j['latitude'] as num?)?.toDouble(), lng = (j['longitude'] as num?)?.toDouble();
    final h = (j['heading'] as num?)?.toDouble();
    return LiveFix(
      status: parseFixStatus(j['status'] as String?),
      point: lat == null || lng == null ? null : GeoPoint(lat, lng),
      recordedAt: j['recorded_at'] == null ? null : DateTime.parse(j['recorded_at'] as String).toLocal(),
      serverAgeSeconds: (j['age_seconds'] as num?)?.toInt(),
      speedKmh: (j['speed_kmh'] as num?)?.toDouble(),
      heading: h != null && h >= 0 && h < 360 ? h : null,
      accuracyM: (j['accuracy_m'] as num?)?.toDouble(),
      tripStatus: j['trip_status'] as String?,
      receivedAt: receivedAt ?? DateTime.now(),
    );
  }
}
