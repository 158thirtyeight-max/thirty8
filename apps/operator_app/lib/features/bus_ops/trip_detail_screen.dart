import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import '../tracking/tracking_models.dart';
import '../tracking/trip_tracking_section.dart';
import '../trip_dashboard/manifest_models.dart';
import '../trip_dashboard/manifest_pdf.dart';
import '../trip_dashboard/passenger_manifest_section.dart';
import '../earnings/earnings_models.dart';
import '../trip_dashboard/trip_booking_analytics_section.dart';
import '../trip_dashboard/trip_financial_section.dart';
import '../trip_dashboard/trip_ops_channel.dart';
import '../trip_dashboard/trip_seat_section.dart';
import 'qr_scanner_screen.dart';

final tripProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, tripId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase
      .from('bus_trips')
      .select(
        '*, bus:buses(registration_number, name), '
        'route:bus_routes(source:locations!bus_routes_source_city_id_fkey(name), destination:locations!bus_routes_destination_city_id_fkey(name))',
      )
      .eq('id', tripId)
      .single();
});

/// Trip Operations Dashboard: Overview · Seat Layout · Bookings · Trip Actions
/// (Financial Analytics and Tracking are added in their own phases).
class TripDetailScreen extends ConsumerStatefulWidget {
  const TripDetailScreen({super.key, required this.tripId, this.operatorContext});

  final String tripId;
  final OperatorContext? operatorContext;

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends ConsumerState<TripDetailScreen> {
  static const _statusFlow = ['scheduled', 'boarding', 'departed', 'arrived'];

  late final TripOpsChannel _ops;

  @override
  void initState() {
    super.initState();
    // Payments, refunds, bookings and boarding changes arrive as "something changed" pings.
    _ops = TripOpsChannel(ref.read(supabaseProvider), widget.tripId, () {
      if (!mounted) return;
      ref.invalidate(tripManifestProvider); // every filter/search of the manifest
      ref.invalidate(tripFinancialsProvider(widget.tripId));
      ref.invalidate(tripBookingStatsProvider(widget.tripId));
      ref.invalidate(tripBookingTrendProvider(widget.tripId));
      ref.invalidate(tripTrackingProvider(widget.tripId));
      ref.invalidate(tripProvider(widget.tripId));
    })
      ..start();
  }

  @override
  void dispose() {
    _ops.stop();
    super.dispose();
  }

  static String _statusError(Object e) {
    final msg = e is PostgrestException ? e.message : e.toString();
    if (msg.contains('trip_has_bookings')) {
      return 'This trip has passenger bookings, so it cannot be cancelled here. Contact support to cancel it and refund passengers.';
    }
    if (msg.contains('invalid_transition')) return 'That status change is not allowed from the current status.';
    if (msg.contains('Operator is not approved')) return 'Your operator account is not approved.';
    return 'Could not update status: $msg';
  }

  Future<void> _updateStatus(String newStatus) async {
    try {
      await ref.read(supabaseProvider).rpc('set_trip_status', params: {'p_trip_id': widget.tripId, 'p_status': newStatus});
      ref.invalidate(tripProvider(widget.tripId));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_statusError(e))));
    }
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  @override
  Widget build(BuildContext context) {
    final tripAsync = ref.watch(tripProvider(widget.tripId));
    final date = DateFormat('EEE, d MMM yyyy');
    final time = DateFormat('h:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trip details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan boarding tickets',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QrScannerScreen())),
          ),
        ],
      ),
      body: tripAsync.when(
        data: (trip) {
          final status = trip['status'] as String;
          final currentIndex = _statusFlow.indexOf(status);
          final nextStatus = status == 'cancelled' || currentIndex == _statusFlow.length - 1 ? null : _statusFlow[currentIndex + 1];
          final route = trip['route'] as Map<String, dynamic>?;
          final from = (route?['source'] as Map?)?['name'] ?? '—';
          final to = (route?['destination'] as Map?)?['name'] ?? '—';
          final bus = trip['bus'] as Map<String, dynamic>?;
          final dep = DateTime.parse(trip['departure_at'] as String).toLocal();
          final arrRaw = trip['arrival_at'] as String?;
          final arr = arrRaw == null ? null : DateTime.parse(arrRaw).toLocal();
          final canEditSeats = widget.operatorContext?.isAdmin ?? true;
          final canSeeMoney = widget.operatorContext?.isAdmin ?? false;

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(tripProvider(widget.tripId));
              ref.invalidate(tripManifestProvider);
              ref.invalidate(tripFinancialsProvider(widget.tripId));
              ref.invalidate(tripBookingStatsProvider(widget.tripId));
              ref.invalidate(tripBookingTrendProvider(widget.tripId));
            },
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                // 1. Overview
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(child: Text('$from → $to', style: Theme.of(context).textTheme.titleLarge)),
                        AppBadge(status: status),
                      ]),
                      const SizedBox(height: AppSpacing.xs),
                      Text('${bus?['registration_number'] ?? ''} · ${date.format(dep)}'),
                      Text('Departs ${time.format(dep)}${arr == null ? '' : ' · Arrives ${time.format(arr)}'}'),
                    ],
                  ),
                ),

                // 2. Seat layout
                _section('Seat layout'),
                TripSeatSection(tripId: widget.tripId, tripStatus: status, canEdit: canEditSeats),

                // 3. Bookings: analytics + passenger manifest
                _section('Bookings'),
                TripBookingAnalyticsSection(tripId: widget.tripId),
                _section('Passengers'),
                PassengerManifestSection(
                  tripId: widget.tripId,
                  operatorContext: widget.operatorContext,
                  tripStatus: status,
                  exportInfo: ManifestExportInfo(
                    routeLabel: '$from → $to',
                    busRegistration: (bus?['registration_number'] as String?) ?? '',
                    departureAt: dep,
                    operatorName: (widget.operatorContext?.operator['name'] as String?) ?? '',
                  ),
                ),

                // 4. Financial analytics (owner/admin only; the server enforces it too)
                if (canSeeMoney) ...[
                  _section('Financial analytics'),
                  TripFinancialSection(tripId: widget.tripId),
                ],

                // 5. Tracking (GPS tracker is the primary source)
                _section('Tracking'),
                TripTrackingSection(
                  tripId: widget.tripId,
                  busId: trip['bus_id'] as String,
                  busRegistration: (bus?['registration_number'] as String?) ?? '',
                  operatorContext: widget.operatorContext,
                ),

                // 6. Trip actions
                _section('Trip actions'),
                Row(
                  children: [
                    if (nextStatus != null)
                      Expanded(
                        child: AppButton(
                          label: 'Mark as ${nextStatus[0].toUpperCase()}${nextStatus.substring(1)}',
                          onPressed: () => _updateStatus(nextStatus),
                        ),
                      ),
                    if (status != 'cancelled' && status != 'arrived') ...[
                      const SizedBox(width: AppSpacing.sm),
                      AppButton(label: 'Cancel trip', variant: AppButtonVariant.outline, onPressed: () => _updateStatus('cancelled')),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          );
        },
        loading: () => const Center(child: AppLoadingState()),
        error: (e, st) => Center(
          child: AppErrorState(message: 'Could not load this trip.', onRetry: () => ref.invalidate(tripProvider(widget.tripId))),
        ),
      ),
    );
  }
}
