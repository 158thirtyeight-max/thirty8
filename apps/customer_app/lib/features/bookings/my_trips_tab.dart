import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'booking_detail_screen.dart';

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
    if (userId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
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
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoadingState();

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: _bookings.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  AppEmptyState(message: 'No trips booked yet', icon: Icons.confirmation_number_outlined),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _bookings.length,
                separatorBuilder: (a, b) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final b = _bookings[index];
                  final fare = (b['total_fare_cents'] as int? ?? 0) / 100;
                  return AppCard(
                    padding: EdgeInsets.zero,
                    child: AppListItem(
                      title: b['booking_reference'] as String? ?? '',
                      subtitle: DateFormat('d MMM yyyy, h:mm a').format(DateTime.parse(b['created_at'] as String)),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('₹${fare.toStringAsFixed(0)}'),
                          const SizedBox(height: AppSpacing.xs),
                          AppBadge(status: b['status'] as String? ?? ''),
                        ],
                      ),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => BookingDetailScreen(bookingId: b['id'] as String)),
                        );
                        _load();
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }
}
