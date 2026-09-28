import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'qr_scanner_screen.dart';

final tripProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, tripId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('bus_trips').select().eq('id', tripId).single();
});

final manifestProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, tripId) async {
  final supabase = ref.watch(supabaseProvider);
  final result = await supabase.rpc('generate_manifest', params: {'p_trip_id': tripId});
  return (result['passengers'] as List<dynamic>?) ?? [];
});

class TripDetailScreen extends ConsumerWidget {
  const TripDetailScreen({super.key, required this.tripId});

  final String tripId;

  static const _statusFlow = ['scheduled', 'boarding', 'departed', 'arrived'];

  Future<void> _updateStatus(BuildContext context, WidgetRef ref, String newStatus) async {
    try {
      await ref.read(supabaseProvider).from('bus_trips').update({'status': newStatus}).eq('id', tripId);
      ref.invalidate(tripProvider(tripId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update status: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tripAsync = ref.watch(tripProvider(tripId));
    final manifestAsync = ref.watch(manifestProvider(tripId));
    final fmt = DateFormat('EEE, d MMM yyyy · h:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan boarding tickets',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QrScannerScreen())),
          ),
        ],
      ),
      body: tripAsync.when(
        data: (trip) {
          final status = trip['status'] as String;
          final currentIndex = _statusFlow.indexOf(status);
          final nextStatus = status == 'cancelled' || currentIndex == _statusFlow.length - 1 ? null : _statusFlow[currentIndex + 1];

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(tripProvider(tripId));
              ref.invalidate(manifestProvider(tripId));
            },
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(fmt.format(DateTime.parse(trip['departure_at'] as String).toLocal()), style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text('Status: $status · ${trip['available_seats']} seats available'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (nextStatus != null)
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _updateStatus(context, ref, nextStatus),
                          child: Text('Mark as ${nextStatus[0].toUpperCase()}${nextStatus.substring(1)}'),
                        ),
                      ),
                    if (status != 'cancelled' && status != 'arrived') ...[
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () => _updateStatus(context, ref, 'cancelled'),
                        child: const Text('Cancel trip'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                Text('Manifest', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                manifestAsync.when(
                  data: (passengers) => passengers.isEmpty
                      ? const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('No confirmed passengers yet'))
                      : Column(
                          children: passengers.map((p) {
                            final row = p as Map<String, dynamic>;
                            return Card(
                              child: ListTile(
                                leading: CircleAvatar(child: Text(row['seat_code'] as String)),
                                title: Text(row['passenger_name'] as String? ?? 'Unnamed'),
                                subtitle: Text('${row['boarding_point']} → ${row['dropping_point']}'),
                                trailing: Text(row['seat_status'] as String? ?? ''),
                              ),
                            );
                          }).toList(),
                        ),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, st) => Text('Could not load manifest: $e'),
                ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Could not load trip: $e')),
      ),
    );
  }
}
