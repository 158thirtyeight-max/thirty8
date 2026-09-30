import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import '../../core/theme.dart';
import 'passenger_details_screen.dart';

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
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _seats = [];
  final Set<String> _selectedSeatIds = {};
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _loadSeatMap();
  }

  Future<void> _loadSeatMap() async {
    try {
      // Fares depend on the chosen boarding/dropping points; the server is the
      // single source of truth for the price of every seat.
      final res = await ref.read(supabaseProvider).rpc('get_trip_seat_map', params: {
        'p_trip_id': widget.trip['trip_id'],
        'p_boarding_point_id': widget.boardingPoint['id'],
        'p_dropping_point_id': widget.droppingPoint['id'],
      });
      if (!mounted) return;
      final map = res as Map<String, dynamic>;
      setState(() {
        _seats = List<Map<String, dynamic>>.from(map['seats'] as List? ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the seat map.';
        _loading = false;
      });
    }
  }

  void _toggleSeat(Map<String, dynamic> seat) {
    if (seat['status'] != 'available') return;
    setState(() {
      final id = seat['seat_id'] as String;
      if (_selectedSeatIds.contains(id)) {
        _selectedSeatIds.remove(id);
      } else {
        _selectedSeatIds.add(id);
      }
    });
  }

  int get _totalFareCents {
    return _seats
        .where((s) => _selectedSeatIds.contains(s['seat_id']))
        .fold<int>(0, (sum, s) => sum + (s['fare_cents'] as int? ?? 0));
  }

  Future<void> _continue() async {
    if (_selectedSeatIds.isEmpty) return;
    setState(() => _holding = true);
    try {
      final result = await ref.read(supabaseProvider).rpc('create_seat_hold', params: {
        'p_trip_id': widget.trip['trip_id'],
        'p_seat_ids': _selectedSeatIds.toList(),
        'p_ttl_seconds': 300,
        'p_boarding_point_id': widget.boardingPoint['id'],
        'p_dropping_point_id': widget.droppingPoint['id'],
      });
      if (!mounted) return;
      final hold = result as Map<String, dynamic>;
      final selectedSeats = _seats.where((s) => _selectedSeatIds.contains(s['seat_id'])).toList();

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PassengerDetailsScreen(
            holdToken: hold['hold_token'] as String,
            expiresAt: DateTime.parse(hold['expires_at'] as String),
            selectedSeats: selectedSeats,
            boardingPoint: widget.boardingPoint,
            droppingPoint: widget.droppingPoint,
          ),
        ),
      );
      // On return (booking completed, hold expired, or user backed out), refresh
      // the seat map so it reflects the current server state.
      if (mounted) {
        setState(() {
          _selectedSeatIds.clear();
          _loading = true;
        });
        _loadSeatMap();
      }
    } catch (e) {
      if (!mounted) return;
      final text = e.toString();
      final message = text.contains('seat_unavailable')
          ? 'One or more selected seats were just taken. Please choose again.'
          : text.contains('bus_unavailable')
              ? 'This bus is no longer available for booking.'
              : text.contains('invalid_points')
                  ? 'Please choose a valid boarding and dropping point.'
                  : 'Could not hold those seats. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      setState(() {
        _selectedSeatIds.clear();
        _loading = true;
      });
      _loadSeatMap();
    } finally {
      if (mounted) setState(() => _holding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select seats')),
      body: _loading
          ? const AppLoadingState()
          : _error != null
              ? AppErrorState(message: _error!)
              : SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 16,
                          runSpacing: 8,
                          children: const [
                            _LegendItem(color: SeatColors.available, label: 'Available'),
                            _LegendItem(color: SeatColors.selected, label: 'Selected'),
                            _LegendItem(color: SeatColors.booked, label: 'Booked'),
                          ],
                        ),
                      ),
                      Expanded(child: SingleChildScrollView(child: _SeatGrid(seats: _seats, selected: _selectedSeatIds, onTap: _toggleSeat))),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _selectedSeatIds.isEmpty
                                      ? 'Select at least one seat'
                                      : '${_selectedSeatIds.length} seat(s) · ₹${(_totalFareCents / 100).toStringAsFixed(0)}',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                              AppButton(
                                label: 'Continue',
                                loading: _holding,
                                onPressed: (_selectedSeatIds.isEmpty || _holding) ? null : _continue,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _SeatGrid extends StatelessWidget {
  const _SeatGrid({required this.seats, required this.selected, required this.onTap});

  final List<Map<String, dynamic>> seats;
  final Set<String> selected;
  final void Function(Map<String, dynamic>) onTap;

  @override
  Widget build(BuildContext context) {
    final rows = <int, List<Map<String, dynamic>>>{};
    for (final seat in seats) {
      final r = seat['row_no'] as int? ?? 0;
      rows.putIfAbsent(r, () => []).add(seat);
    }
    final sortedRowKeys = rows.keys.toList()..sort();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: sortedRowKeys.map((r) {
          final rowSeats = rows[r]!..sort((a, b) => (a['col_no'] as int? ?? 0).compareTo(b['col_no'] as int? ?? 0));
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < rowSeats.length; i++) ...[
                  if (i == 2) const SizedBox(width: 24), // aisle
                  _SeatButton(seat: rowSeats[i], isSelected: selected.contains(rowSeats[i]['seat_id']), onTap: onTap),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SeatButton extends StatelessWidget {
  const _SeatButton({required this.seat, required this.isSelected, required this.onTap});

  final Map<String, dynamic> seat;
  final bool isSelected;
  final void Function(Map<String, dynamic>) onTap;

  @override
  Widget build(BuildContext context) {
    final status = seat['status'] as String? ?? 'available';
    final color = isSelected
        ? SeatColors.selected
        : status == 'available'
            ? SeatColors.available
            : SeatColors.booked;
    final tappable = status == 'available';

    return Padding(
      padding: const EdgeInsets.all(4),
      child: InkWell(
        onTap: tappable ? () => onTap(seat) : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: tappable || isSelected ? 1 : 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            seat['seat_code'] as String? ?? '',
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 14, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
