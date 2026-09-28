import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'new_shipment_screen.dart';
import 'shipment_detail_screen.dart';

class CargoTab extends ConsumerStatefulWidget {
  const CargoTab({super.key});

  @override
  ConsumerState<CargoTab> createState() => _CargoTabState();
}

class _CargoTabState extends ConsumerState<CargoTab> {
  List<Map<String, dynamic>> _shipments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = ref.read(currentUserProvider)?.id;
    if (userId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final res = await ref
          .read(supabaseProvider)
          .from('cargo_shipments')
          .select()
          .eq('sender_user_id', userId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _shipments = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'delivered':
        return Colors.green;
      case 'cancelled':
      case 'failed':
        return Colors.red;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ElevatedButton.icon(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewShipmentScreen()));
                _load();
              },
              icon: const Icon(Icons.add),
              label: const Text('Send a package'),
            ),
            const SizedBox(height: 24),
            Text('My shipments', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_shipments.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 32), child: Center(child: Text('No shipments yet')))
            else
              ..._shipments.map((s) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(s['shipment_reference'] as String? ?? ''),
                      subtitle: Text(DateFormat('d MMM yyyy').format(DateTime.parse(s['created_at'] as String))),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('₹${((s['total_fare_cents'] as int? ?? 0) / 100).toStringAsFixed(0)}'),
                          Text(
                            (s['status'] as String? ?? '').replaceAll('_', ' ').toUpperCase(),
                            style: TextStyle(color: _statusColor(s['status'] as String? ?? ''), fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => ShipmentDetailScreen(shipmentId: s['id'] as String)),
                        );
                        _load();
                      },
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}
