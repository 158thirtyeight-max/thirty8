import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:seat_map/seat_map.dart';

import '../../core/supabase_providers.dart';
import 'booking_errors.dart';
import 'passenger_details_screen.dart';

/// Seat selection on the REAL bus layout (aisles, decks, seat positions), kept live:
/// when another customer holds or books a seat it changes on this screen within moments.
/// The backend decides at `create_seat_hold`; this screen only reflects and requests.
class SeatSelectionScreen extends ConsumerStatefulWidget {
  const SeatSelectionScreen({
    super.key,
    required this.trip,
    required this.boardingPoint,
    required this.droppingPoint,
  });

  final Map<String, dynamic> trip;
  final Map<String, dynamic> boardingPoint;
  final Map<String, dynamic> droppingPoint;

  @override
  ConsumerState<SeatSelectionScreen> createState() => _SeatSelectionScreenState();
}

class _SeatSelectionScreenState extends ConsumerState<SeatSelectionScreen> {
  late final SeatMapSyncController _sync;
  final Set<String> _selected = {};
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    final client = ref.read(supabaseProvider);
    _sync = SeatMapSyncController(
      source: SupabaseSeatEventSource(client, widget.trip['trip_id'] as String),
      fetch: () async {
        // Fares depend on the chosen boarding/dropping points; the server is the
        // single source of truth for the price of every seat.
        final res = await client.rpc('get_trip_seat_map', params: {
          'p_trip_id': widget.trip['trip_id'],
          'p_boarding_point_id': widget.boardingPoint['id'],
          'p_dropping_point_id': widget.droppingPoint['id'],
        });
        if (res == null) throw StateError('trip closed');
        return SeatMapSnapshot.fromJson(Map<String, dynamic>.from(res as Map));
      },
    )..addListener(_onChanged);
    _sync.start();
  }

  void _onChanged() {
    if (!mounted) return;
    // A selected seat that someone else took is dropped from the selection, and we say so.
    final snap = _sync.snapshot;
    if (snap != null && _selected.isNotEmpty) {
      final lost = [for (final s in snap.seats) if (_selected.contains(s.seatId) && s.status != SeatStatus.available) s];
      if (lost.isNotEmpty) {
        _selected.removeAll(lost.map((s) => s.seatId));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(seatTakenMessage)));
        });
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _sync.removeListener(_onChanged);
    _sync.dispose();
    super.dispose();
  }

  Future<void> _toggleSeat(MapSeat seat) async {
    if (seat.status != SeatStatus.available) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(seat.status == SeatStatus.held ? 'Another passenger is booking this seat right now.' : 'This seat is not available.'),
      ));
      return;
    }
    // Never act on availability we cannot verify: re-read first.
    if (!_sync.isVerified) {
      await _sync.refresh();
      final fresh = _sync.snapshot?.seats.where((s) => s.seatId == seat.seatId).firstOrNull;
      if (!mounted || fresh == null || fresh.status != SeatStatus.available) return;
    }
    setState(() {
      if (!_selected.add(seat.seatId)) _selected.remove(seat.seatId);
    });
  }

  int get _totalFareCents {
    final snap = _sync.snapshot;
    if (snap == null) return 0;
    return snap.seats.where((s) => _selected.contains(s.seatId)).fold<int>(0, (sum, s) => sum + (s.fareCents ?? 0));
  }

  Future<void> _continue() async {
    if (_selected.isEmpty) return;
    setState(() => _holding = true);
    try {
      final result = await ref.read(supabaseProvider).rpc('create_seat_hold', params: {
        'p_trip_id': widget.trip['trip_id'],
        'p_seat_ids': _selected.toList(),
        'p_ttl_seconds': 300,
        'p_boarding_point_id': widget.boardingPoint['id'],
        'p_dropping_point_id': widget.droppingPoint['id'],
      });
      if (!mounted) return;
      final hold = result as Map<String, dynamic>;
      final selectedSeats = [
        for (final s in _sync.snapshot!.seats)
          if (_selected.contains(s.seatId)) {'seat_id': s.seatId, 'seat_code': s.code, 'fare_cents': s.fareCents, 'trip_seat_id': s.tripSeatId},
      ];

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PassengerDetailsScreen(
            holdToken: hold['hold_token'] as String,
            expiresAt: DateTime.parse(hold['expires_at'] as String),
            selectedSeats: selectedSeats,
            boardingPoint: widget.boardingPoint,
            droppingPoint: widget.droppingPoint,
          ),
        ),
      );
      // Booking completed, hold expired, or the user backed out: show the current server state.
      if (mounted) {
        setState(_selected.clear);
        _sync.refresh();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(seatHoldErrorMessage(e))));
      setState(_selected.clear);
      _sync.refresh();
    } finally {
      if (mounted) setState(() => _holding = false);
    }
  }

  String _syncText() {
    if (_sync.status == SeatSyncStatus.live) return 'Seats update live';
    final at = _sync.lastSyncedAt;
    final hhmm = at == null ? '' : ' · ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return _sync.isVerified ? 'Reconnecting$hhmm' : 'Offline – tap to refresh$hhmm';
  }

  @override
  Widget build(BuildContext context) {
    final snap = _sync.snapshot;
    return Scaffold(
      appBar: AppBar(title: const Text('Select seats')),
      body: snap == null
          ? (_sync.error != null
              ? AppErrorState(message: 'Could not load the seat map.', onRetry: _sync.refresh)
              : const AppLoadingState())
          : SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        const Expanded(child: SeatStatusLegend(statuses: [SeatStatus.available, SeatStatus.held, SeatStatus.booked], showSelected: true)),
                        SyncStatusChip(label: _syncText(), verified: _sync.isVerified, onRefresh: _sync.refresh),
                      ],
                    ),
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _sync.refresh,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        child: BusSeatMap(
                          layout: snap.layout,
                          seats: snap.seats,
                          selectedSeatIds: _selected,
                          dimAvailable: !_sync.isVerified,
                          onSeatTap: _toggleSeat,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _selected.isEmpty ? 'Select at least one seat' : '${_selected.length} seat(s) · ₹${(_totalFareCents / 100).toStringAsFixed(0)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        AppButton(
                          label: 'Continue',
                          loading: _holding,
                          onPressed: (_selected.isEmpty || _holding) ? null : _continue,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
