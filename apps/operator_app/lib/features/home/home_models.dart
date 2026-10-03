import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

int _i(Object? v) => (v as num?)?.toInt() ?? 0;

@immutable
class HomeTrip {
  const HomeTrip({
    required this.id,
    required this.routeLabel,
    required this.busRegistration,
    required this.departureAt,
    required this.status,
    required this.soldSeats,
    required this.totalSeats,
  });

  final String id;
  final String routeLabel;
  final String busRegistration;
  final DateTime departureAt;
  final String status;
  final int soldSeats;
  final int totalSeats;

  factory HomeTrip.fromJson(Map<String, dynamic> j) => HomeTrip(
        id: j['id'] as String,
        routeLabel: '${j['source_name'] ?? '—'} → ${j['destination_name'] ?? '—'}',
        busRegistration: (j['bus_registration'] as String?) ?? '',
        departureAt: DateTime.parse(j['departure_at'] as String).toLocal(),
        status: j['status'] as String,
        soldSeats: _i(j['sold_seats']),
        totalSeats: _i(j['total_seats']),
      );
}

/// What Home shows for the Bus service. Money fields are null for staff who may not see them.
@immutable
class HomeSummary {
  const HomeSummary({
    required this.todaysTrips,
    required this.activeTrips,
    required this.ticketsSoldToday,
    required this.today,
    required this.upcoming,
    required this.financialsVisible,
    this.todaysTicketSalesCents,
    this.pendingPayoutCents,
  });

  final int todaysTrips;
  final int activeTrips;
  final int ticketsSoldToday;
  final int? todaysTicketSalesCents;
  final int? pendingPayoutCents;
  final bool financialsVisible;
  final List<HomeTrip> today;
  final List<HomeTrip> upcoming;

  /// Nothing scheduled today or soon.
  bool get isQuiet => todaysTrips == 0 && activeTrips == 0 && upcoming.isEmpty;

  factory HomeSummary.fromJson(Map<String, dynamic> j) => HomeSummary(
        todaysTrips: _i(j['todays_trips']),
        activeTrips: _i(j['active_trips']),
        ticketsSoldToday: _i(j['tickets_sold_today']),
        todaysTicketSalesCents: (j['todays_ticket_sales_cents'] as num?)?.toInt(),
        pendingPayoutCents: (j['pending_payout_cents'] as num?)?.toInt(),
        financialsVisible: j['financials_visible'] == true,
        today: [for (final t in (j['today'] as List? ?? const [])) HomeTrip.fromJson(Map<String, dynamic>.from(t as Map))],
        upcoming: [for (final t in (j['upcoming'] as List? ?? const [])) HomeTrip.fromJson(Map<String, dynamic>.from(t as Map))],
      );
}

final homeSummaryProvider = FutureProvider.autoDispose.family<HomeSummary, String>((ref, operatorId) async {
  final res = await ref.watch(supabaseProvider).rpc('get_operator_home_summary', params: {'p_operator_id': operatorId});
  return HomeSummary.fromJson(Map<String, dynamic>.from(res as Map));
});

@immutable
class CargoHomeStats {
  const CargoHomeStats({required this.awaitingAcceptance, required this.inTransit});

  final int awaitingAcceptance;
  final int inTransit;
}

final cargoHomeStatsProvider = FutureProvider.autoDispose.family<CargoHomeStats, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  final pending = await supabase.from('cargo_shipments').select('id').eq('operator_id', operatorId).eq('status', 'confirmed').count();
  final transit = await supabase
      .from('cargo_shipments')
      .select('id')
      .eq('operator_id', operatorId)
      .inFilter('status', ['picked_up', 'in_transit', 'arrived_at_hub', 'out_for_delivery']).count();
  return CargoHomeStats(awaitingAcceptance: pending.count, inTransit: transit.count);
});
