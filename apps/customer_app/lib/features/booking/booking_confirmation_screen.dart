import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/supabase_providers.dart';

class BookingConfirmationScreen extends ConsumerStatefulWidget {
  const BookingConfirmationScreen({super.key, required this.bookingReference});

  final String bookingReference;

  @override
  ConsumerState<BookingConfirmationScreen> createState() => _BookingConfirmationScreenState();
}

class _BookingConfirmationScreenState extends ConsumerState<BookingConfirmationScreen> {
  bool _loading = true;
  Map<String, dynamic>? _booking;
  List<_TicketInfo> _tickets = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final supabase = ref.read(supabaseProvider);
    final booking = await supabase.from('bookings').select().eq('booking_reference', widget.bookingReference).single();

    final items = await supabase
        .from('booking_items')
        .select('id, fare_cents, passengers(full_name), boarding_points(name), dropping_points(name)')
        .eq('booking_id', booking['id'] as String);

    final tickets = <_TicketInfo>[];
    for (final item in List<Map<String, dynamic>>.from(items as List)) {
      String? qr;
      try {
        qr = await supabase.rpc('generate_ticket_qr', params: {'p_booking_item_id': item['id']}) as String?;
      } catch (_) {
        qr = null;
      }
      tickets.add(_TicketInfo(
        passengerName: (item['passengers'] as Map?)?['full_name'] as String? ?? '',
        boardingPoint: (item['boarding_points'] as Map?)?['name'] as String? ?? '',
        droppingPoint: (item['dropping_points'] as Map?)?['name'] as String? ?? '',
        qrPayload: qr,
      ));
    }

    if (!mounted) return;
    setState(() {
      _booking = booking;
      _tickets = tickets;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Booking confirmed'), automaticallyImplyLeading: false),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Icon(Icons.check_circle, size: 64, color: Colors.green.shade600),
                  const SizedBox(height: 12),
                  Center(child: Text(widget.bookingReference, style: Theme.of(context).textTheme.titleLarge)),
                  const SizedBox(height: 4),
                  Center(child: Text('Status: ${_booking?['status']}', style: Theme.of(context).textTheme.bodyMedium)),
                  const SizedBox(height: 24),
                  ..._tickets.map((t) => Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(t.passengerName, style: Theme.of(context).textTheme.titleSmall),
                                    const SizedBox(height: 4),
                                    Text('Board: ${t.boardingPoint}', style: Theme.of(context).textTheme.bodySmall),
                                    Text('Drop: ${t.droppingPoint}', style: Theme.of(context).textTheme.bodySmall),
                                  ],
                                ),
                              ),
                              if (t.qrPayload != null)
                                QrImageView(data: t.qrPayload!, size: 80)
                              else
                                const SizedBox(width: 80, height: 80, child: Icon(Icons.qr_code_2, size: 48, color: Colors.grey)),
                            ],
                          ),
                        ),
                      )),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
                    child: const Text('Back to home'),
                  ),
                ],
              ),
            ),
    );
  }
}

class _TicketInfo {
  final String passengerName;
  final String boardingPoint;
  final String droppingPoint;
  final String? qrPayload;

  _TicketInfo({required this.passengerName, required this.boardingPoint, required this.droppingPoint, this.qrPayload});
}
