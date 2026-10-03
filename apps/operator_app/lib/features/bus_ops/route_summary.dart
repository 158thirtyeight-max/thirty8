import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

/// What the Routes tab shows for one bus: the live (approved) route plus the state of any
/// pending or draft change. The live route is never touched until an admin approves a change.
class RouteSummary {
  RouteSummary({
    required this.busId,
    required this.busLabel,
    required this.routeName,
    required this.source,
    required this.destination,
    required this.intermediateStops,
    required this.tripType,
    required this.routeStatus,
    required this.approvalStatus,
    required this.lastUpdated,
    required this.activeRevisionId,
    required this.openRevisionId,
    required this.openRevisionStatus,
    required this.rejectedRevisionId,
    required this.rejectionReason,
    required this.bus,
    this.liveRouteId,
    this.operatingDays,
  });

  final String busId;
  final String busLabel;
  final String routeName;
  final String? source;
  final String? destination;
  final int? intermediateStops;

  /// 'one_way' or 'round_trip'.
  final String tripType;

  /// 'Live', 'Set up (not live yet)' or 'Not configured'.
  final String routeStatus;

  /// 'approved', 'pending' (awaiting admin approval), 'draft' (unsubmitted changes) or 'rejected'.
  final String approvalStatus;
  final DateTime? lastUpdated;
  final String? activeRevisionId;
  final String? openRevisionId;
  final String? openRevisionStatus;
  final String? rejectedRevisionId;
  final String? rejectionReason;
  final Map<String, dynamic> bus;

  /// The live outbound bus_routes row (for buses set up before route revisions existed).
  final String? liveRouteId;

  /// ISO weekdays (1 = Monday) the outbound journey runs, from the active revision.
  final Set<int>? operatingDays;

  bool get isRoundTrip => tripType == 'round_trip';
  bool get hasDraft => openRevisionStatus == 'draft';
  bool get isPending => openRevisionStatus == 'pending_approval';
  bool get hasLiveRoute => routeStatus != 'Not configured';
}

DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();

