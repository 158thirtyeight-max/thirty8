import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'earnings_models.dart';

/// Status pill with the settlement colours: Paid green, Processing blue, Pending amber,
/// Failed red, Reversed grey. The status comes from the settlement record, never from the app.
class SettlementBadge extends StatelessWidget {
  const SettlementBadge({super.key, required this.status});

  final SettlementStatus status;

  @override
  Widget build(BuildContext context) {
    final c = status.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: AppRadius.pillRadius),
      child: Text(status.label, style: AppTypography.label(c)),
    );
  }
}

/// How the settlement was calculated, line by line, then what is still outstanding.
class SettlementDetailScreen extends ConsumerWidget {
  const SettlementDetailScreen({super.key, required this.settlementId});

  final String settlementId;

  static final _dt = DateFormat('d MMM yyyy, h:mm a');
  static final _d = DateFormat('d MMM yyyy');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(settlementDetailProvider(settlementId));
    return Scaffold(
      appBar: AppBar(title: const Text('Settlement')),
      body: async.when(
        loading: () => const Center(child: AppLoadingState()),
        error: (e, _) => Center(child: AppErrorState(message: 'Could not load this settlement.', onRetry: () => ref.invalidate(settlementDetailProvider(settlementId)))),
        data: (d) => RefreshIndicator(
          onRefresh: () async => ref.refresh(settlementDetailProvider(settlementId).future),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              _Header(detail: d),
              const SizedBox(height: AppSpacing.sm),
              _Calculation(detail: d),
              const SizedBox(height: AppSpacing.sm),
              _Payment(detail: d, dt: _dt, d: _d),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.detail});

  final SettlementDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detail.row.reference, style: theme.textTheme.titleLarge),
                Text(
                  '${DateFormat('d MMM').format(detail.periodStart)} – ${DateFormat('d MMM yyyy').format(detail.periodEnd)} · ${detail.trips} trip${detail.trips == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          SettlementBadge(status: detail.row.status),
        ],
      ),
    );
  }
}

class _Calculation extends StatelessWidget {
  const _Calculation({required this.detail});

  final SettlementDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget line(String label, int cents, {String sign = '', bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(width: 20, child: Text(sign, style: theme.textTheme.titleSmall)),
              Expanded(child: Text(label, style: strong ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium)),
              Text(
                formatMoney(cents),
                style: (strong ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium)?.copyWith(fontWeight: FontWeight.w600, color: color),
              ),
            ],
          ),
        );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Calculation', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          line('Gross eligible booking value', detail.grossCents),
          if (detail.refundsCents != 0) line('Refund deductions', detail.refundsCents, sign: '−'),
          line('Platform commission', detail.commissionCents, sign: '−'),
          if (detail.creditsCents > 0) line('Cancellation share credited to you', detail.creditsCents, sign: '+', color: AppColors.success),
          if (detail.recoveryNettedCents > 0) line('Recovered for earlier refunds', detail.recoveryNettedCents, sign: '−'),
          if (detail.creditsCents == 0 && detail.recoveryNettedCents == 0 && detail.otherDeductionsCents != 0)
            line('Other deductions', detail.otherDeductionsCents, sign: '−'),
          const Divider(),
          line('Net operator payable', detail.netPayableCents, sign: '=', strong: true),
          const SizedBox(height: AppSpacing.sm),
          line('Amount paid', detail.paidCents, sign: '−'),
          const Divider(),
          line('Outstanding settlement amount', detail.outstandingCents, sign: '=', strong: true, color: detail.outstandingCents > 0 ? AppColors.warning : AppColors.success),
          if (!detail.calculationAddsUp)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text('These lines do not add up to the net payable. Please contact support.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.error)),
            ),
        ],
      ),
    );
  }
}

class _Payment extends StatelessWidget {
  const _Payment({required this.detail, required this.dt, required this.d});

  final SettlementDetail detail;
  final DateFormat dt;
  final DateFormat d;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = detail.row;
    Widget row(String label, String? value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 130, child: Text(label, style: theme.textTheme.bodySmall)),
            Expanded(child: Text(value == null || value.isEmpty ? '—' : value)),
          ]),
        );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Payment', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          row('Approved by thirty8', detail.approvedAt == null ? 'Not yet' : dt.format(detail.approvedAt!)),
          row('Payment file sent to bank', detail.exportedAt == null ? 'Not yet' : dt.format(detail.exportedAt!)),
          row('Bank payment confirmed', detail.bankPaidAt == null ? 'Not yet' : dt.format(detail.bankPaidAt!)),
          if (detail.approvedAt == null && detail.exportedAt == null) row('Initiated', r.initiatedAt == null ? 'Not yet initiated' : dt.format(r.initiatedAt!)),
          row('Completed', r.completedAt == null ? null : dt.format(r.completedAt!)),
          row('Payment method', r.method?.replaceAll('_', ' ')),
          row('Transaction reference', r.txnReference),
          if (detail.failureReason != null) row('Failure reason', detail.failureReason),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Payout status is recorded by thirty8 from verified bank payments. It cannot be changed from this app.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
