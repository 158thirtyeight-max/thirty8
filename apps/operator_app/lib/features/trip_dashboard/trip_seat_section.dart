import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:seat_map/seat_map.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';
import 'sync_label.dart';
import 'trip_occupancy_card.dart';

/// Seat Layout section of the trip dashboard: the real bus, live. The seat inventory in
/// the backend is the source of truth; broadcasts update the map and a re-read reconciles.
class TripSeatSection extends ConsumerStatefulWidget {
  const TripSeatSection({super.key, required this.tripId, required this.tripStatus, this.canEdit = true});

  final String tripId;
  final String tripStatus;

  /// Whether the signed-in user may block/release seats (the server enforces it too).
  final bool canEdit;

  @override
  ConsumerState<TripSeatSection> createState() => _TripSeatSectionState();
}

class _TripSeatSectionState extends ConsumerState<TripSeatSection> {
  late final SeatMapSyncController _sync;

  @override
  void initState() {
    super.initState();
    final client = ref.read(supabaseProvider);
    _sync = SeatMapSyncController(
      source: SupabaseSeatEventSource(client, widget.tripId),
      fetch: () async {
        final res = await client.rpc('get_operator_trip_seat_map', params: {'p_trip_id': widget.tripId});
        return SeatMapSnapshot.fromJson(Map<String, dynamic>.from(res as Map));
      },
    )..addListener(_onChanged);
    _sync.start();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sync.removeListener(_onChanged);
    _sync.dispose();
    super.dispose();
  }

  bool get _editable => widget.canEdit && (widget.tripStatus == 'scheduled' || widget.tripStatus == 'boarding');

  String _message(Object e) {
    final text = e is PostgrestException ? e.message : e.toString();
    if (text.contains('seat_unavailable')) return 'That seat is no longer available to block.';
    if (text.contains('seat_not_blocked')) return 'That seat is not blocked.';
    if (text.contains('trip_not_editable')) return 'Seats cannot be changed after departure.';
    if (text.contains('service_inactive')) return 'The Bus service is not active.';
    if (text.contains('reason is required')) return 'Please give a reason.';
    return 'Could not update the seat. Please try again.';
  }

  Future<void> _change(MapSeat seat, {required bool block}) async {
    final client = ref.read(supabaseProvider);
    String? reason;
    if (block) {
      reason = await _askReason();
      if (reason == null) return;
    }
    try {
      await client.rpc(block ? 'operator_block_seats' : 'operator_release_seats', params: {
        'p_trip_id': widget.tripId,
        'p_seat_ids': [seat.seatId],
        'p_reason': reason,
      });
      await _sync.refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_message(e))));
    }
  }

  Future<String?> _askReason() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Block this seat'),
        content: AppTextField(controller: controller, label: 'Reason (e.g. reserved for crew)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.pop(dialogContext, v);
            },
            child: const Text('Block seat'),
          ),
        ],
      ),
    );
  }

  Future<void> _onSeatTap(MapSeat seat) async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('Seat ${seat.code}', style: theme.textTheme.titleLarge),
                const SizedBox(width: AppSpacing.sm),
                AppBadge(status: seat.status.name),
              ]),
              const SizedBox(height: AppSpacing.sm),
              Text('${seat.isSleeper ? 'Sleeper' : 'Seater'}${seat.berth == null ? '' : ' · ${seat.berth} berth'}'
                  '${seat.fareCents == null ? '' : ' · ₹${(seat.fareCents! / 100).toStringAsFixed(2)}'}'),
              if (seat.bookingReference != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text('Booking ${seat.bookingReference}', style: theme.textTheme.titleSmall),
                Text('Status: ${seat.bookingStatus ?? '—'}', style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text('Passenger details are in the manifest.', style: theme.textTheme.bodySmall),
              ] else if (seat.status == SeatStatus.held)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text('A customer is checking out. It frees up automatically if they do not pay.', style: theme.textTheme.bodySmall),
                ),
              if (_editable && _sync.isVerified && seat.status == SeatStatus.available) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Block seat',
                  icon: Icons.block,
                  variant: AppButtonVariant.outline,
                  expand: true,
                  onPressed: () {
                    Navigator.pop(sheet);
                    _change(seat, block: true);
                  },
                ),
              ],
              if (_editable && seat.status == SeatStatus.blocked) ...[
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: 'Release seat',
                  icon: Icons.lock_open,
                  expand: true,
                  onPressed: () {
                    Navigator.pop(sheet);
                    _change(seat, block: false);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snap = _sync.snapshot;
    final theme = Theme.of(context);

    if (snap == null) {
      return _sync.error != null
          ? AppErrorState(message: 'Could not load the seat map.', onRetry: _sync.refresh)
          : const AppLoadingState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TripOccupancyCard(counts: snap.counts),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: SyncStatusChip(
                label: syncLabel(
                  status: _sync.status,
                  lastSyncedAt: _sync.lastSyncedAt,
                  verified: _sync.isVerified,
                  hasError: _sync.error != null,
                ),
                verified: _sync.isVerified && _sync.error == null,
                onRefresh: _sync.refresh,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        BusSeatMap(
          layout: snap.layout,
          seats: snap.seats,
          dimAvailable: !_sync.isVerified,
          onSeatTap: _onSeatTap,
        ),
        const SizedBox(height: AppSpacing.sm),
        const SeatStatusLegend(statuses: [
          SeatStatus.available,
          SeatStatus.held,
          SeatStatus.booked,
          SeatStatus.boarded,
          SeatStatus.blocked,
        ]),
        if (!_sync.isVerified)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              'Live updates are paused, so available seats are shown faded until the map is refreshed.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning),
            ),
          ),
      ],
    );
  }
}
