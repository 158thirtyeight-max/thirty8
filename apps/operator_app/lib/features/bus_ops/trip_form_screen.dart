import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

/// Inserting into bus_trips is all this screen does — the
/// private.generate_trip_seats trigger populates trip_seats and
/// available_seats automatically from the bus's active seat layout.
class TripFormScreen extends ConsumerStatefulWidget {
  const TripFormScreen({super.key, required this.operatorId, required this.service});

  final String operatorId;
  final Map<String, dynamic> service;

  @override
  ConsumerState<TripFormScreen> createState() => _TripFormScreenState();
}

class _TripFormScreenState extends ConsumerState<TripFormScreen> {
  DateTime _travelDate = DateTime.now().add(const Duration(days: 1));
  final _minFareController = TextEditingController(text: '450');
  final _maxFareController = TextEditingController(text: '450');
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _minFareController.dispose();
    _maxFareController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final time = widget.service['default_departure_time'] as String;
      final parts = time.split(':');
      final departureAt = DateTime(_travelDate.year, _travelDate.month, _travelDate.day, int.parse(parts[0]), int.parse(parts[1]));
      final offsetMinutes = widget.service['default_arrival_offset_minutes'] as int;
      final arrivalAt = departureAt.add(Duration(minutes: offsetMinutes));

      final minFare = int.parse(_minFareController.text.trim()) * 100;
      final maxFare = int.parse(_maxFareController.text.trim()) * 100;

      await ref.read(supabaseProvider).from('bus_trips').insert({
        'service_id': widget.service['id'],
        'operator_id': widget.operatorId,
        'route_id': widget.service['route_id'],
        'bus_id': widget.service['bus_id'],
        'travel_date': DateFormat('yyyy-MM-dd').format(_travelDate),
        'departure_at': departureAt.toUtc().toIso8601String(),
        'arrival_at': arrivalAt.toUtc().toIso8601String(),
        'min_fare_cents': minFare,
        'max_fare_cents': maxFare,
        'live_tracking_enabled': true,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Could not schedule trip: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Schedule trip')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Travel date'),
                subtitle: Text(DateFormat('EEE, d MMM yyyy').format(_travelDate)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _travelDate,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 180)),
                  );
                  if (picked != null) setState(() => _travelDate = picked);
                },
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _minFareController,
                keyboardType: TextInputType.number,
                label: 'Fare (₹) — min',
              ),
              const SizedBox(height: 16),
              AppTextField(
                controller: _maxFareController,
                keyboardType: TextInputType.number,
                label: 'Fare (₹) — max',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              AppButton(
                label: 'Schedule trip',
                onPressed: _loading ? null : _save,
                loading: _loading,
                expand: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
