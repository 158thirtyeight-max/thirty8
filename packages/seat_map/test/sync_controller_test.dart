import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seat_map/seat_map.dart';

class FakeSource implements SeatEventSource {
  final deltaCtl = StreamController<List<SeatDelta>>.broadcast(sync: true);
  final connCtl = StreamController<SeatSyncStatus>.broadcast(sync: true);
  bool started = false;
  bool stopped = false;

  @override
  Stream<List<SeatDelta>> get deltas => deltaCtl.stream;
  @override
  Stream<SeatSyncStatus> get connection => connCtl.stream;
  @override
  Future<void> start() async => started = true;
  @override
  Future<void> stop() async => stopped = true;
}

MapSeat seat(String id, SeatStatus st, int rev) =>
    MapSeat(seatId: id, code: id, deck: 1, row: 1, col: 1, status: st, rev: rev);

SeatMapSnapshot snap(List<MapSeat> seats) => SeatMapSnapshot(
      tripId: 't1',
      layout: const SeatLayoutConfig(rows: 1, cols: 1, decks: 1, aisleCols: {}),
      seats: seats,
      asOf: DateTime(2026, 10, 3),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads, applies a newer delta immediately, then reconciles with a fetch', () {
    fakeAsync((async) {
      final src = FakeSource();
      var fetches = 0;
      var serverState = SeatStatus.available;
      var serverRev = 1;
      final c = SeatMapSyncController(
        source: src,
        fetch: () async {
          fetches++;
          return snap([seat('a', serverState, serverRev)]);
        },
      );
      c.start();
      async.flushMicrotasks();
      expect(fetches, 1);
      expect(c.snapshot!.seats.single.status, SeatStatus.available);

      // another customer holds the seat
      serverState = SeatStatus.held;
      serverRev = 2;
      src.deltaCtl.add([const SeatDelta(seatId: 'a', status: SeatStatus.held, rev: 2)]);
      expect(c.snapshot!.seats.single.status, SeatStatus.held, reason: 'delta applies without waiting for the fetch');

      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      expect(fetches, 2, reason: 'debounced reconciliation read');
      expect(c.snapshot!.seats.single.status, SeatStatus.held);
      c.dispose();
    });
  });

  test('a burst of events triggers a single reconciliation (debounce)', () {
    fakeAsync((async) {
      final src = FakeSource();
      var fetches = 0;
      final c = SeatMapSyncController(source: src, fetch: () async {
        fetches++;
        return snap([seat('a', SeatStatus.held, 5)]);
      });
      c.start();
      async.flushMicrotasks();
      for (var i = 2; i <= 5; i++) {
        src.deltaCtl.add([SeatDelta(seatId: 'a', status: SeatStatus.held, rev: i)]);
        async.elapse(const Duration(milliseconds: 100));
      }
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(fetches, 2); // initial + one reconcile
      c.dispose();
    });
  });

  test('an older response never overwrites a newer one (sequence numbers + rev merge)', () {
    fakeAsync((async) {
      final src = FakeSource();
      final slow = Completer<SeatMapSnapshot>();
      var call = 0;
      final c = SeatMapSyncController(source: src, fetch: () {
        call++;
        if (call == 1) return Future.value(snap([seat('a', SeatStatus.available, 1)]));
        if (call == 2) return slow.future; // slow, stale read
        return Future.value(snap([seat('a', SeatStatus.booked, 4)]));
      });
      c.start();
      async.flushMicrotasks();

      c.refresh(); // call 2 (slow)
      c.refresh(); // call 3 (fast, newest state)
      async.flushMicrotasks();
      expect(c.snapshot!.seats.single.status, SeatStatus.booked);

      slow.complete(snap([seat('a', SeatStatus.held, 2)])); // the old read finally returns
      async.flushMicrotasks();
      expect(c.snapshot!.seats.single.status, SeatStatus.booked, reason: 'stale response discarded');
      expect(c.snapshot!.seats.single.rev, 4);
      c.dispose();
    });
  });

  test('a late event cannot roll a seat back', () {
    fakeAsync((async) {
      final src = FakeSource();
      final c = SeatMapSyncController(source: src, fetch: () async => snap([seat('a', SeatStatus.booked, 10)]));
      c.start();
      async.flushMicrotasks();
      src.deltaCtl.add([const SeatDelta(seatId: 'a', status: SeatStatus.held, rev: 9)]);
      expect(c.snapshot!.seats.single.status, SeatStatus.booked);
      c.dispose();
    });
  });

  test('reconnect triggers a full re-read, and isVerified follows the channel', () {
    fakeAsync((async) {
      final src = FakeSource();
      var now = DateTime(2026, 10, 3, 10, 0, 0);
      var fetches = 0;
      final c = SeatMapSyncController(
        source: src,
        now: () => now,
        fetch: () async {
          fetches++;
          return snap([seat('a', SeatStatus.available, 1)]);
        },
      );
      c.start();
      async.flushMicrotasks();
      expect(c.isVerified, isTrue, reason: 'just fetched');

      src.connCtl.add(SeatSyncStatus.live);
      async.flushMicrotasks();
      final afterLive = fetches;
      expect(c.isVerified, isTrue);

      // connection drops: still verified for a short while after the last read ...
      src.connCtl.add(SeatSyncStatus.reconnecting);
      expect(c.status, SeatSyncStatus.reconnecting);
      now = now.add(const Duration(seconds: 10));
      expect(c.isVerified, isTrue);
      // ... but not once the last read is stale: the UI must stop trusting "available"
      now = now.add(const Duration(seconds: 40));
      expect(c.isVerified, isFalse);

      // coming back re-reads the authoritative state
      src.connCtl.add(SeatSyncStatus.live);
      async.flushMicrotasks();
      expect(fetches, greaterThan(afterLive));
      expect(c.isVerified, isTrue);
      c.dispose();
    });
  });

  test('periodic reconciliation keeps running without any events', () {
    fakeAsync((async) {
      final src = FakeSource();
      var fetches = 0;
      final c = SeatMapSyncController(
        source: src,
        reconcileEvery: const Duration(seconds: 60),
        fetch: () async {
          fetches++;
          return snap([seat('a', SeatStatus.available, 1)]);
        },
      );
      c.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 125));
      async.flushMicrotasks();
      expect(fetches, 3); // initial + 2 timer ticks
      c.dispose();
    });
  });

  test('a failed fetch keeps the last map, reports the error, and recovers on the next read', () {
    fakeAsync((async) {
      final src = FakeSource();
      var fail = false;
      final c = SeatMapSyncController(source: src, fetch: () async {
        if (fail) throw Exception('offline');
        return snap([seat('a', SeatStatus.available, 1)]);
      });
      c.start();
      async.flushMicrotasks();
      fail = true;
      c.refresh();
      async.flushMicrotasks();
      expect(c.error, isNotNull);
      expect(c.snapshot, isNotNull, reason: 'last known map stays visible');
      fail = false;
      c.refresh();
      async.flushMicrotasks();
      expect(c.error, isNull);
      c.dispose();
    });
  });

  test('delta for an unknown seat triggers an immediate refetch', () {
    fakeAsync((async) {
      final src = FakeSource();
      var fetches = 0;
      final c = SeatMapSyncController(source: src, fetch: () async {
        fetches++;
        return snap([seat('a', SeatStatus.available, 1)]);
      });
      c.start();
      async.flushMicrotasks();
      src.deltaCtl.add([const SeatDelta(seatId: 'new-seat', status: SeatStatus.held, rev: 3)]);
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(fetches, 2);
      c.dispose();
    });
  });

  test('dispose stops the source and ignores late results', () {
    fakeAsync((async) {
      final src = FakeSource();
      final c = SeatMapSyncController(source: src, fetch: () async => snap([seat('a', SeatStatus.available, 1)]));
      c.start();
      async.flushMicrotasks();
      c.dispose();
      expect(src.stopped, isTrue);
    });
  });
}
