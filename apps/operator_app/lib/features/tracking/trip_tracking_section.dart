import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:route_map/route_map.dart' show TripMapCard;

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import '../trip_dashboard/trip_ops_channel.dart';
import 'gps_tracking_screen.dart';
import 'phone_location_card.dart';
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
  late final TripPing _channel;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _channel = ref.read(tripPingFactoryProvider)(
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
      data: (t) => _Body(tripId: widget.tripId, info: t, busId: widget.busId, busRegistration: widget.busRegistration, operatorContext: widget.operatorContext),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.tripId, required this.info, required this.busId, required this.busRegistration, required this.operatorContext});

  final String tripId;
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
        const SizedBox(height: AppSpacing.sm),
        TripMapCard(
          client: ref.read(supabaseProvider),
          tripId: tripId,
          showTripStatus: true,
          buildGeometry: (routeId) async {
            await ref.read(supabaseProvider).functions.invoke('route-geometry', body: {'route_id': routeId});
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        PhoneLocationCard(tripId: tripId, tripStatus: t.tripStatus),
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
