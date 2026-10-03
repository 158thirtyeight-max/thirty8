import 'package:design_system/design_system.dart';
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

  /// Operators cannot cancel a departure directly: the request goes to the
  /// admin, who decides and triggers the existing cancellation/refund flow.
  Future<void> _requestCancellation(BuildContext context, WidgetRef ref) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Request cancellation'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('This departure only. Your recurring schedule is not affected. An admin reviews the request and handles passenger refunds.'),
            const SizedBox(height: 12),
            TextField(controller: reasonController, decoration: const InputDecoration(labelText: 'Reason')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Back')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Send request')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(supabaseProvider).rpc('request_trip_cancellation', params: {
        'p_trip_id': tripId,
        'p_reason': reasonController.text.trim(),
      });
      ref.invalidate(tripProvider(tripId));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send request: $e')));
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
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(fmt.format(DateTime.parse(trip['departure_at'] as String).toLocal()), style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          AppBadge(status: status),
                          const SizedBox(width: 8),
                          Text('${trip['available_seats']} seats available'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (nextStatus != null)
                      Expanded(
                        child: AppButton(
                          label: 'Mark as ${nextStatus[0].toUpperCase()}${nextStatus.substring(1)}',
                          onPressed: () => _updateStatus(context, ref, nextStatus),
                        ),
                      ),
                    if (status == 'scheduled') ...[
                      const SizedBox(width: 8),
                      if (trip['cancellation_request_status'] == 'requested')
                        const Text('Cancellation requested')
                      else
                        AppButton(
                          label: 'Request cancellation',
                          variant: AppButtonVariant.outline,
                          onPressed: () => _requestCancellation(context, ref),
                        ),
                    ],
                  ],
                ),
                const SizedBox(height: 24),
                Text('Manifest', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                manifestAsync.when(
                  data: (passengers) => passengers.isEmpty
                      ? const AppEmptyState(message: 'No confirmed passengers yet', icon: Icons.people_outline)
                      : Column(
                          children: passengers.map((p) {
                            final row = p as Map<String, dynamic>;
                            return AppCard(
                              padding: EdgeInsets.zero,
                              child: AppListItem(
                                leading: CircleAvatar(child: Text(row['seat_code'] as String)),
                                title: row['passenger_name'] as String? ?? 'Unnamed',
                                subtitle: '${row['boarding_point']} → ${row['dropping_point']}',
                                trailing: Text(row['seat_status'] as String? ?? ''),
                              ),
                            );
                          }).toList(),
                        ),
                  loading: () => const AppLoadingState(),
                  error: (e, st) => AppErrorState(message: 'Could not load manifest: $e'),
                ),
              ],
            ),
          );
        },
        loading: () => const AppLoadingState(),
        error: (e, st) => AppErrorState(
          message: 'Could not load trip: $e',
          onRetry: () => ref.invalidate(tripProvider(tripId)),
        ),
      ),
    );
  }
}
