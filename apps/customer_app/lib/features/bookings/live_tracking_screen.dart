import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

/// Polls track_bus_trip every 15s. No map widget/API — per the plan's
/// GPS-coordinate-matching design, position is shown as raw
/// lat/long + a milestone timeline, not a rendered map.
class LiveTrackingScreen extends ConsumerStatefulWidget {
  const LiveTrackingScreen({super.key, required this.tripId});

  final String tripId;

  @override
  ConsumerState<LiveTrackingScreen> createState() => _LiveTrackingScreenState();
}

class _LiveTrackingScreenState extends ConsumerState<LiveTrackingScreen> {
  bool _loading = true;
  Map<String, dynamic>? _data;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(supabaseProvider).rpc('track_bus_trip', params: {'p_trip_id': widget.tripId});
      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live tracking')),
      body: _loading
          ? const AppLoadingState()
          : _data == null
              ? const AppEmptyState(message: 'Tracking is not available for this trip.', icon: Icons.location_off_outlined)
              : SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Trip status: ${_data!['status']}', style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 8),
                            if (_data!['current_latitude'] != null)
                              Text('Last known position: ${_data!['current_latitude']}, ${_data!['current_longitude']}')
                            else
                              const Text('No location reported yet.'),
                            if (_data!['last_location_update'] != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Updated ${DateFormat('h:mm a').format(DateTime.parse(_data!['last_location_update'] as String).toLocal())}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      AppSectionHeader(title: 'Timeline'),
                      ...List<Map<String, dynamic>>.from(_data!['events'] as List).map((e) {
                        final isMilestone = e['event_type'] == 'milestone_arrived';
                        return AppListItem(
                          leading: Icon(isMilestone ? Icons.flag : Icons.gps_fixed, size: 20),
                          title: isMilestone ? 'Arrived at ${e['point_name']}' : 'Location update',
                          subtitle: DateFormat('h:mm a').format(DateTime.parse(e['recorded_at'] as String).toLocal()),
                        );
                      }),
                    ],
                  ),
                ),
    );
  }
}
