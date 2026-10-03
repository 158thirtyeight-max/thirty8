import 'package:flutter/foundation.dart';

/// Seat states exposed by the backend (`trip_seats.status`, with expired holds
/// already reported as available). The client-side "selected" state is not here:
/// it is a UI overlay owned by the screen.
enum SeatStatus { available, held, booked, boarded, blocked, cancelled }

extension SeatStatusX on SeatStatus {
  static SeatStatus parse(String? v) => SeatStatus.values.firstWhere(
        (s) => s.name == v,
        orElse: () => SeatStatus.blocked, // unknown ⇒ never offer it for sale
      );

  String get label => switch (this) {
        SeatStatus.available => 'Available',
        SeatStatus.held => 'Held',
        SeatStatus.booked => 'Booked',
        SeatStatus.boarded => 'Boarded',
        SeatStatus.blocked => 'Blocked',
        SeatStatus.cancelled => 'Cancelled',
      };

  /// Counts toward occupancy.
  bool get isSold => this == SeatStatus.booked || this == SeatStatus.boarded;
}

/// Physical arrangement of a bus: `bus_layouts.layout_json`.
@immutable
class SeatLayoutConfig {
  const SeatLayoutConfig({required this.rows, required this.cols, required this.decks, required this.aisleCols});

  final int rows;
  final int cols;
  final int decks;

  /// 1-based column numbers that are walkways (no seats).
  final Set<int> aisleCols;

  factory SeatLayoutConfig.fromJson(Map<String, dynamic>? j) {
    final json = j ?? const <String, dynamic>{};
    return SeatLayoutConfig(
      rows: (json['rows'] as num?)?.toInt() ?? 0,
      cols: (json['cols'] as num?)?.toInt() ?? 0,
      decks: (json['decks'] as num?)?.toInt() ?? 1,
      aisleCols: {for (final c in (json['aisle_cols'] as List? ?? const [])) (c as num).toInt()},
    );
  }
}

@immutable
class MapSeat {
  const MapSeat({
    required this.seatId,
    required this.code,
    required this.deck,
    required this.row,
    required this.col,
    required this.status,
    required this.rev,
    this.tripSeatId,
    this.seatType = 'seater',
    this.berth,
    this.fareCents,
    this.bookingReference,
    this.bookingStatus,
  });

  /// `seats.id` — the id customers send to `create_seat_hold`.
  final String seatId;
  final String? tripSeatId;
  final String code;
  final int deck;
  final int row;
  final int col;
  final String seatType;
  final String? berth;
  final SeatStatus status;
  final int rev;
  final int? fareCents;

  /// Operator view only: the booking holding this seat (never passenger data).
  final String? bookingReference;
  final String? bookingStatus;

  bool get isSleeper => seatType == 'sleeper';

  MapSeat copyWith({SeatStatus? status, int? rev}) => MapSeat(
        seatId: seatId,
        tripSeatId: tripSeatId,
        code: code,
        deck: deck,
        row: row,
        col: col,
        seatType: seatType,
        berth: berth,
        status: status ?? this.status,
        rev: rev ?? this.rev,
        fareCents: fareCents,
        bookingReference: bookingReference,
        bookingStatus: bookingStatus,
      );

  factory MapSeat.fromJson(Map<String, dynamic> j) => MapSeat(
        seatId: j['seat_id'] as String,
        tripSeatId: j['trip_seat_id'] as String?,
        code: j['seat_code'] as String,
        deck: (j['deck'] as num?)?.toInt() ?? 1,
        row: (j['row_no'] as num).toInt(),
        col: (j['col_no'] as num).toInt(),
        seatType: (j['seat_type'] as String?) ?? 'seater',
        berth: j['berth'] as String?,
        status: SeatStatusX.parse(j['status'] as String?),
        rev: (j['rev'] as num?)?.toInt() ?? 0,
        fareCents: (j['fare_cents'] as num?)?.toInt(),
        bookingReference: j['booking_reference'] as String?,
        bookingStatus: j['booking_status'] as String?,
      );
}

/// Seat counts computed from the seat list itself (never from ticket counts, so a
/// booking with several seats counts every seat).
@immutable
class SeatCounts {
  const SeatCounts({
    required this.total,
    required this.booked,
    required this.boarded,
    required this.held,
    required this.blocked,
    required this.available,
  });

