import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import '../booking/booking_confirmation_screen.dart';
import '../booking/payment_screen.dart';
import 'live_tracking_screen.dart';
import 'rating_screen.dart';
import 'refund_status.dart';
import 'ticket_qr_card.dart';

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
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _policyTiers = [];
  List<Map<String, dynamic>> _refunds = [];
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

    // payment, policy and refund information is supporting detail: a failure here must not hide the booking itself
    Map<String, dynamic>? order;
    var tiers = <Map<String, dynamic>>[];
    var refunds = <Map<String, dynamic>>[];
    try {
      final o = await supabase
          .from('orders')
          .select('order_reference, amount_cents, status')
          .eq('orderable_type', 'booking')
          .eq('orderable_id', widget.bookingId)
          .maybeSingle();
      order = o == null ? null : Map<String, dynamic>.from(o);
    } catch (_) {}
    try {
      final p = await supabase.rpc('get_booking_cancellation_policy', params: {'p_booking_id': widget.bookingId});
      if (p is Map && p['tiers'] is List) tiers = List<Map<String, dynamic>>.from((p['tiers'] as List).map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {}
    try {
      final r = await supabase.rpc('get_my_refund_status', params: {'p_booking_id': widget.bookingId});
      if (r is List) refunds = List<Map<String, dynamic>>.from(r.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {}

    if (!mounted) return;
    final itemsList = List<Map<String, dynamic>>.from(items as List);
    setState(() {
      _booking = booking;
      _order = order;
      _items = itemsList;
      _policyTiers = tiers;
      _refunds = refunds;
      _tripId = itemsList.isNotEmpty ? itemsList.first['trip_id'] as String? : null;
      _loading = false;
    });
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: const Text(
          'If this booking was already paid, a refund request will be created and reviewed by thirty8 under the cancellation policy. '
          'The refund amount depends on that policy and is not automatic.',
        ),
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

  /// Resume an unfinished payment. The payment screen only offers "Pay" while the order is still payable, and never
  /// starts a second payment once one was made.
  Future<void> _completePayment() async {
    final order = _order;
    final booking = _booking;
    if (order == null || booking == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PaymentScreen(
        orderReference: order['order_reference'] as String,
        amountCents: order['amount_cents'] as int,
        description: 'Booking ${booking['booking_reference']}',
        contactEmail: booking['contact_email'] as String?,
        contactPhone: booking['contact_phone'] as String?,
        onSuccess: (_) => BookingConfirmationScreen(bookingReference: booking['booking_reference'] as String),
      ),
    ));
    if (mounted) _load();
  }

  Widget _paymentPending(BuildContext context) {
    final orderStatus = _order?['status'] as String?;
    final text = Theme.of(context).textTheme;
    String title;
    String body;
    var canPay = false;
    if (orderStatus == 'created') {
      title = 'Payment not completed';
      body = 'Your seats are held only for a short time. Finish paying to confirm your booking. If your seats were released in the meantime, the payment will be refunded.';
      canPay = true;
    } else if (orderStatus == 'paid') {
      title = 'Payment received, booking not confirmed';
      body = 'We received your payment but could not confirm this booking (for example the seats were released). A refund has been requested and thirty8 will review it.';
    } else {
      title = 'This booking was not completed';
      body = 'The payment window has closed. Please make a new booking.';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.payments_outlined, color: AppColors.warning),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: text.titleSmall)),
            ]),
            const SizedBox(height: 8),
            Text(body, style: text.bodyMedium),
            if (canPay) ...[
              const SizedBox(height: 12),
              AppButton(label: 'Complete payment', icon: Icons.lock_outline, expand: true, onPressed: _completePayment),
            ],
          ],
        ),
      ),
    );
  }

  Widget _refundSection(BuildContext context) {
    if (_refunds.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Refund', style: text.titleSmall),
          const SizedBox(height: 8),
          ..._refunds.map((r) {
            final line = refundStatusLine(r);
            final color = switch (line.tone) {
              'done' => AppColors.success,
              'problem' => AppColors.error,
              'progress' => AppColors.warning,
              _ => AppColors.textTertiary,
            };
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: AppCard(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(line.tone == 'done' ? Icons.check_circle_outline : line.tone == 'problem' ? Icons.error_outline : Icons.hourglass_top, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(line.title, style: text.titleSmall),
                      if (line.detail.isNotEmpty) Text(line.detail, style: text.bodySmall),
                    ]),
                  ),
                ]),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _policySection(BuildContext context) {
    if (_policyTiers.isEmpty) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cancellation policy for this booking', style: text.titleSmall),
          const SizedBox(height: 8),
          ..._policyTiers.map((t) => Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• ${policyTierLine(t)}', style: text.bodySmall))),
          const SizedBox(height: 4),
          Text('Refunds are reviewed and approved by thirty8; the amount follows this policy.', style: text.bodySmall?.copyWith(color: AppColors.textTertiary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: AppLoadingState());
    }

    final booking = _booking!;
    final status = booking['status'] as String;
    final canCancel = status == 'confirmed' || status == 'payment_pending';
    final canRate = status == 'confirmed';
    final showTickets = status == 'confirmed';
    String? tripStatus;
    if (_items.isNotEmpty) {
      final tripMap = _items.first['bus_trips'] as Map?;
      tripStatus = tripMap?['status'] as String?;
    }
    final canTrack = canRate && tripStatus != null && tripStatus != 'scheduled';

    return Scaffold(
      appBar: AppBar(title: Text(booking['booking_reference'] as String)),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Status', style: Theme.of(context).textTheme.bodyMedium),
                  AppBadge(status: status),
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
              const SizedBox(height: 16),
              if (status == 'payment_pending') _paymentPending(context),
              _refundSection(context),
              Text(showTickets ? 'Tickets' : 'Passengers', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              ..._items.map((item) {
                final passenger = item['passengers'] as Map?;
                final boarding = item['boarding_points'] as Map?;
                final dropping = item['dropping_points'] as Map?;
                final name = passenger?['full_name'] as String? ?? '';
                final itemConfirmed = (item['status'] as String?) == 'confirmed';
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: showTickets && itemConfirmed
                      ? TicketQrCard(
                          bookingItemId: item['id'] as String,
                          passengerName: name,
                          boardingPoint: boarding?['name'] as String? ?? '-',
                          droppingPoint: dropping?['name'] as String? ?? '-',
                        )
                      : AppCard(
                          padding: EdgeInsets.zero,
                          child: AppListItem(title: name, subtitle: 'Board: ${boarding?['name'] ?? '-'} → Drop: ${dropping?['name'] ?? '-'}'),
                        ),
                );
              }),
              const SizedBox(height: 16),
              _policySection(context),
              const SizedBox(height: 8),
              if (canTrack)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppButton(
                    label: 'Track live location',
                    icon: Icons.location_on_outlined,
                    variant: AppButtonVariant.outline,
                    expand: true,
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LiveTrackingScreen(tripId: _tripId!))),
                  ),
                ),
              if (canRate)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppButton(
                    label: 'Rate this trip',
                    icon: Icons.star_outline,
                    variant: AppButtonVariant.outline,
                    expand: true,
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RatingScreen(tripId: _tripId!))),
                  ),
                ),
              if (canCancel)
                AppButton(
                  label: 'Cancel booking',
                  icon: Icons.cancel_outlined,
                  variant: AppButtonVariant.destructive,
                  expand: true,
                  loading: _cancelling,
                  onPressed: _cancelling ? null : _cancel,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String formatDate(String iso) => DateFormat('d MMM yyyy, h:mm a').format(DateTime.parse(iso).toLocal());
