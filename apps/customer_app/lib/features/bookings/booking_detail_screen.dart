import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'live_tracking_screen.dart';
import 'rating_screen.dart';

class BookingDetailScreen extends ConsumerStatefulWidget {
  const BookingDetailScreen({super.key, required this.bookingId});

  final String bookingId;

  @override
  ConsumerState<BookingDetailScreen> createState() => _BookingDetailScreenState();
}

class _BookingDetailScreenState extends ConsumerState<BookingDetailScreen> {
  bool _loading = true;
  bool _cancelling = false;
  Map<String, dynamic>? _booking;
  List<Map<String, dynamic>> _items = [];
  String? _tripId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final supabase = ref.read(supabaseProvider);
    final booking = await supabase.from('bookings').select().eq('id', widget.bookingId).single();
    final items = await supabase
        .from('booking_items')
        .select('id, trip_id, fare_cents, status, passengers(full_name), boarding_points(name), dropping_points(name), bus_trips(departure_at, status, live_tracking_enabled)')
        .eq('booking_id', widget.bookingId);

    if (!mounted) return;
    final itemsList = List<Map<String, dynamic>>.from(items as List);
    setState(() {
      _booking = booking;
      _items = itemsList;
      _tripId = itemsList.isNotEmpty ? itemsList.first['trip_id'] as String? : null;
      _loading = false;
    });
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: const Text('If this booking was already paid, a refund will be initiated per the cancellation policy.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep booking')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Cancel booking')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _cancelling = true);
    try {
      await ref.read(supabaseProvider).rpc('cancel_booking', params: {'p_booking_id': widget.bookingId, 'p_reason': 'Cancelled by customer'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Booking cancelled')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not cancel this booking')));
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final booking = _booking!;
    final status = booking['status'] as String;
    final canCancel = status == 'confirmed' || status == 'payment_pending';
    final canRate = status == 'confirmed';
    String? tripStatus;
    if (_items.isNotEmpty) {
      final tripMap = _items.first['bus_trips'] as Map?;
      tripStatus = tripMap?['status'] as String?;
    }
    final canTrack = canRate && tripStatus != null && tripStatus != 'scheduled';

    return Scaffold(
      appBar: AppBar(title: Text(booking['booking_reference'] as String)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Status', style: Theme.of(context).textTheme.bodyMedium),
                Text(status.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total fare', style: Theme.of(context).textTheme.bodyMedium),
                Text('₹${((booking['total_fare_cents'] as int? ?? 0) / 100).toStringAsFixed(0)}'),
              ],
            ),
            const SizedBox(height: 24),
            Text('Passengers', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ..._items.map((item) {
              final passenger = item['passengers'] as Map?;
              final boarding = item['boarding_points'] as Map?;
              final dropping = item['dropping_points'] as Map?;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(passenger?['full_name'] as String? ?? ''),
                  subtitle: Text('Board: ${boarding?['name'] ?? '-'} → Drop: ${dropping?['name'] ?? '-'}'),
                ),
              );
            }),
            const SizedBox(height: 24),
            if (canTrack)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LiveTrackingScreen(tripId: _tripId!))),
                  icon: const Icon(Icons.location_on_outlined),
                  label: const Text('Track live location'),
                ),
              ),
            if (canRate)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RatingScreen(tripId: _tripId!))),
                  icon: const Icon(Icons.star_outline),
                  label: const Text('Rate this trip'),
                ),
              ),
            if (canCancel)
              OutlinedButton.icon(
                onPressed: _cancelling ? null : _cancel,
                style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                icon: _cancelling
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cancel_outlined),
                label: const Text('Cancel booking'),
              ),
          ],
        ),
      ),
    );
  }
}

String formatDate(String iso) => DateFormat('d MMM yyyy, h:mm a').format(DateTime.parse(iso).toLocal());
