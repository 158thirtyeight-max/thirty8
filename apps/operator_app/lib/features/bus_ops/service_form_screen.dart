import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'fleet_list_screen.dart';
import 'routes_list_screen.dart';

class ServiceFormScreen extends ConsumerStatefulWidget {
  const ServiceFormScreen({super.key, required this.operatorId});

  final String operatorId;

  @override
  ConsumerState<ServiceFormScreen> createState() => _ServiceFormScreenState();
}

class _ServiceFormScreenState extends ConsumerState<ServiceFormScreen> {
  String? _routeId;
  String? _busId;
  TimeOfDay _departureTime = const TimeOfDay(hour: 8, minute: 0);
  final _arrivalOffsetController = TextEditingController(text: '240');
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _arrivalOffsetController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_routeId == null || _busId == null) {
      setState(() => _error = 'Pick a route and a bus');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final supabase = ref.read(supabaseProvider);
      final route = await supabase.from('bus_routes').select('source_city_id, destination_city_id').eq('id', _routeId!).single();

      final time = '${_departureTime.hour.toString().padLeft(2, '0')}:${_departureTime.minute.toString().padLeft(2, '0')}:00';
      final source = route['source_city_id'] as String;
      final dest = route['destination_city_id'] as String;

      await supabase.from('bus_services').insert({
        'operator_id': widget.operatorId,
        'route_id': _routeId,
        'bus_id': _busId,
        'service_name': 'Service',
        'service_source_city_id': source,
        'service_dest_city_id': dest,
        'default_departure_time': time,
        'default_arrival_offset_minutes': int.tryParse(_arrivalOffsetController.text.trim()) ?? 240,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Could not save service: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routesAsync = ref.watch(busRoutesProvider(widget.operatorId));
    final busesAsync = ref.watch(busesProvider(widget.operatorId));

    return Scaffold(
      appBar: AppBar(title: const Text('Add service')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              routesAsync.when(
                data: (routes) => DropdownButtonFormField<String>(
                  initialValue: _routeId,
                  decoration: const InputDecoration(labelText: 'Route'),
                  isExpanded: true,
                  items: routes
                      .map((r) => DropdownMenuItem(
                            value: r['id'] as String,
                            child: Text('${r['source']?['name']} → ${r['destination']?['name']}', overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _routeId = v),
                ),
                loading: () => const CircularProgressIndicator(),
                error: (e, st) => Text('Error loading routes: $e'),
              ),
              const SizedBox(height: 16),
              busesAsync.when(
                data: (buses) => DropdownButtonFormField<String>(
                  initialValue: _busId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Bus'),
                  items: buses.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['registration_number'] as String))).toList(),
                  onChanged: (v) => setState(() => _busId = v),
                ),
                loading: () => const CircularProgressIndicator(),
                error: (e, st) => Text('Error loading buses: $e'),
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Default departure time'),
                subtitle: Text(_departureTime.format(context)),
                trailing: const Icon(Icons.access_time),
                onTap: () async {
                  final picked = await showTimePicker(context: context, initialTime: _departureTime);
                  if (picked != null) setState(() => _departureTime = picked);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _arrivalOffsetController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Journey duration (minutes)'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _save,
                child: _loading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Save service'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
