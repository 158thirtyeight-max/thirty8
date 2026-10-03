import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import 'manifest_models.dart';
import 'manifest_pdf.dart';

/// Bookings → Passenger manifest: search, filters, per-passenger boarding verification.
/// Document numbers are masked everywhere; the full number needs an audited reveal.
class PassengerManifestSection extends ConsumerStatefulWidget {
  const PassengerManifestSection({super.key, required this.tripId, required this.operatorContext, required this.tripStatus, this.exportInfo});

  final String tripId;
  final OperatorContext? operatorContext;
  final String tripStatus;

  /// Header facts for the PDF; when null the export bar is not shown.
  final ManifestExportInfo? exportInfo;

  @override
  ConsumerState<PassengerManifestSection> createState() => _PassengerManifestSectionState();
}

class _PassengerManifestSectionState extends ConsumerState<PassengerManifestSection> {
  ManifestFilter _filter = ManifestFilter.all;
  String _search = '';
  Timer? _debounce;
  final _searchCtl = TextEditingController();

  ManifestQuery get _query => ManifestQuery(widget.tripId, _filter, _search);
  bool get _isAdmin => widget.operatorContext?.isAdmin ?? false;
  bool get _boardable => const ['scheduled', 'boarding', 'departed'].contains(widget.tripStatus);

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _search = v);
    });
  }

  void _refresh() {
    for (final f in ManifestFilter.values) {
      ref.invalidate(tripManifestProvider(ManifestQuery(widget.tripId, f, _search)));
    }
    ref.invalidate(tripManifestProvider(_query));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tripManifestProvider(_query));
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchCtl,
          onChanged: _onSearch,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Name, booking reference, seat or phone',
            suffixIcon: _searchCtl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchCtl.clear();
                      setState(() => _search = '');
                    },
                  ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (widget.exportInfo != null)
          _ExportBar(
            tripId: widget.tripId,
            info: widget.exportInfo!,
            closed: async.value?.bookingClosed,
            closeAt: async.value?.bookingCloseAt ?? async.value?.departureAt,
          ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final f in ManifestFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: AppChip(label: f.label, selected: _filter == f, onTap: () => setState(() => _filter = f)),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        async.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load the manifest.', onRetry: _refresh),
          data: (result) => result.passengers.isEmpty
              ? AppEmptyState(
                  icon: Icons.people_outline,
                  message: _search.isNotEmpty ? 'No passengers match your search.' : 'No passengers in this list.',
                )
              : Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                        child: Text('${result.passengers.length} ${result.passengers.length == 1 ? 'passenger' : 'passengers'}', style: theme.textTheme.bodySmall),
                      ),
                    ),
                    for (final p in result.passengers)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _PassengerTile(
                          passenger: p,
                          onTap: () => showPassengerSheet(
                            context,
                            ref,
                            passenger: p,
                            isAdmin: _isAdmin,
                            boardable: _boardable,
                            onChanged: _refresh,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _PassengerTile extends StatelessWidget {
  const _PassengerTile({required this.passenger, required this.onTap});

  final ManifestPassenger passenger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = passenger;
    return AppCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(child: Text(p.seatCode, style: const TextStyle(fontSize: 12))),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: theme.textTheme.titleSmall),
                Text('${p.bookingReference} · ${p.boardingPoint} → ${p.droppingPoint}', style: theme.textTheme.bodySmall),
                if (p.documentLine != null) Text(p.documentLine!, style: theme.textTheme.bodySmall),
                if (p.phone != null) Text(p.phone!, style: theme.textTheme.bodySmall),
                if (p.hasPaymentException)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      p.refundStatus == 'pending' ? 'Refund pending' : 'Payment ${p.paymentStatus}',
                      style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          AppBadge(status: p.boarding.badge),
        ],
      ),
    );
  }
}

/// Booking details + the boarding actions for one passenger.
Future<void> showPassengerSheet(
  BuildContext context,
  WidgetRef ref, {
  required ManifestPassenger passenger,
  required bool isAdmin,
  required bool boardable,
  required VoidCallback onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => _PassengerSheet(passenger: passenger, isAdmin: isAdmin, boardable: boardable, onChanged: onChanged),
  );
}

class _PassengerSheet extends ConsumerStatefulWidget {
  const _PassengerSheet({required this.passenger, required this.isAdmin, required this.boardable, required this.onChanged});

  final ManifestPassenger passenger;
  final bool isAdmin;
  final bool boardable;
  final VoidCallback onChanged;

  @override
  ConsumerState<_PassengerSheet> createState() => _PassengerSheetState();
}

