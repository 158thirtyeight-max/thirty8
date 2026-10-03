import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

/// Health of the realtime channel as seen by the client.
enum SeatSyncStatus { connecting, live, reconnecting, offline }

/// Where seat-change events come from. The Supabase implementation listens to the
/// private Broadcast channel `trip:<id>:seats`; tests use a fake.
abstract class SeatEventSource {
  Stream<List<SeatDelta>> get deltas;
  Stream<SeatSyncStatus> get connection;
  Future<void> start();
  Future<void> stop();
}

/// Merges a fetched snapshot with the one we hold: per seat the HIGHER revision wins,
/// so a slow fetch that returns after a newer broadcast can never roll a seat back.
SeatMapSnapshot mergeSnapshots(SeatMapSnapshot? current, SeatMapSnapshot fetched) {
  if (current == null || current.tripId != fetched.tripId) return fetched;
  final held = {for (final s in current.seats) s.seatId: s};
  return SeatMapSnapshot(
    tripId: fetched.tripId,
    layout: fetched.layout,
    asOf: fetched.asOf,
    tripStatus: fetched.tripStatus,
    deckCount: fetched.deckCount,
    seats: [
      for (final s in fetched.seats)
        if (held[s.seatId] != null && held[s.seatId]!.rev > s.rev)
          // keep our newer status/rev, but take the fresh booking details from the fetch
          s.copyWith(status: held[s.seatId]!.status, rev: held[s.seatId]!.rev)
        else
          s,
    ],
  );
}

/// Keeps a seat map correct while the backend is the single source of truth:
///   1. load the full map (RPC),
///   2. apply broadcast deltas only when their revision is newer,
///   3. reconcile with a debounced re-fetch after events, on a timer, on reconnect and on
///      app resume,
///   4. report whether what is on screen can be trusted ([isVerified]) and since when.
/// Fetch results carry a sequence number: a response older than the last applied one is dropped.
class SeatMapSyncController extends ChangeNotifier with WidgetsBindingObserver {
  SeatMapSyncController({
    required this.fetch,
    required this.source,
    this.debounce = const Duration(milliseconds: 400),
    this.reconcileEvery = const Duration(seconds: 60),
    this.staleAfter = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<SeatMapSnapshot> Function() fetch;
  final SeatEventSource source;
  final Duration debounce;
  final Duration reconcileEvery;
  final Duration staleAfter;
  final DateTime Function() _now;

  SeatMapSnapshot? _snapshot;
  Object? _error;
  SeatSyncStatus _status = SeatSyncStatus.connecting;
  DateTime? _lastSyncedAt;

  int _seq = 0;
  int _appliedSeq = 0;
  bool _started = false;
  bool _disposed = false;
  StreamSubscription<List<SeatDelta>>? _deltaSub;
  StreamSubscription<SeatSyncStatus>? _connSub;
  Timer? _debounceTimer;
  Timer? _reconcileTimer;

  SeatMapSnapshot? get snapshot => _snapshot;
  Object? get error => _error;
  SeatSyncStatus get status => _status;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// True when the channel is live, or the last full read is recent enough to trust.
  /// While false the UI must not present "available" seats as bookable without re-checking.
  bool get isVerified {
    if (_snapshot == null) return false;
    if (_status == SeatSyncStatus.live) return true;
    final last = _lastSyncedAt;
    return last != null && _now().difference(last) < staleAfter;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _deltaSub = source.deltas.listen(_onDeltas);
    _connSub = source.connection.listen(_onConnection);
    _reconcileTimer = Timer.periodic(reconcileEvery, (_) => refresh());
    await source.start();
    await refresh();
  }

  void _onConnection(SeatSyncStatus next) {
    final recovered = next == SeatSyncStatus.live && _status != SeatSyncStatus.live;
    _status = next;
    _notify();
    if (recovered) refresh(); // anything could have changed while we were away
  }

  void _onDeltas(List<SeatDelta> deltas) {
    final snap = _snapshot;
    if (snap == null) {
      refresh();
      return;
    }
    final result = snap.applyDeltas(deltas);
    if (result.changed) {
      _snapshot = result.snapshot;
      _notify();
    }
    // The event is only a hint; reconcile with the authoritative read shortly after.
    _debounceTimer?.cancel();
    _debounceTimer = Timer(result.unknownSeat ? Duration.zero : debounce, refresh);
  }

  /// Full authoritative read. Safe to call at any time (pull-to-refresh, resume, timers).
  Future<void> refresh() async {
    if (_disposed) return;
    final seq = ++_seq;
    try {
      final fetched = await fetch();
      if (_disposed || seq < _appliedSeq) return; // an older response must not overwrite a newer one
      _appliedSeq = seq;
      _snapshot = mergeSnapshots(_snapshot, fetched);
      _lastSyncedAt = _now();
      _error = null;
    } catch (e) {
      if (_disposed) return;
      _error = e;
    }
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _debounceTimer?.cancel();
    _reconcileTimer?.cancel();
    _deltaSub?.cancel();
    _connSub?.cancel();
    source.stop();
    super.dispose();
  }
}

/// Listens to the private Broadcast channel `trip:<tripId>:seats`.
class SupabaseSeatEventSource implements SeatEventSource {
  SupabaseSeatEventSource(this._client, this.tripId);

  final SupabaseClient _client;
  final String tripId;
  RealtimeChannel? _channel;
  final _deltas = StreamController<List<SeatDelta>>.broadcast();
  final _connection = StreamController<SeatSyncStatus>.broadcast();

  @override
  Stream<List<SeatDelta>> get deltas => _deltas.stream;

  @override
  Stream<SeatSyncStatus> get connection => _connection.stream;

  @override
  Future<void> start() async {
    final channel = _client.channel('trip:$tripId:seats', opts: const RealtimeChannelConfig(private: true));
    channel
        .onBroadcast(
          event: 'seat_changes',
          callback: (message) {
            final data = message['payload'] is Map ? Map<String, dynamic>.from(message['payload'] as Map) : message;
            if (!_deltas.isClosed) _deltas.add(SeatDelta.parsePayload(data));
          },
        )
        .subscribe((status, error) {
      if (_connection.isClosed) return;
      _connection.add(switch (status) {
        RealtimeSubscribeStatus.subscribed => SeatSyncStatus.live,
        RealtimeSubscribeStatus.channelError || RealtimeSubscribeStatus.timedOut => SeatSyncStatus.reconnecting,
        RealtimeSubscribeStatus.closed => SeatSyncStatus.offline,
      });
    });
    _channel = channel;
  }

  @override
  Future<void> stop() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client.removeChannel(channel);
    await _deltas.close();
    await _connection.close();
  }
}
