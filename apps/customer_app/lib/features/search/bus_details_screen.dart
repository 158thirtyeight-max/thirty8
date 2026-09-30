import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import '../booking/seat_selection_screen.dart';

class BusDetailsScreen extends ConsumerStatefulWidget {
  const BusDetailsScreen({super.key, required this.trip});

  /// The trip map as returned by the search_trips RPC's `direct` array.
  final Map<String, dynamic> trip;

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
    final trip = await supabase.from('bus_trips').select('route_id').eq('id', widget.trip['trip_id'] as String).single();
    final routeId = trip['route_id'] as String;

    final boarding = await supabase.from('boarding_points').select().eq('route_id', routeId).eq('is_active', true).order('sequence_no');
    final dropping = await supabase.from('dropping_points').select().eq('route_id', routeId).eq('is_active', true).order('sequence_no');

    if (!mounted) return;
    setState(() {
      _boardingPoints = List<Map<String, dynamic>>.from(boarding as List);
      _droppingPoints = List<Map<String, dynamic>>.from(dropping as List);
      _selectedBoarding = _boardingPoints.isNotEmpty ? _boardingPoints.first : null;
      final valid = _validDropping;
      _selectedDropping = valid.isNotEmpty ? valid.first : null;
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
