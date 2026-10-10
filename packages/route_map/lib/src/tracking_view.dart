import 'live_fix.dart';

/// How the bus marker is drawn and what the headline says. "Live" is only ever used for a fix that
/// is actually fresh at the moment of display.
enum TrackingKind { live, lastKnown, estimated, offline, notStarted, notAvailable, ended, unavailable }

/// A fix older than this is not "live" any more (matches the server's `tracker_fresh_seconds` default).
const liveFreshness = Duration(seconds: 120);

/// Past this, the vehicle is treated as offline rather than merely "last updated".
const offlineAfter = Duration(minutes: 15);

/// A GPS accuracy worse than this is shown as approximate.
const poorAccuracyM = 100.0;

class TrackingView {
  const TrackingView({required this.kind, required this.headline, this.detail, this.showBus = false, this.approximate = false});

  final TrackingKind kind;
  final String headline;
  final String? detail;
  final bool showBus;

  /// True when the position is poor or an estimate: the UI must not present it as precise.
  final bool approximate;

  bool get isLive => kind == TrackingKind.live;
}

String ageText(Duration age) {
  final s = age.inSeconds;
  if (s < 5) return 'just now';
  if (s < 60) return '$s sec ago';
  final m = age.inMinutes;
  if (m < 60) return '$m min ago';
  final h = age.inHours;
  if (h < 24) return '$h h ${m % 60} min ago';
  return '${age.inDays} d ago';
}

/// [fix] null means the tracking read itself failed (offline / error).
TrackingView describeTracking(LiveFix? fix, DateTime now) {
  if (fix == null) {
    return const TrackingView(
      kind: TrackingKind.unavailable,
      headline: 'Live tracking temporarily unavailable',
      detail: 'Check your connection. Your trip details are still available.',
    );
  }
  final age = fix.ageAt(now);
  final hasPoint = fix.point != null;
  final poor = (fix.accuracyM ?? 0) > poorAccuracyM;
  final accuracy = poor ? 'Position is approximate (±${fix.accuracyM!.round()} m)' : null;

  switch (fix.status) {
    case FixStatus.notStarted:
      return const TrackingView(kind: TrackingKind.notStarted, headline: 'Bus not started', detail: 'The location appears once the trip is under way.');
    case FixStatus.notConfigured:
      return const TrackingView(
        kind: TrackingKind.notAvailable,
        headline: 'Live tracking is not available for this bus',
        detail: 'The route and stops are shown on the map.',
      );
    case FixStatus.ended:
      return TrackingView(
        kind: TrackingKind.ended,
        headline: 'Trip completed',
        detail: hasPoint && age != null ? 'Final position ${ageText(age)}' : null,
        showBus: hasPoint,
      );
    case FixStatus.estimatedPassenger:
      return TrackingView(
        kind: TrackingKind.estimated,
        headline: 'Estimated location',
        detail: 'Based on passengers who chose to share. It may not be exact.',
        showBus: hasPoint,
        approximate: true,
      );
    case FixStatus.liveTracker:
    case FixStatus.liveFallback:
    case FixStatus.stale:
    case FixStatus.offline:
      if (!hasPoint) {
        return const TrackingView(kind: TrackingKind.offline, headline: 'Live tracking temporarily unavailable', detail: 'The bus location cannot be seen right now.');
      }
      final serverLive = fix.status == FixStatus.liveTracker || fix.status == FixStatus.liveFallback;
      if (serverLive && age != null && age <= liveFreshness) {
        final speed = fix.speedKmh != null ? '${fix.speedKmh!.round()} km/h · ' : '';
        return TrackingView(
          kind: TrackingKind.live,
          headline: 'Live',
          detail: '$speed${accuracy != null ? '$accuracy · ' : ''}Updated ${ageText(age)}',
          showBus: true,
          approximate: poor,
        );
      }
      // Anything not demonstrably fresh right now is "last known", never "live".
      if (age == null || age <= offlineAfter) {
        return TrackingView(
          kind: TrackingKind.lastKnown,
          headline: age == null ? 'Last known location' : 'Last updated ${ageText(age)}',
          detail: 'This is where the bus was last seen, not necessarily where it is now.',
          showBus: true,
          approximate: poor,
        );
      }
      return TrackingView(
        kind: TrackingKind.offline,
        headline: 'Live tracking temporarily unavailable',
        detail: 'Last seen ${ageText(age)}. The bus may be offline or out of coverage.',
        showBus: true,
        approximate: poor,
      );
  }
}
