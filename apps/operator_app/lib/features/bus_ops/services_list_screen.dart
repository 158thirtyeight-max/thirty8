import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'service_form_screen.dart';
import 'trip_detail_screen.dart';
import 'trip_form_screen.dart';

final busServicesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase
      .from('bus_services')
      .select('*, source:cities!bus_services_service_source_city_id_fkey(name), destination:cities!bus_services_service_dest_city_id_fkey(name)')
      .eq('operator_id', operatorId)
      .order('created_at', ascending: false);
});

final tripsForServiceProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, serviceId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('bus_trips').select().eq('service_id', serviceId).order('departure_at', ascending: false).limit(20);
});

class ServicesListScreen extends ConsumerWidget {
  const ServicesListScreen({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final servicesAsync = ref.watch(busServicesProvider(context.operatorId));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(busServicesProvider(context.operatorId)),
        child: servicesAsync.when(
          data: (services) => services.isEmpty
              ? ListView(children: const [
                  Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No services yet — add a route + bus first, then create a service.'))),
                ])
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: services.length,
                  itemBuilder: (c, i) {
                    final service = services[i];
                    final source = service['source']?['name'] as String? ?? '?';
                    final dest = service['destination']?['name'] as String? ?? '?';
                    return _ServiceCard(
                      service: service,
                      title: '$source → $dest',
                      operatorId: context.operatorId,
                    );
                  },
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, st) => Center(child: Text('Could not load services: $e')),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.of(buildContext).push<bool>(
            MaterialPageRoute(builder: (_) => ServiceFormScreen(operatorId: context.operatorId)),
          );
          if (created == true) ref.invalidate(busServicesProvider(context.operatorId));
        },
        icon: const Icon(Icons.add),
        label: const Text('Add service'),
      ),
    );
  }
}

class _ServiceCard extends ConsumerStatefulWidget {
  const _ServiceCard({required this.service, required this.title, required this.operatorId});

  final Map<String, dynamic> service;
  final String title;
  final String operatorId;

  @override
  ConsumerState<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends ConsumerState<_ServiceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final serviceId = widget.service['id'] as String;
    final tripsAsync = _expanded ? ref.watch(tripsForServiceProvider(serviceId)) : null;
    final fmt = DateFormat('EEE, d MMM · h:mm a');

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.route),
            title: Text(widget.title),
            subtitle: Text('${widget.service['default_departure_time']} · ${widget.service['status']}'),
            trailing: IconButton(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  tripsAsync!.when(
                    data: (trips) => trips.isEmpty
                        ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No trips scheduled yet'))
                        : Column(
                            children: trips
                                .map((t) => ListTile(
                                      dense: true,
                                      title: Text(fmt.format(DateTime.parse(t['departure_at'] as String).toLocal())),
                                      subtitle: Text('${t['available_seats']} seats left · ${t['status']}'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(builder: (_) => TripDetailScreen(tripId: t['id'] as String)),
                                      ),
                                    ))
                                .toList(),
                          ),
                    loading: () => const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()),
                    error: (e, st) => Text('Error: $e'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Schedule a trip'),
                    onPressed: () async {
                      final created = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => TripFormScreen(operatorId: widget.operatorId, service: widget.service)),
                      );
                      if (created == true) ref.invalidate(tripsForServiceProvider(serviceId));
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
