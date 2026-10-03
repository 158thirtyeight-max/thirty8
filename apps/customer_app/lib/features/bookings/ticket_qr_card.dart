import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/supabase_providers.dart';

/// One passenger's digital ticket. The QR is issued by the backend (`generate_ticket_qr`) and only for a confirmed,
/// paid booking item, so a ticket is never shown for an unpaid or unconfirmed booking.
class TicketQrCard extends ConsumerStatefulWidget {
  const TicketQrCard({
    super.key,
    required this.bookingItemId,
    required this.passengerName,
    required this.boardingPoint,
    required this.droppingPoint,
  });

  final String bookingItemId;
  final String passengerName;
  final String boardingPoint;
  final String droppingPoint;

  @override
  ConsumerState<TicketQrCard> createState() => _TicketQrCardState();
}

class _TicketQrCardState extends ConsumerState<TicketQrCard> {
  String? _payload;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    String? qr;
    try {
      qr = await ref.read(supabaseProvider).rpc('generate_ticket_qr', params: {'p_booking_item_id': widget.bookingItemId}) as String?;
    } catch (_) {
      qr = null;
    }
    if (!mounted) return;
    setState(() {
      _payload = qr;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.passengerName, style: text.titleSmall),
                const SizedBox(height: 4),
                Text('Board: ${widget.boardingPoint}', style: text.bodySmall),
                Text('Drop: ${widget.droppingPoint}', style: text.bodySmall),
                const SizedBox(height: 6),
                Text('Show this code to the conductor when boarding.', style: text.bodySmall?.copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (_loading)
            const SizedBox(width: 120, height: 120, child: Center(child: CircularProgressIndicator()))
          else if (_payload != null)
            QrImageView(data: _payload!, size: 120)
          else
            SizedBox(
              width: 120,
              height: 120,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.qr_code_2, size: 40, color: AppColors.textTertiary),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ]),
            ),
        ],
      ),
    );
  }
}
