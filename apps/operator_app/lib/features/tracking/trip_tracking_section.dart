import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import '../fleet/fleet_providers.dart';
import '../trip_dashboard/trip_ops_channel.dart';
import 'gps_tracking_screen.dart';
import 'tracking_models.dart';

/// Trip → Tracking. The bus-mounted GPS tracker is the primary source; estimated and last-known
/// positions are drawn differently and always labelled, never as confirmed live tracking.
class TripTrackingSection extends ConsumerStatefulWidget {
  const TripTrackingSection({super.key, required this.tripId, required this.busId, required this.busRegistration, this.operatorContext});

  final String tripId;
  final String busId;
  final String busRegistration;
  final OperatorContext? operatorContext;

  @override
  ConsumerState<TripTrackingSection> createState() => _TripTrackingSectionState();
}

class _TripTrackingSectionState extends ConsumerState<TripTrackingSection> {
  late final TripOpsChannel _channel;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _channel = TripOpsChannel(
      ref.read(supabaseProvider),
      widget.tripId,
      () {
        if (mounted) ref.invalidate(tripTrackingProvider(widget.tripId));
      },
      topicSuffix: 'track',
      event: 'tracking',
    )..start();
    // Staleness depends on the clock, so re-read periodically even without a ping.
    _ticker = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) ref.invalidate(tripTrackingProvider(widget.tripId));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _channel.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tripTrackingProvider(widget.tripId));
    return async.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(message: 'Could not load tracking.', onRetry: () => ref.invalidate(tripTrackingProvider(widget.tripId))),
      data: (t) => _Body(info: t, busId: widget.busId, busRegistration: widget.busRegistration, operatorContext: widget.operatorContext),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.info, required this.busId, required this.busRegistration, required this.operatorContext});

  final TrackingInfo info;
  final String busId;
  final String busRegistration;
  final OperatorContext? operatorContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = info;
    final now = DateTime.now();
    final time = DateFormat('h:mm a');
    final route = ref.watch(busRouteProvider(busId)).value;

    final stops = <LatLng>[];
    if (route != null) {
      final pts = [
        for (final p in [...(route['boarding'] as List), ...(route['dropping'] as List)])
          if (p['latitude'] != null && p['longitude'] != null) (p['sequence_no'] as num, LatLng((p['latitude'] as num).toDouble(), (p['longitude'] as num).toDouble())),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      stops.addAll([for (final p in pts) p.$2]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(width: 12, height: 12, decoration: BoxDecoration(color: t.status.color, shape: BoxShape.circle)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(t.status.label, style: theme.textTheme.titleMedium)),
              ]),
              const SizedBox(height: AppSpacing.xs),
              Text(trackingExplanation(t), style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        if (t.hasPosition) ...[
          const SizedBox(height: AppSpacing.sm),
          _TrackingMap(info: t, stops: stops),
          const SizedBox(height: AppSpacing.sm),
        ] else
          const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Column(children: [
            _row(theme, 'Tracking source', t.sourceLabel),
            _row(theme, 'Last updated', t.recordedAt == null ? '—' : '${ageText(t.recordedAt, now)} · ${time.format(t.recordedAt!)}'),
            if (t.status.isEstimate && t.confidence != null) _row(theme, 'Confidence', '${(t.confidence! * 100).round()}%'),
            _row(theme, 'Vehicle', busRegistration),
            if (t.deviceActivation != null)
              _row(theme, 'GPS device', t.deviceActivation == 'active' ? (t.deviceConnection == 'online' ? 'Connected' : 'Active · ${t.deviceConnection?.replaceAll('_', ' ')}') : 'Awaiting activation'),
          ]),
        ),
        if (t.milestones.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('Route progress', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          for (final m in t.milestones.take(6))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(m.pointType == 'dropping' ? Icons.flag_outlined : Icons.trip_origin, size: 14),
                const SizedBox(width: 6),
                Expanded(child: Text('Reached ${m.pointName}', style: theme.textTheme.bodySmall)),
                Text(time.format(m.recordedAt), style: theme.textTheme.bodySmall),
              ]),
            ),
        ],
        if (t.status == TrackingStatus.notConfigured && (operatorContext?.isAdmin ?? false))
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: AppButton(
              label: 'Set up GPS tracking',
              icon: Icons.sensors,
              variant: AppButtonVariant.outline,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => GpsTrackingScreen(busId: busId, busRegistration: busRegistration, operatorContext: operatorContext!)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _row(ThemeData theme, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(label, style: theme.textTheme.bodySmall)),
          Expanded(child: Text(value)),
        ]),
      );
}

class _TrackingMap extends StatelessWidget {
  const _TrackingMap({required this.info, required this.stops});

  final TrackingInfo info;
  final List<LatLng> stops;

  @override
  Widget build(BuildContext context) {
    final t = info;
    final pos = LatLng(t.latitude!, t.longitude!);
    final color = t.status.color;
    final estimate = t.status.isEstimate;
    final live = t.status.isLive;

    // Confirmed live = solid bus marker; estimate = hollow marker + uncertainty circle; last known = grey hourglass.
    final marker = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: estimate ? Colors.white : color,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
      ),
      child: Icon(live ? Icons.directions_bus : (estimate ? Icons.help_outline : Icons.hourglass_empty), size: 22, color: estimate ? color : Colors.white),
    );

    return ClipRRect(
      borderRadius: AppRadius.lgRadius,
      child: SizedBox(
        height: 260,
        child: FlutterMap(
          options: MapOptions(initialCenter: pos, initialZoom: 13, interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate)),
          children: [
            TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.thirty8.operator_app'),
            if (stops.length >= 2) PolylineLayer(polylines: [Polyline(points: stops, strokeWidth: 3, color: const Color(0xFF6D28D9).withValues(alpha: 0.6))]),
            MarkerLayer(markers: [
              for (final s in stops) Marker(point: s, width: 10, height: 10, child: Container(decoration: BoxDecoration(color: const Color(0xFF6D28D9), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5)))),
            ]),
            if (estimate) CircleLayer(circles: [CircleMarker(point: pos, radius: 150, useRadiusInMeter: true, color: color.withValues(alpha: 0.15), borderColor: color, borderStrokeWidth: 1.5)]),
            MarkerLayer(markers: [Marker(point: pos, width: 40, height: 40, child: marker)]),
            const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
          ],
        ),
      ),
    );
  }
}
