import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

class MyTripsTab extends ConsumerStatefulWidget {
  const MyTripsTab({super.key});

  @override
  ConsumerState<MyTripsTab> createState() => _MyTripsTabState();
}

class _MyTripsTabState extends ConsumerState<MyTripsTab> {
  List<Map<String, dynamic>> _bookings = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = ref.read(currentUserProvider)?.id;
    if (userId == null) return;
    final res = await ref
        .read(supabaseProvider)
        .from('bookings')
        .select()
        .eq('customer_id', userId)
        .order('created_at', ascending: false);
    if (!mounted) return;
    setState(() {
      _bookings = List<Map<String, dynamic>>.from(res as List);
      _loading = false;
    });
  }

  Color _statusColor(String status, BuildContext context) {
    switch (status) {
      case 'confirmed':
        return Colors.green;
      case 'cancelled':
      case 'failed':
      case 'expired':
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
        child: _bookings.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Icon(Icons.confirmation_number_outlined, size: 48, color: Colors.grey),
                  SizedBox(height: 12),
                  Center(child: Text('No trips booked yet')),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _bookings.length,
                separatorBuilder: (a, b) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final b = _bookings[index];
                  final fare = (b['total_fare_cents'] as int? ?? 0) / 100;
                  return Card(
                    child: ListTile(
                      title: Text(b['booking_reference'] as String? ?? ''),
                      subtitle: Text(DateFormat('d MMM yyyy, h:mm a').format(DateTime.parse(b['created_at'] as String))),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('₹${fare.toStringAsFixed(0)}'),
                          Text(
                            (b['status'] as String? ?? '').toUpperCase(),
                            style: TextStyle(color: _statusColor(b['status'] as String? ?? '', context), fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
