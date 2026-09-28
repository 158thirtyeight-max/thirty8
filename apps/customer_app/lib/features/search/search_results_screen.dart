import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'bus_details_screen.dart';
import 'city.dart';

class SearchResultsScreen extends ConsumerStatefulWidget {
  const SearchResultsScreen({super.key, required this.source, required this.destination, required this.date});

  final City source;
  final City destination;
  final DateTime date;

  @override
  ConsumerState<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends ConsumerState<SearchResultsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _direct = [];
  List<Map<String, dynamic>> _connected = [];

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    try {
      final res = await ref.read(supabaseProvider).rpc('search_trips', params: {
        'p_source_city_id': widget.source.id,
        'p_destination_city_id': widget.destination.id,
        'p_travel_date': DateFormat('yyyy-MM-dd').format(widget.date),
      });
      if (!mounted) return;
      final map = res as Map<String, dynamic>;
      setState(() {
        _direct = List<Map<String, dynamic>>.from(map['direct'] as List? ?? []);
        _connected = List<Map<String, dynamic>>.from(map['connected'] as List? ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load results. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.source.name} → ${widget.destination.name}'),
      ),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            if (_loading) return const Center(child: CircularProgressIndicator());
            if (_error != null) return Center(child: Text(_error!));
            if (_direct.isEmpty && _connected.isEmpty) {
              return const Center(child: Text('No buses found for this route on this date'));
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_direct.isNotEmpty) ...[
                  Text('Direct', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ..._direct.map((t) => _DirectTripCard(trip: t)),
                  const SizedBox(height: 16),
                ],
                if (_connected.isNotEmpty) ...[
                  Text('With a change', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ..._connected.map((c) => _ConnectedTripCard(connection: c)),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

String _time(String iso) => DateFormat('h:mm a').format(DateTime.parse(iso).toLocal());

class _DirectTripCard extends StatelessWidget {
  const _DirectTripCard({required this.trip});

  final Map<String, dynamic> trip;

  @override
  Widget build(BuildContext context) {
    final fare = ((trip['min_fare_cents'] as int?) ?? 0) / 100;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(trip['operator_name'] as String? ?? 'Operator', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('₹${fare.toStringAsFixed(0)}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text((trip['bus_type'] as String? ?? '').replaceAll('_', ' ').toUpperCase(), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(_time(trip['departure_at'] as String), style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(width: 8),
                const Expanded(child: Divider()),
                const SizedBox(width: 8),
                Text('${trip['available_seats']} seats left', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(width: 8),
                const Expanded(child: Divider()),
                const SizedBox(width: 8),
                Text(_time(trip['arrival_at'] as String), style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => BusDetailsScreen(trip: trip)),
                  );
                },
                child: const Text('Select seats'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectedTripCard extends StatelessWidget {
  const _ConnectedTripCard({required this.connection});

  final Map<String, dynamic> connection;

  @override
  Widget build(BuildContext context) {
    final leg1 = connection['leg1'] as Map<String, dynamic>;
    final leg2 = connection['leg2'] as Map<String, dynamic>;
    final total = ((connection['total_min_fare_cents'] as int?) ?? 0) / 100;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Change required', style: TextStyle(fontWeight: FontWeight.bold)),
                Text('₹${total.toStringAsFixed(0)}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            Text('${leg1['operator_name']} · ${_time(leg1['departure_at'] as String)} → ${_time(leg1['arrival_at'] as String)}'),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [Icon(Icons.swap_horiz, size: 16, color: Colors.grey), SizedBox(width: 4), Text('Change buses', style: TextStyle(color: Colors.grey, fontSize: 12))]),
            ),
            Text('${leg2['operator_name']} · ${_time(leg2['departure_at'] as String)} → ${_time(leg2['arrival_at'] as String)}'),
          ],
        ),
      ),
    );
  }
}
