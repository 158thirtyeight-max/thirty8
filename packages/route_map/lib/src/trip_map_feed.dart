import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'live_fix.dart';
import 'models.dart';

/// Loads one trip's route map once and follows its live position.
///
/// * Route + stops + stored road geometry: one `get_trip_route_map` read (never recalculated here).
/// * Live position: `get_trip_tracking`, re-read when the trip's private tracking channel pings and
///   every [pollInterval] as a safety net (a missed ping or a dropped Realtime connection).
/// * Subscribes to this trip only. When the trip has ended it reads the final position once and
///   stops the channel and the timer.
class TripMapFeed extends ChangeNotifier {
  TripMapFeed({required this.client, required this.tripId, this.pollInterval = const Duration(seconds: 30)});

  final SupabaseClient client;
  final String tripId;
  final Duration pollInterval;

  RouteMapData? route;
  bool routeLoading = true;
  bool routeFailed = false;

  /// Latest tracking read; null until the first success, kept (not cleared) when a later read fails.
  LiveFix? fix;
  bool trackingFailed = false;
  bool get ended => fix?.status == FixStatus.ended || route?.tripStatus == 'arrived' || route?.tripStatus == 'cancelled';

  RealtimeChannel? _channel;
  Timer? _timer;
  bool _disposed = false;
  bool _loadingTracking = false;

  Future<void> start() async {
    await Future.wait([loadRoute(), loadTracking()]);
    if (_disposed || ended) return;
    _timer = Timer.periodic(pollInterval, (_) => loadTracking());
    _channel = client.channel('trip:$tripId:track', opts: const RealtimeChannelConfig(private: true))
      ..onBroadcast(event: 'tracking', callback: (_) => loadTracking())
      ..subscribe();
  }

  Future<void> loadRoute() async {
    routeLoading = true;
    routeFailed = false;
    _notify();
    try {
      final res = await client.rpc('get_trip_route_map', params: {'p_trip_id': tripId});
      route = RouteMapData.fromJson(Map<String, dynamic>.from(res as Map));
    } catch (_) {
      routeFailed = true;
    }
    routeLoading = false;
    _notify();
  }

  Future<void> loadTracking() async {
    if (_loadingTracking) return;
    _loadingTracking = true;
    try {
      final res = await client.rpc('get_trip_tracking', params: {'p_trip_id': tripId});
      fix = LiveFix.fromJson(Map<String, dynamic>.from(res as Map));
      trackingFailed = false;
      if (ended) _stopListening();
    } catch (_) {
      trackingFailed = true;
    }
    _loadingTracking = false;
    _notify();
  }

  void _stopListening() {
    _timer?.cancel();
    _timer = null;
    final c = _channel;
    _channel = null;
    if (c != null) client.removeChannel(c);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopListening();
    super.dispose();
  }
}
