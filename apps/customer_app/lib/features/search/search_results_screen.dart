import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'bus_details_screen.dart';
import 'city.dart';
import 'main_locations_provider.dart';

class SearchResultsScreen extends ConsumerStatefulWidget {
  const SearchResultsScreen({super.key, required this.source, required this.destination, required this.date});

  final City source;
  final City destination;
  final DateTime date;

  @override
  ConsumerState<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends ConsumerState<SearchResultsScreen> {
  bool _loading = true;
  String? _pickupId;
  String? _dropId;
  String? _error;
  List<Map<String, dynamic>> _direct = [];
  List<Map<String, dynamic>> _connected = [];

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    try {
      final res = await ref.read(supabaseProvider).rpc('search_trips', params: {
        'p_source_city_id': widget.source.id,
        'p_destination_city_id': widget.destination.id,
        'p_travel_date': DateFormat('yyyy-MM-dd').format(widget.date),
        'p_pickup_point_id': _pickupId,
        'p_drop_point_id': _dropId,
      });
      if (!mounted) return;
      final map = res as Map<String, dynamic>;
      setState(() {
        _direct = List<Map<String, dynamic>>.from(map['direct'] as List? ?? []);
        _connected = List<Map<String, dynamic>>.from(map['connected'] as List? ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load results. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = ref.watch(journeyPointsProvider((
      source: widget.source.id,
      destination: widget.destination.id,
      date: DateFormat('yyyy-MM-dd').format(widget.date),
    ))).value;
    final pickups = points?['pickup'] ?? const <Map<String, dynamic>>[];
    final drops = points?['drop'] ?? const <Map<String, dynamic>>[];

    Widget filter(String label, List<Map<String, dynamic>> options, String? value, void Function(String?) onChanged) {
      return DropdownButtonFormField<String?>(
        key: ValueKey('$label-$value'),
        initialValue: options.any((o) => o['id'] == value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          DropdownMenuItem<String?>(value: null, child: Text('Any ${label.toLowerCase()}')),
          for (final o in options) DropdownMenuItem<String?>(value: o['id'] as String, child: Text(o['name'] as String, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: onChanged,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.source.name} → ${widget.destination.name}'),
      ),
      body: SafeArea(
        child: Builder(
          builder: (context) {
            if (_loading) return const AppLoadingState();
            if (_error != null) return AppErrorState(message: _error!, onRetry: _search);
            void changed(void Function() update) {
              setState(() {
                update();
                _loading = true;
              });
              _search();
            }

            final filters = (pickups.isNotEmpty || drops.isNotEmpty)
                ? Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: Column(
                      children: [
                        if (pickups.isNotEmpty) filter('Pickup point', pickups, _pickupId, (v) => changed(() => _pickupId = v)),
                        if (pickups.isNotEmpty && drops.isNotEmpty) const SizedBox(height: AppSpacing.sm),
                        if (drops.isNotEmpty) filter('Drop point', drops, _dropId, (v) => changed(() => _dropId = v)),
                      ],
                    ),
                  )
                : const SizedBox.shrink();
            if (_direct.isEmpty && _connected.isEmpty) {
              return ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  filters,
                  const AppEmptyState(message: 'No buses found for this route on this date', icon: Icons.directions_bus_filled_outlined),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                filters,
                if (_direct.isNotEmpty) ...[
                  AppSectionHeader(title: 'Direct'),
                  ..._direct.map((t) => _DirectTripCard(
                        trip: t,
                        sourceCityId: widget.source.id,
                        destinationCityId: widget.destination.id,
                        pickupPointId: _pickupId,
                        dropPointId: _dropId,
                      )),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (_connected.isNotEmpty) ...[
                  AppSectionHeader(title: 'With a change'),
                  ..._connected.map((c) => _ConnectedTripCard(connection: c)),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

String _time(String iso) => DateFormat('h:mm a').format(DateTime.parse(iso).toLocal());

class _DirectTripCard extends StatelessWidget {
  const _DirectTripCard({required this.trip, required this.sourceCityId, required this.destinationCityId, this.pickupPointId, this.dropPointId});

  final Map<String, dynamic> trip;
  final String sourceCityId;
  final String destinationCityId;
  final String? pickupPointId;
  final String? dropPointId;

  @override
  Widget build(BuildContext context) {
    final fare = ((trip['min_fare_cents'] as int?) ?? 0) / 100;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(trip['operator_name'] as String? ?? 'Operator', style: Theme.of(context).textTheme.titleSmall),
              Text('₹${fare.toStringAsFixed(0)}', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text((trip['bus_type'] as String? ?? '').replaceAll('_', ' ').toUpperCase(), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Text(_time(trip['departure_at'] as String), style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(child: Divider()),
              const SizedBox(width: AppSpacing.sm),
              Text('${trip['available_seats']} seats left', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(child: Divider()),
              const SizedBox(width: AppSpacing.sm),
              Text(_time(trip['arrival_at'] as String), style: Theme.of(context).textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Select seats',
            variant: AppButtonVariant.outline,
            expand: true,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BusDetailsScreen(
                    trip: trip,
                    sourceCityId: sourceCityId,
                    destinationCityId: destinationCityId,
                    pickupPointId: pickupPointId,
                    dropPointId: dropPointId,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ConnectedTripCard extends StatelessWidget {
  const _ConnectedTripCard({required this.connection});

  final Map<String, dynamic> connection;

  @override
  Widget build(BuildContext context) {
    final leg1 = connection['leg1'] as Map<String, dynamic>;
    final leg2 = connection['leg2'] as Map<String, dynamic>;
    final total = ((connection['total_min_fare_cents'] as int?) ?? 0) / 100;

    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Change required', style: textTheme.titleSmall),
              Text('₹${total.toStringAsFixed(0)}', style: textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('${leg1['operator_name']} · ${_time(leg1['departure_at'] as String)} → ${_time(leg1['arrival_at'] as String)}'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(children: [
              const Icon(Icons.swap_horiz, size: 16, color: AppColors.textTertiary),
              const SizedBox(width: AppSpacing.xs),
              Text('Change buses', style: textTheme.bodySmall?.copyWith(color: AppColors.textTertiary)),
            ]),
          ),
          Text('${leg2['operator_name']} · ${_time(leg2['departure_at'] as String)} → ${_time(leg2['arrival_at'] as String)}'),
        ],
      ),
    );
  }
}
