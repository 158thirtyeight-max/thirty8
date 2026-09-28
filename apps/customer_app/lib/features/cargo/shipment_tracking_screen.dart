import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

class ShipmentTrackingScreen extends ConsumerStatefulWidget {
  const ShipmentTrackingScreen({super.key, required this.shipmentId});

  final String shipmentId;

  @override
  ConsumerState<ShipmentTrackingScreen> createState() => _ShipmentTrackingScreenState();
}

class _ShipmentTrackingScreenState extends ConsumerState<ShipmentTrackingScreen> {
  bool _loading = true;
  Map<String, dynamic>? _data;
  Timer? _timer;

  static const _statusOrder = ['confirmed', 'picked_up', 'in_transit', 'arrived_at_hub', 'out_for_delivery', 'delivered'];

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(supabaseProvider).rpc('track_cargo_shipment', params: {'p_shipment_id': widget.shipmentId});
      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Track shipment')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _data == null
              ? const Center(child: Text('Tracking is not available.'))
              : SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _StatusStepper(status: _data!['status'] as String, statusOrder: _statusOrder),
                      const SizedBox(height: 16),
                      if (_data!['current_latitude'] != null)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.gps_fixed),
                            title: Text('${_data!['current_latitude']}, ${_data!['current_longitude']}'),
                            subtitle: _data!['last_location_update'] != null
                                ? Text('Updated ${DateFormat('h:mm a').format(DateTime.parse(_data!['last_location_update'] as String).toLocal())}')
                                : null,
                          ),
                        ),
                      const SizedBox(height: 16),
                      Text('Timeline', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 8),
                      ...List<Map<String, dynamic>>.from(_data!['status_history'] as List).map((h) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.check_circle_outline, size: 20),
                            title: Text((h['to_status'] as String).replaceAll('_', ' ')),
                            subtitle: Text(DateFormat('d MMM, h:mm a').format(DateTime.parse(h['created_at'] as String).toLocal())),
                          )),
                    ],
                  ),
                ),
    );
  }
}

class _StatusStepper extends StatelessWidget {
  const _StatusStepper({required this.status, required this.statusOrder});

  final String status;
  final List<String> statusOrder;

  @override
  Widget build(BuildContext context) {
    if (status == 'cancelled' || status == 'failed') {
      return Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Shipment ${status == 'cancelled' ? 'cancelled' : 'failed'}', style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      );
    }

    final currentIndex = statusOrder.indexOf(status);
    return Row(
      children: List.generate(statusOrder.length, (i) {
        final reached = i <= currentIndex;
        return Expanded(
          child: Column(
            children: [
              CircleAvatar(
                radius: 10,
                backgroundColor: reached ? Theme.of(context).colorScheme.primary : Colors.grey.shade300,
                child: reached ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
              ),
              const SizedBox(height: 4),
              Text(
                statusOrder[i].replaceAll('_', ' '),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: reached ? Theme.of(context).colorScheme.primary : Colors.grey),
              ),
            ],
          ),
        );
      }),
    );
  }
}
