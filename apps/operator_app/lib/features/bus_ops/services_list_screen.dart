import 'package:design_system/design_system.dart';
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
  // Upcoming departures only — the backend generates these automatically.
  return await supabase
      .from('bus_trips')
      .select()
      .eq('service_id', serviceId)
      .gte('departure_at', DateTime.now().toUtc().toIso8601String())
      .order('departure_at', ascending: true)
      .limit(30);
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
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    AppEmptyState(message: 'No schedules yet — add a route + bus first, then set up a recurring schedule.', icon: Icons.route_outlined),
                  ],
                )
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
          loading: () => const AppLoadingState(),
          error: (e, st) => AppErrorState(
            message: 'Could not load services: $e',
            onRetry: () => ref.invalidate(busServicesProvider(context.operatorId)),
          ),
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
        label: const Text('Add schedule'),
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

  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String _departureLabel() => (widget.service['default_departure_time'] as String).substring(0, 5);

  String _daysLabel() {
    final days = ((widget.service['operating_days'] as List<dynamic>?) ?? const [1, 2, 3, 4, 5, 6, 7]).map((e) => (e as num).toInt()).toList()..sort();
    return days.length == 7 ? 'Daily' : days.map((d) => _dayLabels[d - 1]).join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final serviceId = widget.service['id'] as String;
    final tripsAsync = _expanded ? ref.watch(tripsForServiceProvider(serviceId)) : null;
    final fmt = DateFormat('EEE, d MMM · h:mm a');

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          AppListItem(
            leading: const Icon(Icons.route),
            title: widget.title,
            subtitle: '${_departureLabel()} · ${_daysLabel()} · ${widget.service['status']}',
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
                        ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No upcoming departures — they are generated automatically while the schedule is active'))
                        : Column(
                            children: trips
                                .map((t) => AppListItem(
                                      title: fmt.format(DateTime.parse(t['departure_at'] as String).toLocal()),
                                      subtitle: '${t['available_seats']} seats left · ${t['status']}',
                                      onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(builder: (_) => TripDetailScreen(tripId: t['id'] as String)),
                                      ),
                                    ))
                                .toList(),
                          ),
                    loading: () => const Padding(padding: EdgeInsets.all(8), child: AppLoadingState()),
                    error: (e, st) => Text('Error: $e'),
                  ),
                  const SizedBox(height: 8),
                  AppButton(
                    label: 'Edit recurring schedule',
                    icon: Icons.edit_calendar,
                    onPressed: () async {
                      final saved = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => ServiceFormScreen(operatorId: widget.operatorId, service: widget.service)),
                      );
                      if (saved == true) {
                        ref.invalidate(busServicesProvider(widget.operatorId));
                        ref.invalidate(tripsForServiceProvider(serviceId));
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  // One-off special departures only; recurring departures are never added by hand.
                  AppButton(
                    label: 'Add special departure (one-off)',
                    icon: Icons.add,
                    variant: AppButtonVariant.outline,
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
