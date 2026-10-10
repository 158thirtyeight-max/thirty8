import 'dart:async';
import 'dart:math' as math;

/// One reading from the phone, independent of the location plugin so the publishing rules can be
/// tested without a device.
class PhoneFix {
  const PhoneFix({required this.latitude, required this.longitude, required this.at, this.accuracyM, this.speedKmh, this.heading});

  final double latitude;
  final double longitude;
  final DateTime at;
  final double? accuracyM;
  final double? speedKmh;

  /// Degrees clockwise from north, only when the phone actually knows it.
  final double? heading;
}

enum PublishOutcome { sent, throttled, fallbackDisabled, notAuthorized, failed }

/// Sends the driver phone's position to Supabase (`update_bus_location`) while a trip is active.
///
/// Battery / data / write budget:
///  * the location stream itself is distance-filtered by the caller;
///  * a fix is sent when the bus moved at least [minDistanceM] AND at least [minInterval] has passed,
///    or as a [heartbeat] when it has not moved (so a standing bus does not look offline);
///  * the server additionally ignores fixes closer than 5 s apart.
/// It stops itself when the server says phone sharing is not enabled for the bus, and never starts
/// on its own: the caller starts it only for an active trip.
class PhoneLocationPublisher {
  PhoneLocationPublisher({
    required this.positions,
    required this.send,
    this.minInterval = const Duration(seconds: 10),
    this.heartbeat = const Duration(seconds: 60),
    this.minDistanceM = 25,
    this.distanceBetween = _flatDistanceM,
    this.onStopped,
  });

  final Stream<PhoneFix> Function() positions;
  final Future<PublishOutcome> Function(PhoneFix fix) send;
  final Duration minInterval;
  final Duration heartbeat;
  final double minDistanceM;
  final double Function(PhoneFix a, PhoneFix b) distanceBetween;

  /// Called when publishing ends on its own (server refused, stream failed) with the reason.
  final void Function(PublishOutcome? reason)? onStopped;

  StreamSubscription<PhoneFix>? _sub;
  PhoneFix? _lastSent;
  int sentCount = 0;

  bool get running => _sub != null;

  void start() {
    if (_sub != null) return;
    _sub = positions().listen(_onFix, onError: (_) => _stop(PublishOutcome.failed), cancelOnError: false);
  }

  Future<void> stop() async {
    final s = _sub;
    _sub = null;
    await s?.cancel();
  }

  Future<void> _stop(PublishOutcome? reason) async {
    await stop();
    onStopped?.call(reason);
  }

  bool shouldSend(PhoneFix f) {
    final last = _lastSent;
    if (last == null) return true;
    final since = f.at.difference(last.at);
    if (since >= heartbeat) return true;
    return since >= minInterval && distanceBetween(last, f) >= minDistanceM;
  }

  bool _inFlight = false;

  Future<void> _onFix(PhoneFix f) async {
    if (_inFlight || !shouldSend(f)) return;
    // (0, 0) is the "no fix yet" value of some devices, not a place.
    if (f.latitude == 0 && f.longitude == 0) return;
    _inFlight = true;
    try {
      final r = await send(f);
      switch (r) {
        case PublishOutcome.sent:
          _lastSent = f;
          sentCount++;
        case PublishOutcome.throttled:
          _lastSent = f;
        case PublishOutcome.fallbackDisabled:
        case PublishOutcome.notAuthorized:
          await _stop(r);
        case PublishOutcome.failed:
          break; // offline: keep listening, try again at the next fix
      }
    } finally {
      _inFlight = false;
    }
  }
}

double _flatDistanceM(PhoneFix a, PhoneFix b) {
  const mPerDeg = 111320.0;
  final dLat = (b.latitude - a.latitude) * mPerDeg;
  final dLng = (b.longitude - a.longitude) * mPerDeg * math.cos(a.latitude * math.pi / 180);
  return math.sqrt(dLat * dLat + dLng * dLng);
}