  final int total;
  final int booked;
  final int boarded;
  final int held;
  final int blocked;
  final int available;

  int get sold => booked + boarded;

  /// 0–100 with one decimal; 0 for a bus without seats.
  double get occupancyPct => total == 0 ? 0 : (sold * 1000 / total).round() / 10;

  factory SeatCounts.fromSeats(Iterable<MapSeat> seats) {
    var total = 0, booked = 0, boarded = 0, held = 0, blocked = 0, available = 0;
    for (final s in seats) {
      total++;
      switch (s.status) {
        case SeatStatus.booked:
          booked++;
        case SeatStatus.boarded:
          boarded++;
        case SeatStatus.held:
          held++;
        case SeatStatus.blocked:
          blocked++;
        case SeatStatus.available:
          available++;
        case SeatStatus.cancelled:
          break;
      }
    }
    return SeatCounts(total: total, booked: booked, boarded: boarded, held: held, blocked: blocked, available: available);
  }
}

/// One seat-change event from the backend (`trip:<id>:seats` broadcast).
@immutable
class SeatDelta {
  const SeatDelta({required this.seatId, required this.status, required this.rev});

  final String seatId;
  final SeatStatus status;
  final int rev;

  static List<SeatDelta> parsePayload(Map<String, dynamic> payload) => [
        for (final e in (payload['seats'] as List? ?? const []))
          SeatDelta(
            seatId: (e as Map)['seat_id'] as String,
            status: SeatStatusX.parse(e['status'] as String?),
            rev: (e['rev'] as num?)?.toInt() ?? 0,
          ),
      ];
}

@immutable
class SeatMapSnapshot {
  const SeatMapSnapshot({
    required this.tripId,
    required this.layout,
    required this.seats,
    required this.asOf,
    this.tripStatus,
    this.deckCount = 1,
  });

  final String tripId;
  final SeatLayoutConfig layout;
  final List<MapSeat> seats;
  final DateTime asOf;
  final String? tripStatus;
  final int deckCount;

  SeatCounts get counts => SeatCounts.fromSeats(seats);

  factory SeatMapSnapshot.fromJson(Map<String, dynamic> j) {
    final layoutJson = j['layout'] == null ? null : Map<String, dynamic>.from(j['layout'] as Map);
    final seats = [for (final s in (j['seats'] as List? ?? const [])) MapSeat.fromJson(Map<String, dynamic>.from(s as Map))];
    final layout = SeatLayoutConfig.fromJson(layoutJson);
    return SeatMapSnapshot(
      tripId: j['trip_id'] as String,
      layout: layout,
      seats: seats,
      asOf: DateTime.tryParse((j['as_of'] as String?) ?? '') ?? DateTime.now(),
      tripStatus: j['trip_status'] as String?,
      deckCount: (j['deck_count'] as num?)?.toInt() ?? layout.decks,
    );
  }

  /// Applies deltas that are NEWER than what we hold. Older or equal revisions are
  /// ignored, so a late message can never overwrite a newer state. [unknownSeat] is
  /// true when a delta names a seat we do not have (layout changed) → caller refetches.
  ({SeatMapSnapshot snapshot, bool changed, bool unknownSeat}) applyDeltas(List<SeatDelta> deltas) {
    final byId = {for (final s in seats) s.seatId: s};
    var changed = false;
    var unknown = false;
    for (final d in deltas) {
      final cur = byId[d.seatId];
      if (cur == null) {
        unknown = true;
        continue;
      }
      if (d.rev > cur.rev) {
        byId[d.seatId] = cur.copyWith(status: d.status, rev: d.rev);
        changed = true;
      }
    }
    if (!changed) return (snapshot: this, changed: false, unknownSeat: unknown);
    return (
      snapshot: SeatMapSnapshot(
        tripId: tripId,
        layout: layout,
        seats: [for (final s in seats) byId[s.seatId]!],
        asOf: asOf,
        tripStatus: tripStatus,
        deckCount: deckCount,
      ),
      changed: true,
      unknownSeat: unknown,
    );
  }
}
