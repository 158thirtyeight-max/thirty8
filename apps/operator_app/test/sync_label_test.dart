import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/trip_dashboard/sync_label.dart';
import 'package:seat_map/seat_map.dart';

void main() {
  final at = DateTime(2026, 10, 3, 14, 5, 9);

  test('live shows the last update time', () {
    expect(syncLabel(status: SeatSyncStatus.live, lastSyncedAt: at, verified: true), 'Live · updated 2:05:09 PM');
  });

  test('before the first load', () {
    expect(syncLabel(status: SeatSyncStatus.connecting, lastSyncedAt: null, verified: false), 'Loading…');
    expect(syncLabel(status: SeatSyncStatus.connecting, lastSyncedAt: null, verified: false, hasError: true), contains('retry'));
  });

  test('reconnecting and offline never claim to be live', () {
    expect(syncLabel(status: SeatSyncStatus.reconnecting, lastSyncedAt: at, verified: false), startsWith('Reconnecting'));
    expect(syncLabel(status: SeatSyncStatus.offline, lastSyncedAt: at, verified: false), contains('last updated'));
    expect(syncLabel(status: SeatSyncStatus.offline, lastSyncedAt: at, verified: true), isNot(startsWith('Live')));
  });

  test('a failed refresh on a live channel is not labelled live', () {
    expect(syncLabel(status: SeatSyncStatus.live, lastSyncedAt: at, verified: true, hasError: true), isNot(startsWith('Live')));
  });
}
