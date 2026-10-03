import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

/// Trip list buckets, matching `list_operator_trips` on the server.
enum TripBucket { upcoming, active, completed, cancelled }

extension TripBucketX on TripBucket {
  String get label => switch (this) {
        TripBucket.upcoming => 'Upcoming',
        TripBucket.active => 'Active',
        TripBucket.completed => 'Completed',
        TripBucket.cancelled => 'Cancelled',
      };

  String get emptyMessage => switch (this) {
        TripBucket.upcoming => 'No upcoming trips. Tap "Schedule Trip" to add some.',
        TripBucket.active => 'No trips are running right now.',
        TripBucket.completed => 'No completed trips yet.',
        TripBucket.cancelled => 'No cancelled trips.',
      };

  /// Which bucket a trip status belongs to (mirror of the SQL rules).
  static TripBucket forStatus(String status) => switch (status) {
        'boarding' || 'departed' => TripBucket.active,
        'arrived' => TripBucket.completed,
        'cancelled' => TripBucket.cancelled,
        _ => TripBucket.upcoming,
      };
}

/// One row of the operator trip list. Seat figures come from the seat inventory
/// (`trip_seats`), so a booking with several seats counts every seat.
@immutable
class OperatorTrip {
  const OperatorTrip({
    required this.id,
    required this.busId,
    required this.busRegistration,
    required this.sourceName,
    required this.destinationName,
    required this.departureAt,
    required this.arrivalAt,
    required this.status,
    required this.totalSeats,
    required this.soldSeats,
    required this.heldSeats,
    required this.blockedSeats,
    this.busName,
  });

  final String id;
  final String busId;
  final String busRegistration;
  final String? busName;
  final String sourceName;
  final String destinationName;
  final DateTime departureAt;
  final DateTime? arrivalAt;
  final String status;
  final int totalSeats;
  final int soldSeats;
  final int heldSeats;
  final int blockedSeats;

  String get routeLabel => '$sourceName → $destinationName';
  int get availableSeats => (totalSeats - soldSeats - heldSeats - blockedSeats).clamp(0, totalSeats);
  TripBucket get bucket => TripBucketX.forStatus(status);

  /// Share of seats sold (0..1); 0 for a bus with no seats.
  double get soldFraction => totalSeats == 0 ? 0 : (soldSeats / totalSeats).clamp(0, 1).toDouble();

  factory OperatorTrip.fromJson(Map<String, dynamic> j) => OperatorTrip(
        id: j['id'] as String,
        busId: j['bus_id'] as String,
        busRegistration: (j['bus_registration'] as String?) ?? '',
        busName: j['bus_name'] as String?,
        sourceName: (j['source_name'] as String?) ?? '—',
        destinationName: (j['destination_name'] as String?) ?? '—',
        departureAt: DateTime.parse(j['departure_at'] as String).toLocal(),
        arrivalAt: j['arrival_at'] == null ? null : DateTime.parse(j['arrival_at'] as String).toLocal(),
        status: j['status'] as String,
        totalSeats: (j['total_seats'] as num?)?.toInt() ?? 0,
        soldSeats: (j['sold_seats'] as num?)?.toInt() ?? 0,
        heldSeats: (j['held_seats'] as num?)?.toInt() ?? 0,
        blockedSeats: (j['blocked_seats'] as num?)?.toInt() ?? 0,
      );
}

class TripListResult {
  const TripListResult({required this.counts, required this.items});

  final Map<TripBucket, int> counts;
  final List<OperatorTrip> items;

  factory TripListResult.fromJson(Map<String, dynamic> j) {
    final c = (j['counts'] as Map?) ?? const {};
    return TripListResult(
      counts: {for (final b in TripBucket.values) b: (c[b.name] as num?)?.toInt() ?? 0},
      items: [for (final i in (j['items'] as List? ?? const [])) OperatorTrip.fromJson(Map<String, dynamic>.from(i as Map))],
    );
  }
}

@immutable
class TripQuery {
  const TripQuery(this.operatorId, this.bucket, [this.busId]);

  final String operatorId;
  final TripBucket bucket;
  final String? busId;

  @override
  bool operator ==(Object other) =>
      other is TripQuery && other.operatorId == operatorId && other.bucket == bucket && other.busId == busId;

  @override
  int get hashCode => Object.hash(operatorId, bucket, busId);
}

final operatorTripsProvider = FutureProvider.autoDispose.family<TripListResult, TripQuery>((ref, q) async {
  final res = await ref.watch(supabaseProvider).rpc('list_operator_trips', params: {
    'p_operator_id': q.operatorId,
    'p_bucket': q.bucket.name,
    'p_bus_id': q.busId,
  });
  return TripListResult.fromJson(Map<String, dynamic>.from(res as Map));
});
