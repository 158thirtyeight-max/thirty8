import 'package:flutter_test/flutter_test.dart';
import 'package:seat_map/seat_map.dart';

MapSeat seat(String id, SeatStatus st, {int rev = 1, int row = 1, int col = 1, int deck = 1, String? ref}) => MapSeat(
      seatId: id,
      code: id.toUpperCase(),
      deck: deck,
      row: row,
      col: col,
      status: st,
      rev: rev,
      bookingReference: ref,
    );

SeatMapSnapshot snap(List<MapSeat> seats) => SeatMapSnapshot(
      tripId: 't1',
      layout: const SeatLayoutConfig(rows: 2, cols: 3, decks: 1, aisleCols: {2}),
      seats: seats,
      asOf: DateTime(2026, 10, 3),
    );

void main() {
  group('SeatCounts', () {
    test('counts every seat by state, occupancy from sold seats only', () {
      final c = SeatCounts.fromSeats([
        seat('a', SeatStatus.booked),
        seat('b', SeatStatus.boarded),
        seat('c', SeatStatus.held),
        seat('d', SeatStatus.blocked),
        seat('e', SeatStatus.available),
        seat('f', SeatStatus.available),
        seat('g', SeatStatus.cancelled),
        seat('h', SeatStatus.available),
      ]);
      expect(c.total, 8);
      expect(c.sold, 2);
      expect(c.held, 1);
      expect(c.blocked, 1);
      expect(c.available, 3);
      expect(c.occupancyPct, 25.0);
    });

    test('one booking with several seats counts every seat (not one ticket)', () {
      // three seats of the same booking
      final seats = [
        seat('a', SeatStatus.booked, ref: 'BK1'),
        seat('b', SeatStatus.booked, ref: 'BK1'),
        seat('c', SeatStatus.booked, ref: 'BK1'),
        seat('d', SeatStatus.available),
      ];
      expect(SeatCounts.fromSeats(seats).sold, 3);
      expect(SeatCounts.fromSeats(seats).occupancyPct, 75.0);
    });

    test('pending (held) is not confirmed, so it does not raise occupancy', () {
      final c = SeatCounts.fromSeats([seat('a', SeatStatus.held), seat('b', SeatStatus.available)]);
      expect(c.sold, 0);
      expect(c.occupancyPct, 0);
    });

    test('empty bus has 0% and does not divide by zero', () {
      expect(SeatCounts.fromSeats(const []).occupancyPct, 0);
    });

    test('a cancelled seat is released history, not capacity used', () {
      final c = SeatCounts.fromSeats([seat('a', SeatStatus.cancelled), seat('b', SeatStatus.booked)]);
      expect(c.sold, 1);
      expect(c.total, 2);
    });
  });

  group('SeatStatus.parse', () {
    test('unknown backend values are never treated as available', () {
      expect(SeatStatusX.parse('available'), SeatStatus.available);
      expect(SeatStatusX.parse('weird'), SeatStatus.blocked);
      expect(SeatStatusX.parse(null), SeatStatus.blocked);
    });
  });

  group('layout / seat parsing', () {
    test('reads rows, cols, decks and aisle columns from layout_json', () {
      final l = SeatLayoutConfig.fromJson({'rows': 10, 'cols': 5, 'decks': 2, 'aisle_cols': [3]});
      expect(l.rows, 10);
      expect(l.cols, 5);
      expect(l.decks, 2);
      expect(l.aisleCols, {3});
    });

    test('snapshot parses seats with their real codes and positions', () {
      final s = SeatMapSnapshot.fromJson({
        'trip_id': 't1',
        'layout': {'rows': 2, 'cols': 3, 'decks': 1, 'aisle_cols': [2]},
        'as_of': '2026-10-03T10:00:00Z',
        'seats': [
          {'seat_id': 's1', 'seat_code': '1A', 'row_no': 1, 'col_no': 1, 'deck': 1, 'status': 'available', 'rev': 3},
          {'seat_id': 's2', 'seat_code': '1B', 'row_no': 1, 'col_no': 3, 'deck': 1, 'status': 'booked', 'rev': 5, 'booking_reference': 'TH-1', 'booking_status': 'confirmed'},
        ],
      });
      expect(s.seats.map((e) => e.code), ['1A', '1B']);
      expect(s.seats[1].col, 3);
      expect(s.seats[1].bookingReference, 'TH-1');
      expect(s.counts.sold, 1);
    });
  });

  group('applyDeltas (stale updates never win)', () {
    test('newer revision is applied', () {
      final r = snap([seat('a', SeatStatus.available, rev: 1)]).applyDeltas([const SeatDelta(seatId: 'a', status: SeatStatus.held, rev: 2)]);
      expect(r.changed, isTrue);
      expect(r.snapshot.seats.single.status, SeatStatus.held);
      expect(r.snapshot.seats.single.rev, 2);
    });

    test('older or equal revision is ignored (late message cannot overwrite newer state)', () {
      final base = snap([seat('a', SeatStatus.booked, rev: 7)]);
      final older = base.applyDeltas([const SeatDelta(seatId: 'a', status: SeatStatus.held, rev: 6)]);
      expect(older.changed, isFalse);
      expect(older.snapshot.seats.single.status, SeatStatus.booked);
      final equal = base.applyDeltas([const SeatDelta(seatId: 'a', status: SeatStatus.available, rev: 7)]);
      expect(equal.changed, isFalse);
    });

    test('duplicate delivery is idempotent', () {
      const d = SeatDelta(seatId: 'a', status: SeatStatus.held, rev: 2);
      final once = snap([seat('a', SeatStatus.available, rev: 1)]).applyDeltas([d]);
      final twice = once.snapshot.applyDeltas([d]);
      expect(twice.changed, isFalse);
      expect(twice.snapshot.seats.single.status, SeatStatus.held);
    });

    test('a delta for an unknown seat asks for a refetch', () {
      final r = snap([seat('a', SeatStatus.available)]).applyDeltas([const SeatDelta(seatId: 'zzz', status: SeatStatus.held, rev: 9)]);
      expect(r.unknownSeat, isTrue);
      expect(r.changed, isFalse);
    });

    test('out-of-order batch applies each seat independently', () {
      final r = snap([seat('a', SeatStatus.available, rev: 1), seat('b', SeatStatus.available, rev: 4)]).applyDeltas([
        const SeatDelta(seatId: 'b', status: SeatStatus.held, rev: 3), // stale
        const SeatDelta(seatId: 'a', status: SeatStatus.booked, rev: 2), // fresh
      ]);
      expect(r.snapshot.seats.firstWhere((s) => s.seatId == 'a').status, SeatStatus.booked);
      expect(r.snapshot.seats.firstWhere((s) => s.seatId == 'b').status, SeatStatus.available);
    });

    test('payload parsing', () {
      final d = SeatDelta.parsePayload({
        'trip_id': 't1',
        'seats': [
          {'seat_id': 'a', 'status': 'held', 'rev': 5},
        ],
      });
      expect(d.single.status, SeatStatus.held);
      expect(d.single.rev, 5);
    });
  });

  group('mergeSnapshots', () {
    test('keeps the higher revision per seat when a slow fetch returns after a newer event', () {
      final current = snap([seat('a', SeatStatus.held, rev: 9)]);
      final staleFetch = snap([seat('a', SeatStatus.available, rev: 8, ref: null)]);
      final merged = mergeSnapshots(current, staleFetch);
      expect(merged.seats.single.status, SeatStatus.held);
      expect(merged.seats.single.rev, 9);
    });

    test('takes the fetched state when it is newer', () {
      final merged = mergeSnapshots(snap([seat('a', SeatStatus.held, rev: 2)]), snap([seat('a', SeatStatus.booked, rev: 3)]));
      expect(merged.seats.single.status, SeatStatus.booked);
    });

    test('first load and a different trip use the fetched snapshot as is', () {
      final fetched = snap([seat('a', SeatStatus.booked)]);
      expect(mergeSnapshots(null, fetched), same(fetched));
    });
  });
}
