import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'route_form_screen.dart';
import 'route_points_screen.dart';

final busRoutesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase
      .from('bus_routes')
      .select('*, source:cities!bus_routes_source_city_id_fkey(name), destination:cities!bus_routes_destination_city_id_fkey(name)')
      .eq('operator_id', operatorId)
      .order('created_at', ascending: false);
});

class RoutesListScreen extends ConsumerWidget {
  const RoutesListScreen({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final routesAsync = ref.watch(busRoutesProvider(context.operatorId));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(busRoutesProvider(context.operatorId)),
        child: routesAsync.when(
          data: (routes) => routes.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [AppEmptyState(message: 'No routes yet — add your first route.', icon: Icons.alt_route)],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: routes.length,
                  itemBuilder: (c, i) {
                    final route = routes[i];
                    final source = route['source']?['name'] as String? ?? '?';
                    final dest = route['destination']?['name'] as String? ?? '?';
                    return AppCard(
                      padding: EdgeInsets.zero,
                      child: AppListItem(
                        leading: const Icon(Icons.alt_route),
                        title: '$source → $dest',
                        subtitle: route['distance_km'] != null ? '${route['distance_km']} km' : 'Distance not set',
                        onTap: () => Navigator.of(buildContext).push(
                          MaterialPageRoute(builder: (_) => RoutePointsScreen(routeId: route['id'] as String, routeLabel: '$source → $dest')),
                        ),
                      ),
                    );
                  },
                ),
          loading: () => const AppLoadingState(),
          error: (e, st) => AppErrorState(
            message: 'Could not load routes: $e',
            onRetry: () => ref.invalidate(busRoutesProvider(context.operatorId)),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.of(buildContext).push<bool>(
            MaterialPageRoute(builder: (_) => RouteFormScreen(operatorId: context.operatorId)),
          );
          if (created == true) ref.invalidate(busRoutesProvider(context.operatorId));
        },
        icon: const Icon(Icons.add),
        label: const Text('Add route'),
      ),
    );
  }
}
