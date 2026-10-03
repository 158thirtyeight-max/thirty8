import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

/// What the vehicle location is, as decided by the backend (`get_trip_tracking`).
/// An estimate is never `isLive`, and a stale/offline position is never shown as live.
enum TrackingStatus { liveTracker, liveFallback, estimatedPassenger, stale, offline, notStarted, notConfigured, ended }

extension TrackingStatusX on TrackingStatus {
  static TrackingStatus parse(String? v) => switch (v) {
        'live_tracker' => TrackingStatus.liveTracker,
        'live_verified_fallback' => TrackingStatus.liveFallback,
        'estimated_passenger' => TrackingStatus.estimatedPassenger,
        'stale' => TrackingStatus.stale,
        'offline' => TrackingStatus.offline,
        'not_started' => TrackingStatus.notStarted,
        'ended' => TrackingStatus.ended,
        _ => TrackingStatus.notConfigured,
      };

  String get label => switch (this) {
        TrackingStatus.liveTracker => 'Live — GPS Tracker',
        TrackingStatus.liveFallback => 'Live — Verified Fallback',
        TrackingStatus.estimatedPassenger => 'Estimated — Passenger Assisted',
        TrackingStatus.stale => 'Stale',
        TrackingStatus.offline => 'Offline',
        TrackingStatus.notStarted => 'Not Started',
        TrackingStatus.notConfigured => 'Not Configured',
        TrackingStatus.ended => 'Trip ended',
      };

  bool get isLive => this == TrackingStatus.liveTracker || this == TrackingStatus.liveFallback;
  bool get isEstimate => this == TrackingStatus.estimatedPassenger;

  /// Confirmed live (solid), estimated (outlined) and last-known (grey) are drawn differently.
  Color get color => switch (this) {
        TrackingStatus.liveTracker || TrackingStatus.liveFallback => const Color(0xFF10B981),
        TrackingStatus.estimatedPassenger => const Color(0xFF3B82F6),
        TrackingStatus.stale => const Color(0xFFF59E0B),
        TrackingStatus.offline || TrackingStatus.ended => const Color(0xFF9B96AC),
        TrackingStatus.notStarted || TrackingStatus.notConfigured => const Color(0xFF9B96AC),
      };

  /// Whether a map position should be drawn at all.
  bool get hasPosition => this != TrackingStatus.notStarted && this != TrackingStatus.notConfigured;
}

@immutable
class Milestone {
  const Milestone({required this.pointName, required this.pointType, required this.recordedAt});

  final String pointName;
  final String? pointType;
  final DateTime recordedAt;
}

@immutable
class TrackingInfo {
  const TrackingInfo({
    required this.status,
    required this.label,
    required this.tripStatus,
    required this.milestones,
    this.latitude,
    this.longitude,
    this.recordedAt,
    this.source,
    this.confidence,
    this.deviceConnection,
    this.deviceActivation,
    this.deviceLastCommunication,
  });

  final TrackingStatus status;
  final String label;
  final String tripStatus;
  final double? latitude;
  final double? longitude;
  final DateTime? recordedAt;
  final String? source;
  final double? confidence;
  final List<Milestone> milestones;
  final String? deviceConnection;
  final String? deviceActivation;
  final DateTime? deviceLastCommunication;

  bool get hasPosition => status.hasPosition && latitude != null && longitude != null;

  /// "Source: GPS tracker" etc. Estimated positions are named as estimates.
  String get sourceLabel => switch (source) {
        'tracker' => 'GPS tracker',
        'driver_device' => 'Driver phone (fallback)',
        'passenger_assisted' => 'Passenger-assisted estimate',
        _ => '—',
      };

  factory TrackingInfo.fromJson(Map<String, dynamic> j) {
    final dev = j['device'] is Map ? Map<String, dynamic>.from(j['device'] as Map) : null;
    return TrackingInfo(
      status: TrackingStatusX.parse(j['status'] as String?),
      label: (j['label'] as String?) ?? '',
      tripStatus: (j['trip_status'] as String?) ?? '',
      latitude: (j['latitude'] as num?)?.toDouble(),
      longitude: (j['longitude'] as num?)?.toDouble(),
      recordedAt: j['recorded_at'] == null ? null : DateTime.parse(j['recorded_at'] as String).toLocal(),
      source: j['source'] as String?,
      confidence: (j['confidence'] as num?)?.toDouble(),
      milestones: [
        for (final m in (j['milestones'] as List? ?? const []))
          Milestone(
            pointName: (m as Map)['point_name'] as String? ?? '',
            pointType: m['point_type'] as String?,
            recordedAt: DateTime.parse(m['recorded_at'] as String).toLocal(),
          ),
      ],
      deviceConnection: dev?['connection_status'] as String?,
      deviceActivation: dev?['activation_status'] as String?,
      deviceLastCommunication: dev?['last_communication_at'] == null ? null : DateTime.parse(dev!['last_communication_at'] as String).toLocal(),
    );
  }
}

/// "just now", "42 s ago", "5 min ago", "2 h ago".
String ageText(DateTime? at, DateTime now) {
  if (at == null) return '—';
  final s = now.difference(at).inSeconds;
  if (s < 10) return 'just now';
  if (s < 60) return '$s s ago';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 86400) return '${s ~/ 3600} h ago';
  return '${s ~/ 86400} d ago';
}

