import 'package:intl/intl.dart';
import 'package:seat_map/seat_map.dart';

/// Text for the sync indicator: what the operator can trust and since when.
String syncLabel({
  required SeatSyncStatus status,
  required DateTime? lastSyncedAt,
  required bool verified,
  bool hasError = false,
}) {
  final at = lastSyncedAt == null ? null : DateFormat('h:mm:ss a').format(lastSyncedAt);
  if (lastSyncedAt == null) return hasError ? 'Could not load — tap to retry' : 'Loading…';
  if (status == SeatSyncStatus.live && !hasError) return 'Live · updated $at';
  if (status == SeatSyncStatus.reconnecting || status == SeatSyncStatus.connecting) {
    return verified ? 'Reconnecting · updated $at' : 'Reconnecting… last updated $at';
  }
  return verified ? 'Offline · updated $at' : 'Offline — last updated $at';
}
