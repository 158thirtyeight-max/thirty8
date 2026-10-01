import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'city.dart';

/// Active main route locations, in the order the admin set. The same table the
/// operator app and admin panel use.
final mainLocationsProvider = FutureProvider.autoDispose<List<City>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('main_locations')
      .select('id, name, state')
      .eq('is_active', true)
      .order('display_order');
  return [for (final r in rows) City.fromJson(Map<String, dynamic>.from(r as Map))];
});

/// Pickup / drop points actually served by buses between two main locations.
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
