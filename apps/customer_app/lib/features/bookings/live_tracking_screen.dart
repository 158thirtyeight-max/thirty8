import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';
import 'tracking_status.dart';

/// Follow your bus. The status is decided by the backend (GPS tracker first; an estimate is always
/// labelled as one; stale or offline positions say so). Updates arrive as a tiny "changed" ping on a
/// private channel and the screen re-reads; a 30 s timer covers a missed ping.
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
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    final client = ref.read(supabaseProvider);
    _channel = client.channel('trip:${widget.tripId}:track', opts: const RealtimeChannelConfig(private: true))
      ..onBroadcast(event: 'tracking', callback: (_) => _load())
      ..subscribe();
  }

  @override
  void dispose() {
    _timer?.cancel();
    final c = _channel;
    if (c != null) ref.read(supabaseProvider).removeChannel(c);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(supabaseProvider).rpc('get_trip_tracking', params: {'p_trip_id': widget.tripId});
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
    final theme = Theme.of(context);
    final data = _data;
    final loc = data == null ? null : VehicleLocation.fromJson(data);
    final time = DateFormat('h:mm a');

    return Scaffold(
      appBar: AppBar(title: const Text('Live tracking')),
      body: _loading
          ? const AppLoadingState()
          : data == null
              ? AppEmptyState(message: 'Tracking is not available for this trip.', icon: Icons.location_off_outlined, action: AppButton(label: 'Retry', onPressed: _load))
              : SafeArea(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Container(width: 12, height: 12, decoration: BoxDecoration(color: loc!.status.color, shape: BoxShape.circle)),
                                const SizedBox(width: 8),
                                Expanded(child: Text(loc.status.title, style: theme.textTheme.titleMedium)),
                              ]),
                              const SizedBox(height: 6),
                              Text(loc.status.explanation, style: theme.textTheme.bodySmall),
                              if (loc.recordedAt != null) ...[
                                const SizedBox(height: 6),
                                Text('Updated ${time.format(loc.recordedAt!)}', style: theme.textTheme.bodySmall),
                              ],
                            ],
                          ),
                        ),
                        if (loc.hasPoint) ...[
                          const SizedBox(height: 12),
                          _MapCard(location: loc),
                        ],
                        const SizedBox(height: 16),
                        const AppSectionHeader(title: 'Stops reached'),
                        if ((data['milestones'] as List? ?? const []).isEmpty)
                          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('No stops reached yet.', style: theme.textTheme.bodySmall))
                        else
                          ...[
                            for (final e in List<Map<String, dynamic>>.from((data['milestones'] as List).map((m) => Map<String, dynamic>.from(m as Map))))
                              AppListItem(
                                leading: Icon(e['point_type'] == 'dropping' ? Icons.flag : Icons.trip_origin, size: 20),
                                title: 'Reached ${e['point_name']}',
                                subtitle: time.format(DateTime.parse(e['recorded_at'] as String).toLocal()),
                              ),
                          ],
                      ],
                    ),
                  ),
                ),
    );
  }
}

class _MapCard extends StatelessWidget {
  const _MapCard({required this.location});

  final VehicleLocation location;

  @override
  Widget build(BuildContext context) {
    final pos = LatLng(location.latitude!, location.longitude!);
    final s = location.status;
    final color = s.color;
    return ClipRRect(
      borderRadius: AppRadius.lgRadius,
      child: SizedBox(
        height: 240,
        child: FlutterMap(
          options: MapOptions(initialCenter: pos, initialZoom: 13, interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate)),
          children: [
            TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.thirty8.customer_app'),
            if (s.isEstimate) CircleLayer(circles: [CircleMarker(point: pos, radius: 150, useRadiusInMeter: true, color: color.withValues(alpha: 0.15), borderColor: color, borderStrokeWidth: 1.5)]),
            MarkerLayer(markers: [
              Marker(
                point: pos,
                width: 40,
                height: 40,
                child: Container(
                  decoration: BoxDecoration(
                    color: s.isEstimate ? Colors.white : color,
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 3),
                    boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
                  ),
                  child: Icon(s.isLive ? Icons.directions_bus : (s.isEstimate ? Icons.help_outline : Icons.hourglass_empty), size: 22, color: s.isEstimate ? color : Colors.white),
                ),
              ),
            ]),
            const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
          ],
        ),
      ),
    );
  }
}
