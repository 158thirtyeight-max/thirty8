import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'city.dart';

/// Main-route locations (active, enabled for the Main Route page) in the order the admin set.
/// The same locations table the operator app and admin panel use.
final mainLocationsProvider = FutureProvider.autoDispose<List<City>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('locations')
      .select('id, name, state')
      .eq('is_active', true)
      .eq('is_main_route_enabled', true)
      .order('main_route_order');
  return [for (final r in rows) City.fromJson(Map<String, dynamic>.from(r as Map))];
});

/// Pickup / drop locations the running buses actually serve between two main locations
/// (each with id, location_code, name, port_name), already filtered by the admin's pickup / drop flags.
final journeyPointsProvider = FutureProvider.autoDispose.family<Map<String, List<Map<String, dynamic>>>, ({String source, String destination, String date})>((ref, q) async {
  final res = await ref.watch(supabaseProvider).rpc('get_journey_points', params: {
    'p_source_city_id': q.source,
    'p_destination_city_id': q.destination,
    'p_travel_date': q.date,
  });
  final map = Map<String, dynamic>.from(res as Map);
  return {
    'pickup': List<Map<String, dynamic>>.from(map['pickup'] as List? ?? const []),
    'drop': List<Map<String, dynamic>>.from(map['drop'] as List? ?? const []),
  };
});