/// Merges buses, live routes and route revisions into one summary per bus. Pure, so it is unit tested.
List<RouteSummary> buildRouteSummaries({
  required List<Map<String, dynamic>> buses,
  required List<Map<String, dynamic>> routes,
  required List<Map<String, dynamic>> revisions,
}) {
  final out = <RouteSummary>[];
  for (final bus in buses) {
    final busId = bus['id'] as String;
    final busRoutes = routes.where((r) => r['bus_id'] == busId && r['active'] != false).toList();
    final outbound = busRoutes.where((r) => r['direction'] != 'return').firstOrNull;
    final hasReturn = busRoutes.any((r) => r['direction'] == 'return');
    final revs = revisions.where((r) => r['bus_id'] == busId).toList()
      ..sort((a, b) => (b['revision_no'] as int).compareTo(a['revision_no'] as int));
    final open = revs.where((r) => r['status'] == 'draft' || r['status'] == 'pending_approval').firstOrNull;
    final activeId = bus['active_route_revision_id'] as String?;
    final active = activeId == null ? null : revs.where((r) => r['id'] == activeId).firstOrNull;
    if (outbound == null && open == null) continue; // nothing configured for this bus yet

    // A rejection stays visible until a newer revision replaces it.
    final latestDecided = revs.where((r) => r['status'] != 'draft' && r['status'] != 'pending_approval' && r['status'] != 'withdrawn').firstOrNull;
    final rejected = (open == null && latestDecided != null && latestDecided['status'] == 'rejected') ? latestDecided : null;

    int? intermediate;
    Set<int>? days;
    if (active != null) {
      final aj = List<Map<String, dynamic>>.from((active['route_revision_journeys'] as List?) ?? const []).where((x) => x['direction'] == 'outbound').firstOrNull;
      final raw = aj?['operating_days'];
      if (raw is List) days = {for (final d in raw) (d as num).toInt()};
      final journeys = List<Map<String, dynamic>>.from((active['route_revision_journeys'] as List?) ?? const []);
      final j = journeys.where((x) => x['direction'] == 'outbound').firstOrNull;
      final stops = j == null ? null : (j['route_revision_stops'] as List?)?.firstOrNull;
      final count = stops is Map ? stops['count'] as int? : null;
      if (count != null) intermediate = (count - 2).clamp(0, 1000);
    }

    final source = (outbound?['source'] as Map?)?['name'] as String?;
    final destination = (outbound?['destination'] as Map?)?['name'] as String?;
    final lifecycle = bus['lifecycle_status'] as String?;
    final name = (bus['name'] as String?)?.trim();
    final reg = bus['registration_number'] as String? ?? '';

    out.add(RouteSummary(
      busId: busId,
      busLabel: (name == null || name.isEmpty) ? reg : '$name · $reg',
      routeName: (active?['name'] as String?) ?? (source != null && destination != null ? '$source to $destination' : (open?['name'] as String?) ?? 'Route'),
      source: source,
      destination: destination,
      intermediateStops: intermediate,
      tripType: hasReturn ? 'round_trip' : 'one_way',
      routeStatus: outbound == null ? 'Not configured' : (lifecycle == 'active' ? 'Live' : 'Set up (not live yet)'),
      approvalStatus: open != null ? (open['status'] == 'pending_approval' ? 'pending' : 'draft') : (rejected != null ? 'rejected' : 'approved'),
      lastUpdated: _date(active?['reviewed_at'] ?? active?['submitted_at'] ?? active?['updated_at'] ?? outbound?['created_at']),
      activeRevisionId: activeId,
      openRevisionId: open?['id'] as String?,
      openRevisionStatus: open?['status'] as String?,
      rejectedRevisionId: rejected?['id'] as String?,
      rejectionReason: rejected?['rejection_reason'] as String?,
      bus: bus,
      liveRouteId: outbound?['id'] as String?,
      operatingDays: days,
    ));
  }
  return out;
}

final operatorRouteSummariesProvider = FutureProvider.autoDispose.family<List<RouteSummary>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  final results = await Future.wait([
    supabase
        .from('buses')
        .select('id, name, registration_number, lifecycle_status, is_legacy, active_route_revision_id')
        .eq('operator_id', operatorId)
        .order('created_at', ascending: false),
    supabase
        .from('bus_routes')
        .select('id, bus_id, direction, active, created_at, source:locations!bus_routes_source_city_id_fkey(name), destination:locations!bus_routes_destination_city_id_fkey(name)')
        .eq('operator_id', operatorId)
        .not('bus_id', 'is', null),
    supabase
        .from('route_revisions')
        .select('id, bus_id, revision_no, status, trip_type, name, change_reason, rejection_reason, submitted_at, reviewed_at, updated_at, route_revision_journeys(direction, operating_days, route_revision_stops(count))')
        .eq('operator_id', operatorId),
  ]);
  return buildRouteSummaries(
    buses: List<Map<String, dynamic>>.from(results[0]),
    routes: List<Map<String, dynamic>>.from(results[1]),
    revisions: List<Map<String, dynamic>>.from(results[2]),
  );
});

/// A revision with its journeys and stops (each stop carries `location: {name}`).
final routeRevisionDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, revisionId) async {
  return await ref
      .watch(supabaseProvider)
      .from('route_revisions')
      .select('*, route_revision_journeys(*, route_revision_stops(*, location:locations(name)))')
      .eq('id', revisionId)
      .single();
});

/// Every revision of a bus, newest first (history), with origin (operator / admin / route_copy), the
/// revision it replaced, who was responsible and its events. Comes from get_route_history.
final busRevisionsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, busId) async {
  final rows = await ref.watch(supabaseProvider).rpc('get_route_history', params: {'p_bus_id': busId});
  return List<Map<String, dynamic>>.from(rows as List);
});
