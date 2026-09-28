import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'bus_form_screen.dart';

final busesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('buses').select().eq('operator_id', operatorId).order('created_at', ascending: false);
});

class FleetListScreen extends ConsumerWidget {
  const FleetListScreen({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final busesAsync = ref.watch(busesProvider(context.operatorId));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(busesProvider(context.operatorId)),
        child: busesAsync.when(
          data: (buses) => buses.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [AppEmptyState(message: 'No buses yet — add your first bus.', icon: Icons.directions_bus_outlined)],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: buses.length,
                  itemBuilder: (c, i) {
                    final bus = buses[i];
                    return AppCard(
                      padding: EdgeInsets.zero,
                      child: AppListItem(
                        leading: const Icon(Icons.directions_bus),
                        title: bus['registration_number'] as String,
                        subtitle: '${bus['bus_type']} · ${bus['total_seats']} seats · ${bus['status']}',
                      ),
                    );
                  },
                ),
          loading: () => const AppLoadingState(),
          error: (e, st) => AppErrorState(
            message: 'Could not load fleet: $e',
            onRetry: () => ref.invalidate(busesProvider(context.operatorId)),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.of(buildContext).push<bool>(
            MaterialPageRoute(builder: (_) => BusFormScreen(operatorId: context.operatorId)),
          );
          if (created == true) ref.invalidate(busesProvider(context.operatorId));
        },
        icon: const Icon(Icons.add),
        label: const Text('Add bus'),
      ),
    );
  }
}
