import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Listens to a trip's private Broadcast ping channel (`trip:<id>:ops` by default, `:track` for
/// tracking). A message means "something changed" — it carries no amounts, personal data or
/// coordinates, so the screen reacts by re-reading its authorized RPCs.
class TripOpsChannel {
  TripOpsChannel(
    this._client,
    this.tripId,
    this.onChange, {
    this.debounce = const Duration(milliseconds: 600),
    this.topicSuffix = 'ops',
    this.event = 'changed',
  });

  final String topicSuffix;
  final String event;

  final SupabaseClient _client;
  final String tripId;
  final void Function() onChange;
  final Duration debounce;

  RealtimeChannel? _channel;
  Timer? _timer;

  void start() {
    final channel = _client.channel('trip:$tripId:$topicSuffix', opts: const RealtimeChannelConfig(private: true));
    channel.onBroadcast(event: event, callback: (_) => _schedule()).subscribe();
    _channel = channel;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, onChange);
  }

  Future<void> stop() async {
    _timer?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client.removeChannel(channel);
  }
}
