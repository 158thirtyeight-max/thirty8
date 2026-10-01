import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import '../search/city.dart';
import '../search/main_locations_provider.dart';

/// Active routes defined by the admin (route catalog), shown as quick picks.
final popularRoutesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('route_templates')
      .select('id, name, source:cities!route_templates_source_city_id_fkey(id, name, state), destination:cities!route_templates_destination_city_id_fkey(id, name, state)')
      .eq('is_active', true)
      .order('name');
  return List<Map<String, dynamic>>.from(rows);
});

class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});

  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> {
  City? _source;
  City? _destination;
  DateTime _date = DateTime.now();

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 120)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _swap() {
    setState(() {
      final tmp = _source;
      _source = _destination;
      _destination = tmp;
    });
  }

  void _search() {
    if (_source == null || _destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose where you’re leaving from and going to')),
      );
      return;
    }
    if (_source!.id == _destination!.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Source and destination can’t be the same')),
      );
      return;
    }
    context.push('/search-results', extra: {
      'source': _source,
      'destination': _destination,
      'date': _date,
    });
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = DateFormat('EEE, d MMM').format(_date);
    final locationsAsync = ref.watch(mainLocationsProvider);
    final locations = locationsAsync.value ?? const <City>[];

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AppLogoLockup(markSize: 26),
          const SizedBox(height: 4),
          Text('Where are you headed?', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 20),
          if (locationsAsync.hasError)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppErrorState(message: 'Could not load locations.', onRetry: () => ref.invalidate(mainLocationsProvider)),
            ),
          AppCard(
            child: Column(
              children: [
                _LocationDropdown(
                  icon: Icons.trip_origin,
                  label: 'From',
                  locations: locations,
                  value: _source,
                  onChanged: (c) => setState(() => _source = c),
                ),
                const Divider(height: 24),
                Stack(
                  alignment: Alignment.centerRight,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 48),
                      child: _LocationDropdown(
                        icon: Icons.location_on,
                        label: 'Going to',
                        locations: locations,
                        value: _destination,
                        onChanged: (c) => setState(() => _destination = c),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.swap_vert),
                      onPressed: _swap,
                      tooltip: 'Swap',
                    ),
                  ],
                ),
                const Divider(height: 24),
                _PickerRow(
                  icon: Icons.calendar_today_outlined,
                  label: dateLabel,
                  onTap: _pickDate,
                ),
                const SizedBox(height: 16),
                AppButton(
                  label: 'Search buses',
                  onPressed: _search,
                  icon: Icons.search,
                  expand: true,
                ),
              ],
            ),
          ),
          ref.watch(popularRoutesProvider).maybeWhen(
                data: (routes) => routes.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 24),
                          Text('Popular routes', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final r in routes)
                                ActionChip(
                                  label: Text(r['name'] as String),
                                  onPressed: () => setState(() {
                                    _source = City.fromJson(Map<String, dynamic>.from(r['source'] as Map));
                                    _destination = City.fromJson(Map<String, dynamic>.from(r['destination'] as Map));
                                  }),
                                ),
                            ],
                          ),
                        ],
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
        ],
      ),
    );
  }
}

/// From / Going to dropdown fed by the shared main_locations table (admin order, active only).
class _LocationDropdown extends StatelessWidget {
  const _LocationDropdown({required this.icon, required this.label, required this.locations, required this.value, required this.onChanged});

  final IconData icon;
  final String label;
  final List<City> locations;
  final City? value;
  final ValueChanged<City?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey('$label-${value?.id}-${locations.length}'),
      initialValue: locations.any((c) => c.id == value?.id) ? value!.id : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Theme.of(context).colorScheme.primary),
      ),
      items: [for (final c in locations) DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))],
      onChanged: (id) => onChanged(id == null ? null : locations.firstWhere((c) => c.id == id)),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.smRadius,
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
