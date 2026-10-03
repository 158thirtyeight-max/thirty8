import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

enum ManifestFilter { all, yetToBoard, boarded, cancelled, exceptions }

extension ManifestFilterX on ManifestFilter {
  String get label => switch (this) {
        ManifestFilter.all => 'All passengers',
        ManifestFilter.yetToBoard => 'Yet to board',
        ManifestFilter.boarded => 'Boarded',
        ManifestFilter.cancelled => 'Cancelled',
        ManifestFilter.exceptions => 'Exceptions',
      };

  /// Value understood by `get_trip_manifest`.
  String get wire => switch (this) {
        ManifestFilter.all => 'all',
        ManifestFilter.yetToBoard => 'yet_to_board',
        ManifestFilter.boarded => 'boarded',
        ManifestFilter.cancelled => 'cancelled',
        ManifestFilter.exceptions => 'exceptions',
      };
}

/// not_boarded → verified → boarded, plus exception.
enum BoardingStatus { notBoarded, verified, boarded, exception }

extension BoardingStatusX on BoardingStatus {
  static BoardingStatus parse(String? v) => switch (v) {
        'verified' => BoardingStatus.verified,
        'boarded' => BoardingStatus.boarded,
        'exception' => BoardingStatus.exception,
        _ => BoardingStatus.notBoarded,
      };

  String get label => switch (this) {
        BoardingStatus.notBoarded => 'Not boarded',
        BoardingStatus.verified => 'Boarding verified',
        BoardingStatus.boarded => 'Boarded',
        BoardingStatus.exception => 'Boarding exception',
      };

  /// Key understood by AppBadge.
  String get badge => switch (this) {
        BoardingStatus.notBoarded => 'pending',
        BoardingStatus.verified => 'verified',
        BoardingStatus.boarded => 'confirmed',
        BoardingStatus.exception => 'failed',
      };
}

/// One passenger on the manifest. The document number is ALWAYS masked here; the full number
/// only exists behind the audited reveal action and is never stored in this model.
@immutable
class ManifestPassenger {
  const ManifestPassenger({
    required this.bookingItemId,
    required this.bookingReference,
    required this.seatCode,
    required this.name,
    required this.phone,
    required this.boardingPoint,
    required this.droppingPoint,
    required this.bookingStatus,
    required this.paymentStatus,
    required this.boarding,
    this.refundStatus,
    this.docLabel,
    this.docMasked,
    this.docVerification,
    this.exceptionReason,
  });

  final String bookingItemId;
  final String bookingReference;
  final String seatCode;
  final String name;
  final String? phone;
  final String boardingPoint;
  final String droppingPoint;
  final String bookingStatus;
  final String paymentStatus;
  final String? refundStatus;
  final String? docLabel;
  final String? docMasked;
  final String? docVerification;
  final BoardingStatus boarding;
  final String? exceptionReason;

  bool get hasDocument => docMasked != null;
  bool get isConfirmed => bookingStatus == 'confirmed' || bookingStatus == 'completed';
  bool get isPaid => paymentStatus == 'captured';

  /// "Aadhaar: XXXX-XXXX-1234", or null when no document was provided.
  String? get documentLine => hasDocument ? '$docLabel: $docMasked' : null;

  bool get canVerify => isConfirmed && isPaid && boarding != BoardingStatus.boarded;
  bool get canConfirmBoarding => boarding == BoardingStatus.verified;
  bool get canReportException => isConfirmed && boarding != BoardingStatus.boarded;
  bool get hasPaymentException => !isPaid || refundStatus == 'pending';

