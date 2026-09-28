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

    final boarding = await supabase.from('boarding_points').select().eq('route_id', routeId).order('sequence_no');
    final dropping = await supabase.from('dropping_points').select().eq('route_id', routeId).order('sequence_no');

    if (!mounted) return;
    setState(() {
      _boardingPoints = List<Map<String, dynamic>>.from(boarding as List);
      _droppingPoints = List<Map<String, dynamic>>.from(dropping as List);
      _selectedBoarding = _boardingPoints.isNotEmpty ? _boardingPoints.first : null;
      _selectedDropping = _droppingPoints.isNotEmpty ? _droppingPoints.first : null;
      _loading = false;
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
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(trip['operator_name'] as String? ?? '', style: Theme.of(context).textTheme.titleMedium),
                          if (trip['operator_rating'] != null) ...[
                            const SizedBox(height: 4),
                            Row(children: [const Icon(Icons.star, size: 16, color: Colors.amber), Text(' ${trip['operator_rating']}')]),
                          ],
                          const SizedBox(height: 8),
                          Text((trip['bus_type'] as String? ?? '').replaceAll('_', ' ').toUpperCase(), style: Theme.of(context).textTheme.bodySmall),
                          if (amenities.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: amenities.map((a) => Chip(label: Text(a.replaceAll('_', ' ')))).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Boarding point', style: Theme.of(context).textTheme.titleSmall),
                  ..._boardingPoints.map((bp) => RadioListTile<Map<String, dynamic>>(
                        value: bp,
                        groupValue: _selectedBoarding,
                        onChanged: (v) => setState(() => _selectedBoarding = v),
                        title: Text(bp['name'] as String),
                        subtitle: bp['address'] != null ? Text(bp['address'] as String) : null,
                      )),
                  const SizedBox(height: 8),
                  Text('Dropping point', style: Theme.of(context).textTheme.titleSmall),
                  ..._droppingPoints.map((dp) => RadioListTile<Map<String, dynamic>>(
                        value: dp,
                        groupValue: _selectedDropping,
                        onChanged: (v) => setState(() => _selectedDropping = v),
                        title: Text(dp['name'] as String),
                        subtitle: dp['address'] != null ? Text(dp['address'] as String) : null,
                      )),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _continue,
                    child: const Text('Select seats'),
                  ),
                ],
              ),
            ),
    );
  }
}

String formatTime(String iso) => DateFormat('h:mm a').format(DateTime.parse(iso).toLocal());