/// Explains what a status means to the operator (never implies a connected device when there is none).
String trackingExplanation(TrackingInfo t) => switch (t.status) {
      TrackingStatus.liveTracker => 'The bus GPS tracker is reporting normally.',
      TrackingStatus.liveFallback => 'The tracker is not reporting; the driver’s phone is providing the location (enabled by thirty8).',
      TrackingStatus.estimatedPassenger =>
        'Estimated from several passengers who chose to share their location. This is not a confirmed GPS position.',
      TrackingStatus.stale => 'No recent update. This is the last known position, not the bus’s current location.',
      TrackingStatus.offline => t.hasPosition
          ? 'The bus has been silent for a while. This is the last known position.'
          : 'Vehicle location unavailable.',
      TrackingStatus.notStarted => 'Tracking has not started for this trip yet.',
      TrackingStatus.notConfigured => 'No GPS tracker is active for this bus. Configure one in Manage Bus → GPS Tracking.',
      TrackingStatus.ended => 'This trip has ended.',
    };

final tripTrackingProvider = FutureProvider.autoDispose.family<TrackingInfo, String>((ref, tripId) async {
  final res = await ref.watch(supabaseProvider).rpc('get_trip_tracking', params: {'p_trip_id': tripId});
  return TrackingInfo.fromJson(Map<String, dynamic>.from(res as Map));
});

@immutable
class GpsDeviceInfo {
  const GpsDeviceInfo({
    required this.id,
    required this.deviceIdentifier,
    required this.activation,
    required this.connection,
    required this.providerConfigured,
    this.name,
    this.imei,
    this.serialNo,
    this.simRef,
    this.notes,
    this.lastCommunicationAt,
  });

  final String id;
  final String? name;
  final String deviceIdentifier;
  final String? imei;
  final String? serialNo;
  final String? simRef;
  final String? notes;
  final String activation;
  final String connection;
  final bool providerConfigured;
  final DateTime? lastCommunicationAt;

  bool get isActive => activation == 'active';

  factory GpsDeviceInfo.fromJson(Map<String, dynamic> j) => GpsDeviceInfo(
        id: j['id'] as String,
        name: j['name'] as String?,
        deviceIdentifier: j['device_identifier'] as String,
        imei: j['imei'] as String?,
        serialNo: j['serial_no'] as String?,
        simRef: j['sim_ref'] as String?,
        notes: j['notes'] as String?,
        activation: (j['activation_status'] as String?) ?? 'registered',
        connection: (j['connection_status'] as String?) ?? 'never_connected',
        providerConfigured: j['provider_configured'] == true,
        lastCommunicationAt: j['last_communication_at'] == null ? null : DateTime.parse(j['last_communication_at'] as String).toLocal(),
      );
}

@immutable
class BusGpsStatus {
  const BusGpsStatus({required this.configured, required this.statusLabel, required this.allowDriverFallback, this.device, this.lastLatitude, this.lastLongitude, this.lastRecordedAt});

  final bool configured;
  final String statusLabel;
  final bool allowDriverFallback;
  final GpsDeviceInfo? device;
  final double? lastLatitude;
  final double? lastLongitude;
  final DateTime? lastRecordedAt;

  factory BusGpsStatus.fromJson(Map<String, dynamic> j) {
    final loc = j['last_location'] is Map ? Map<String, dynamic>.from(j['last_location'] as Map) : null;
    return BusGpsStatus(
      configured: j['configured'] == true,
      statusLabel: (j['status_label'] as String?) ?? 'Not Configured',
      allowDriverFallback: j['allow_driver_fallback'] == true,
      device: j['device'] is Map ? GpsDeviceInfo.fromJson(Map<String, dynamic>.from(j['device'] as Map)) : null,
      lastLatitude: (loc?['latitude'] as num?)?.toDouble(),
      lastLongitude: (loc?['longitude'] as num?)?.toDouble(),
      lastRecordedAt: loc?['recorded_at'] == null ? null : DateTime.parse(loc!['recorded_at'] as String).toLocal(),
    );
  }
}

final busGpsStatusProvider = FutureProvider.autoDispose.family<BusGpsStatus, String>((ref, busId) async {
  final res = await ref.watch(supabaseProvider).rpc('get_bus_gps_status', params: {'p_bus_id': busId});
  return BusGpsStatus.fromJson(Map<String, dynamic>.from(res as Map));
});

String gpsErrorMessage(Object e) {
  final t = e.toString();
  if (t.contains('device_already_assigned')) return 'That tracker is already assigned to a bus, or this bus already has one.';
  if (t.contains('service_inactive')) return 'The Bus service is not active.';
  if (t.contains('Only the operator admin')) return 'Only the account owner can configure tracking.';
  if (t.contains('identifier is required')) return 'Enter the device identifier printed on the tracker.';
  if (t.contains('imei')) return 'The IMEI must be 15 digits.';
  return 'Could not save the tracker details. Please try again.';
}

String? validateImei(String? v) {
  final t = (v ?? '').trim();
  if (t.isEmpty) return null; // optional
  return RegExp(r'^[0-9]{15}$').hasMatch(t) ? null : 'The IMEI must be 15 digits';
}
