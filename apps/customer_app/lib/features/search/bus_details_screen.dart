import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import '../booking/seat_selection_screen.dart';

class BusDetailsScreen extends ConsumerStatefulWidget {
  const BusDetailsScreen({super.key, required this.trip, this.sourceCityId, this.destinationCityId, this.pickupLocationId, this.dropLocationId});

  /// The trip map as returned by the search_trips RPC's `direct` array.
  final Map<String, dynamic> trip;

  /// The journey the customer searched (main-route location ids) and any exact pickup / drop
  /// location they chose. Only the bus's stops between the searched ends are offered, and the
  /// chosen locations are preselected.
  final String? sourceCityId;
  final String? destinationCityId;
  final String? pickupLocationId;
  final String? dropLocationId;

  @override
  ConsumerState<BusDetailsScreen> createState() => _BusDetailsScreenState();
}

class _BusDetailsScreenState extends ConsumerState<BusDetailsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _boardingPoints = [];
  List<Map<String, dynamic>> _droppingPoints = [];
  Map<String, dynamic>? _selectedBoarding;
  Map<String, dynamic>? _selectedDropping;

  @override
  void initState() {
    super.initState();
    _loadPoints();
  }

  Future<void> _loadPoints() async {
    final supabase = ref.read(supabaseProvider);
    // Stops come from an RPC: the trip and stop tables are not readable directly. The RPC
    // returns null once the trip is closed to booking.
    final res = await supabase.rpc('get_trip_points', params: {'p_trip_id': widget.trip['trip_id'] as String});
    final points = res as Map<String, dynamic>?;
    final boarding = (points?['boarding'] as List?) ?? const [];
    final dropping = (points?['dropping'] as List?) ?? const [];

    if (!mounted) return;
    // Stops are locations. Offer pickups from the searched origin up to (not including) the searched
    // destination, and drops after the origin up to the destination.
    var boardingList = List<Map<String, dynamic>>.from(boarding);
    var droppingList = List<Map<String, dynamic>>.from(dropping);
    final src = boardingList.where((p) => p['city_id'] == widget.sourceCityId).toList();
    final dst = droppingList.where((p) => p['city_id'] == widget.destinationCityId).toList();
    if (src.isNotEmpty && dst.isNotEmpty) {
      final from = src.first['sequence_no'] as int;
      final to = dst.last['sequence_no'] as int;
      boardingList = boardingList.where((p) => (p['sequence_no'] as int) >= from && (p['sequence_no'] as int) < to).toList();
      droppingList = droppingList.where((p) => (p['sequence_no'] as int) > from && (p['sequence_no'] as int) <= to).toList();
    }

    setState(() {
      _boardingPoints = boardingList;
      _droppingPoints = droppingList;
      _selectedBoarding = _boardingPoints.isEmpty
          ? null
          : _boardingPoints.firstWhere((p) => widget.pickupLocationId != null && p['city_id'] == widget.pickupLocationId, orElse: () => _boardingPoints.first);
      final valid = _validDropping;
      _selectedDropping = valid.isEmpty
          ? null
          : valid.firstWhere((p) => widget.dropLocationId != null && p['city_id'] == widget.dropLocationId, orElse: () => valid.last);
      _loading = false;
    });
  }

  /// On routes built with the operator setup wizard the stops are one ordered
  /// sequence, so only stops after the chosen boarding point can be dropped at.
  /// Older routes number the two lists independently and are shown unfiltered.
  List<Map<String, dynamic>> get _validDropping {
    final b = _selectedBoarding;
    if (b == null || b['departure_offset_min'] == null) return _droppingPoints;
    return _droppingPoints.where((d) => (d['sequence_no'] as int) > (b['sequence_no'] as int)).toList();
  }

  void _selectBoarding(Map<String, dynamic>? v) {
    setState(() {
      _selectedBoarding = v;
      final valid = _validDropping;
      if (_selectedDropping == null || !valid.any((d) => d['id'] == _selectedDropping!['id'])) {
        _selectedDropping = valid.isNotEmpty ? valid.first : null;
      }
    });
  }

  void _continue() {
    if (_selectedBoarding == null || _selectedDropping == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SeatSelectionScreen(
          trip: widget.trip,
          boardingPoint: _selectedBoarding!,
          droppingPoint: _selectedDropping!,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final amenities = List<String>.from(trip['amenities'] as List? ?? []);

    return Scaffold(
      appBar: AppBar(title: Text(trip['operator_name'] as String? ?? 'Bus details')),
      body: _loading
          ? const Center(child: AppLoadingState())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(trip['operator_name'] as String? ?? '', style: Theme.of(context).textTheme.titleMedium),
                        if (trip['operator_rating'] != null) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Row(children: [const Icon(Icons.star, size: 16, color: AppColors.accent), Text(' ${trip['operator_rating']}')]),
                        ],
                        const SizedBox(height: AppSpacing.sm),
                        Text((trip['bus_type'] as String? ?? '').replaceAll('_', ' ').toUpperCase(), style: Theme.of(context).textTheme.bodySmall),
                        if (amenities.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            spacing: AppSpacing.sm,
                            children: amenities.map((a) => AppChip(label: a.replaceAll('_', ' '))).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text('Boarding point', style: Theme.of(context).textTheme.titleSmall),
                  ..._boardingPoints.map((bp) => RadioListTile<Map<String, dynamic>>(
                        value: bp,
                        groupValue: _selectedBoarding,
                        onChanged: _selectBoarding,
                        title: Text(bp['name'] as String),
                        subtitle: bp['address'] != null ? Text(bp['address'] as String) : null,
                      )),
                  const SizedBox(height: AppSpacing.sm),
                  Text('Dropping point', style: Theme.of(context).textTheme.titleSmall),
                  ..._validDropping.map((dp) => RadioListTile<Map<String, dynamic>>(
                        value: dp,
                        groupValue: _selectedDropping,
                        onChanged: (v) => setState(() => _selectedDropping = v),
                        title: Text(dp['name'] as String),
                        subtitle: dp['address'] != null ? Text(dp['address'] as String) : null,
                      )),
                  const SizedBox(height: AppSpacing.lg),
                  AppButton(
                    label: 'Select seats',
                    onPressed: _continue,
                    expand: true,
                  ),
                ],
              ),
            ),
    );
  }
}

String formatTime(String iso) => DateFormat('h:mm a').format(DateTime.parse(iso).toLocal());
