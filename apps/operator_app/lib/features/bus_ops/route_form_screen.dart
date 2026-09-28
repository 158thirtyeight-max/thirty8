import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

final citiesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('cities').select('id, name, state').eq('is_active', true).order('name');
});

class RouteFormScreen extends ConsumerStatefulWidget {
  const RouteFormScreen({super.key, required this.operatorId});

  final String operatorId;

  @override
  ConsumerState<RouteFormScreen> createState() => _RouteFormScreenState();
}

class _RouteFormScreenState extends ConsumerState<RouteFormScreen> {
  String? _sourceCityId;
  String? _destinationCityId;
  final _distanceController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _distanceController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_sourceCityId == null || _destinationCityId == null) {
      setState(() => _error = 'Pick both cities');
      return;
    }
    if (_sourceCityId == _destinationCityId) {
      setState(() => _error = 'Source and destination must differ');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).from('bus_routes').insert({
        'operator_id': widget.operatorId,
        'source_city_id': _sourceCityId,
        'destination_city_id': _destinationCityId,
        'distance_km': double.tryParse(_distanceController.text.trim()),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Could not save route: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final citiesAsync = ref.watch(citiesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Add route')),
      body: SafeArea(
        child: citiesAsync.when(
          data: (cities) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _sourceCityId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Origin city'),
                  items: cities.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String, overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (v) => setState(() => _sourceCityId = v),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _destinationCityId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Destination city'),
                  items: cities.map((c) => DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String, overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (v) => setState(() => _destinationCityId = v),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _distanceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Distance (km, optional)'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                AppButton(
                  label: 'Save route',
                  onPressed: _loading ? null : _save,
                  loading: _loading,
                  expand: true,
                ),
              ],
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, st) => Center(child: Text('Could not load cities: $e')),
        ),
      ),
    );
  }
}