  factory ManifestPassenger.fromJson(Map<String, dynamic> j) => ManifestPassenger(
        bookingItemId: j['booking_item_id'] as String,
        bookingReference: (j['booking_reference'] as String?) ?? '',
        seatCode: (j['seat_code'] as String?) ?? '',
        name: (j['passenger_name'] as String?) ?? 'Unnamed passenger',
        phone: j['passenger_phone'] as String?,
        boardingPoint: (j['boarding_point'] as String?) ?? '—',
        droppingPoint: (j['dropping_point'] as String?) ?? '—',
        bookingStatus: (j['booking_status'] as String?) ?? '',
        paymentStatus: (j['payment_status'] as String?) ?? 'pending',
        refundStatus: j['refund_status'] as String?,
        docLabel: j['doc_label'] as String?,
        docMasked: j['doc_masked'] as String?,
        docVerification: j['doc_verification'] as String?,
        boarding: BoardingStatusX.parse(j['boarding_status'] as String?),
        exceptionReason: j['exception_reason'] as String?,
      );
}

@immutable
class ManifestQuery {
  const ManifestQuery(this.tripId, this.filter, [this.search = '']);

  final String tripId;
  final ManifestFilter filter;
  final String search;

  @override
  bool operator ==(Object other) =>
      other is ManifestQuery && other.tripId == tripId && other.filter == filter && other.search == search;

  @override
  int get hashCode => Object.hash(tripId, filter, search);
}

/// A manifest read: the passengers plus whether booking has closed (which unlocks the PDF export).
@immutable
class ManifestResult {
  const ManifestResult({required this.passengers, required this.bookingClosed, this.bookingCloseAt, this.departureAt});

  final List<ManifestPassenger> passengers;

  /// True once the trip is no longer open for sale (cut-off passed, boarding/departed, cancelled).
  final bool bookingClosed;
  final DateTime? bookingCloseAt;
  final DateTime? departureAt;

  factory ManifestResult.fromJson(Map<String, dynamic> j) => ManifestResult(
        passengers: [for (final p in (j['passengers'] as List? ?? const [])) ManifestPassenger.fromJson(Map<String, dynamic>.from(p as Map))],
        bookingClosed: j['booking_closed'] == true,
        bookingCloseAt: j['booking_close_at'] == null ? null : DateTime.parse(j['booking_close_at'] as String).toLocal(),
        departureAt: j['departure_at'] == null ? null : DateTime.parse(j['departure_at'] as String).toLocal(),
      );
}

final tripManifestProvider = FutureProvider.autoDispose.family<ManifestResult, ManifestQuery>((ref, q) async {
  final res = await ref.watch(supabaseProvider).rpc('get_trip_manifest', params: {
    'p_trip_id': q.tripId,
    'p_filter': q.filter.wire,
    'p_search': q.search.trim().isEmpty ? null : q.search.trim(),
  });
  return ManifestResult.fromJson(Map<String, dynamic>.from(res as Map));
});

/// Result of a boarding RPC: `{ok, status}` or `{ok:false, code, message}`.
@immutable
class BoardingResult {
  const BoardingResult({required this.ok, this.status, this.code, this.message});

  final bool ok;
  final String? status;
  final String? code;
  final String? message;

  factory BoardingResult.fromJson(Map<String, dynamic> j) => BoardingResult(
        ok: j['ok'] == true,
        status: j['status'] as String?,
        code: j['code'] as String?,
        message: j['message'] as String?,
      );
}

/// Operator-friendly text for errors raised by the boarding / reveal RPCs.
String boardingErrorMessage(Object e) {
  final t = e.toString();
  if (t.contains('service_inactive')) return 'The Bus service is not active, so boarding actions are disabled.';
  if (t.contains('trip_not_boardable')) return 'This trip is not open for boarding.';
  if (t.contains('Only the operator admin')) return 'Only the account owner can do this.';
  if (t.contains('reason')) return 'Please give a reason.';
  if (t.contains('No document on file')) return 'No identity document was provided for this passenger.';
  if (t.contains('booking_not_closed')) return 'The passenger list can be downloaded once booking has closed for this trip.';
  if (t.contains('Not authorized')) return 'You are not allowed to do this for this trip.';
  return 'Something went wrong. Please try again.';
}