class _PassengerSheetState extends ConsumerState<_PassengerSheet> {
  bool _docChecked = false;
  bool _busy = false;

  ManifestPassenger get p => widget.passenger;

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<String?> _askReason(String title, {String hint = 'Reason'}) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: AppTextField(controller: c, label: hint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (c.text.trim().length >= 5) Navigator.pop(d, c.text.trim());
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<void> _run(Future<dynamic> Function() call, {String? successMessage, bool close = true}) async {
    setState(() => _busy = true);
    try {
      final res = await call();
      final r = res is Map ? BoardingResult.fromJson(Map<String, dynamic>.from(res)) : const BoardingResult(ok: true);
      if (!r.ok) {
        _snack(r.message ?? 'That could not be done.');
      } else {
        if (successMessage != null) _snack(successMessage);
        widget.onChanged();
        if (close && mounted) Navigator.pop(context);
      }
    } catch (e) {
      _snack(boardingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() => _run(
        () => ref.read(supabaseProvider).rpc('verify_passenger_boarding', params: {
          'p_booking_item_id': p.bookingItemId,
          'p_doc_checked': _docChecked,
          'p_via': 'manual',
        }),
        successMessage: 'Passenger verified',
      );

  Future<void> _confirm() => _run(
        () => ref.read(supabaseProvider).rpc('confirm_boarding', params: {'p_booking_item_id': p.bookingItemId}),
        successMessage: 'Boarding confirmed',
      );

  Future<void> _exception() async {
    final reason = await _askReason('Report a boarding exception', hint: 'What is wrong? (min 5 characters)');
    if (reason == null) return;
    await _run(
      () => ref.read(supabaseProvider).rpc('mark_boarding_exception', params: {'p_booking_item_id': p.bookingItemId, 'p_reason': reason}),
      successMessage: 'Exception recorded',
    );
  }

  Future<void> _correct() async {
    final reason = await _askReason('Correct boarding', hint: 'Why is this being corrected? (min 5 characters)');
    if (reason == null) return;
    await _run(
      () => ref.read(supabaseProvider).rpc('correct_boarding', params: {'p_booking_item_id': p.bookingItemId, 'p_reason': reason}),
      successMessage: 'Boarding reset',
    );
  }

  Future<void> _reveal() async {
    final reason = await _askReason('View full document number', hint: 'Reason (recorded in the audit log)');
    if (reason == null) return;
    setState(() => _busy = true);
    try {
      final res = await ref.read(supabaseProvider).rpc('reveal_passenger_document', params: {
        'p_booking_item_id': p.bookingItemId,
        'p_reason': reason,
      }) as Map;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _RevealDialog(label: (res['doc_label'] as String?) ?? 'Document', number: res['doc_number'] as String),
      );
    } catch (e) {
      _snack(boardingErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget line(String label, String? value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 120, child: Text(label, style: theme.textTheme.bodySmall)),
            Expanded(child: Text(value == null || value.isEmpty ? '—' : value)),
          ]),
        );
    final canAct = widget.boardable && !_busy;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.md + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text(p.name, style: theme.textTheme.titleLarge)),
              AppBadge(status: p.boarding.badge),
            ]),
            const SizedBox(height: AppSpacing.sm),
            line('Booking', p.bookingReference),
            line('Seat', p.seatCode),
            line('Phone', p.phone),
            line('Boarding point', p.boardingPoint),
            line('Destination', p.droppingPoint),
            line('Booking status', p.bookingStatus),
            line('Payment', p.refundStatus == 'pending' ? '${p.paymentStatus} · refund pending' : p.paymentStatus),
            line('ID document', p.documentLine ?? 'None provided'),
            if (p.docVerification != null) line('ID check', p.docVerification),
            line('Boarding', p.boarding.label),
            if (p.exceptionReason != null) line('Exception', p.exceptionReason),
            const SizedBox(height: AppSpacing.md),
            if (!widget.boardable)
              Text('This trip is not open for boarding actions.', style: theme.textTheme.bodySmall),
            if (p.canVerify && p.boarding != BoardingStatus.verified && widget.boardable) ...[
              if (p.hasDocument)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _docChecked,
                  onChanged: _busy ? null : (v) => setState(() => _docChecked = v ?? false),
                  title: Text('I checked the passenger’s ${p.docLabel} against the booking'),
                ),
              AppButton(label: 'Verify passenger', icon: Icons.verified_user_outlined, expand: true, loading: _busy, onPressed: canAct ? _verify : null),
            ],
            if (p.canConfirmBoarding && widget.boardable)
              AppButton(label: 'Confirm boarding', icon: Icons.directions_bus, expand: true, loading: _busy, onPressed: canAct ? _confirm : null),
            if (!p.canVerify && !p.isPaid && p.isConfirmed)
              Text('Payment has not been captured, so this passenger cannot be verified.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
            if (p.canReportException && widget.boardable) ...[
              const SizedBox(height: AppSpacing.xs),
              AppButton(label: 'Report exception', variant: AppButtonVariant.outline, expand: true, onPressed: canAct ? _exception : null),
            ],
            if (widget.isAdmin && p.hasDocument) ...[
              const SizedBox(height: AppSpacing.xs),
              AppButton(label: 'View full document number', icon: Icons.visibility_outlined, variant: AppButtonVariant.ghost, expand: true, onPressed: _busy ? null : _reveal),
            ],
            if (widget.isAdmin && widget.boardable && p.boarding != BoardingStatus.notBoarded) ...[
              const SizedBox(height: AppSpacing.xs),
              AppButton(label: 'Correct boarding', icon: Icons.undo, variant: AppButtonVariant.ghost, expand: true, onPressed: canAct ? _correct : null),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows the number for 30 seconds, then closes. Never logged or persisted.
class _RevealDialog extends StatefulWidget {
  const _RevealDialog({required this.label, required this.number});

  final String label;
  final String number;

  @override
  State<_RevealDialog> createState() => _RevealDialogState();
}

class _RevealDialogState extends State<_RevealDialog> {
  Timer? _timer;
  int _left = 30;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_left <= 1) {
        t.cancel();
        if (mounted) Navigator.pop(context);
      } else if (mounted) {
        setState(() => _left--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(widget.number, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('This access was recorded. Hiding in $_left s.', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: widget.number)),
          child: const Text('Copy'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Hide')),
      ],
    );
  }
}


/// Passenger list for carrying on the bus. Locked until booking has closed; every export is audited.
class _ExportBar extends ConsumerStatefulWidget {
  const _ExportBar({required this.tripId, required this.info, required this.closed, required this.closeAt});

  final String tripId;
  final ManifestExportInfo info;
  final bool? closed;
  final DateTime? closeAt;

  @override
  ConsumerState<_ExportBar> createState() => _ExportBarState();
}

class _ExportBarState extends ConsumerState<_ExportBar> {
  bool _busy = false;

  Future<void> _export(String action) async {
    setState(() => _busy = true);
    try {
      final client = ref.read(supabaseProvider);
      // The database decides: it refuses (and logs nothing) while booking is still open.
      await client.rpc('log_manifest_export', params: {'p_trip_id': widget.tripId, 'p_action': action});
      // Always the full confirmed list, whatever filter or search is on screen.
      final res = await client.rpc('get_trip_manifest', params: {'p_trip_id': widget.tripId, 'p_filter': 'all'});
      final result = ManifestResult.fromJson(Map<String, dynamic>.from(res as Map));
      final info = ManifestExportInfo(
        routeLabel: widget.info.routeLabel,
        busRegistration: widget.info.busRegistration,
        departureAt: widget.info.departureAt,
        operatorName: widget.info.operatorName,
        bookingClosedAt: result.bookingCloseAt,
      );
      final bytes = await buildManifestPdf(result.passengers, info);
      final name = manifestExportFileName(info);
      if (action == 'share') {
        await Printing.sharePdf(bytes: bytes, filename: name);
      } else {
        // Opens the system viewer with Save / Print, so the file can be kept on the phone.
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(boardingErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final closed = widget.closed;
    final at = widget.closeAt == null ? null : DateFormat('d MMM, h:mm a').format(widget.closeAt!);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.picture_as_pdf_outlined, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text('Passenger list (PDF)', style: theme.textTheme.titleSmall)),
            ]),
            const SizedBox(height: 2),
            Text(
              closed == true
                  ? 'Booking is closed. Download the list to carry it, or share it. IDs are masked.'
                  : (closed == null ? 'Checking booking status…' : 'Available once booking closes${at == null ? '' : ' (at $at)'}.'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(children: [
              Expanded(
                child: AppButton(
                  label: 'Download',
                  icon: Icons.download_outlined,
                  size: AppButtonSize.small,
                  loading: _busy,
                  onPressed: (closed == true && !_busy) ? () => _export('download') : null,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Share',
                  icon: Icons.share_outlined,
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.outline,
                  onPressed: (closed == true && !_busy) ? () => _export('share') : null,
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
