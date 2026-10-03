import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../charts/analytics_charts.dart';
import '../earnings/earnings_models.dart';

/// Trip → Financial analytics. Every figure comes from `get_trip_financials`
/// (the same calculation as Earnings and settlements); nothing is computed in the UI.
class TripFinancialSection extends ConsumerWidget {
  const TripFinancialSection({super.key, required this.tripId});

  final String tripId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tripFinancialsProvider(tripId));
    return async.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(message: 'Could not load the financial summary.', onRetry: () => ref.invalidate(tripFinancialsProvider(tripId))),
      data: (f) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TripFinancialSummary(financials: f),
          const SizedBox(height: AppSpacing.sm),
          RevenueBreakdownChart(financials: f),
          const SizedBox(height: AppSpacing.sm),
          CollectionVsSettlementChart(financials: f),
        ],
      ),
    );
  }
}

/// The trip's money, one labelled line per concept — sales are never shown as money received.
class TripFinancialSummary extends StatelessWidget {
  const TripFinancialSummary({super.key, required this.financials});

  final TripFinancials financials;

  @override
  Widget build(BuildContext context) {
    final f = financials;
    final theme = Theme.of(context);

    Widget line(String label, int cents, {String? hint, bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: strong ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium),
                    if (hint != null) Text(hint, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
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
          Text('Sales', style: theme.textTheme.labelLarge),
          line('Gross ticket value', f.grossCents, hint: '${f.soldTickets} confirmed ticket${f.soldTickets == 1 ? '' : 's'}'),
          line('Cancelled booking value', f.cancelledValueCents, hint: 'Tickets cancelled after payment'),
          const Divider(height: AppSpacing.md),
          Text('Payments', style: theme.textTheme.labelLarge),
          line('Payments collected', f.collectedCents, hint: 'Money actually received'),
          line('Pending payments', f.pendingPaymentsCents, hint: 'Customers still checking out', color: f.pendingPaymentsCents > 0 ? AppColors.warning : null),
          line('Failed payments', f.failedPaymentsCents, color: f.failedPaymentsCents > 0 ? AppColors.error : null),
          line('Refunds initiated', f.refundsInitiatedCents, hint: 'Requested, not yet completed', color: f.refundsInitiatedCents > 0 ? AppColors.warning : null),
          line('Refunds completed', f.refundsCompletedCents, hint: 'Returned to customers'),
          const Divider(height: AppSpacing.md),
          Text('Settlement', style: theme.textTheme.labelLarge),
          line(
            f.commissionIsEstimate ? 'Platform commission (estimated)' : 'Platform commission',
            f.commissionCents,
            hint: f.commissionConfigured ? (f.commissionIsEstimate ? 'Final once the trip is settled' : 'Settled amount') : 'Commission rate not configured yet',
          ),
          line('Other deductions', f.otherDeductionsCents),
          if (f.refundDeductionsCents > 0)
            line('Refund deductions to recover', f.refundDeductionsCents, hint: 'Tickets cancelled after they were paid out', color: AppColors.warning),
          line('Net operator payable', f.netPayableCents, strong: true),
          line('Paid to operator', f.paidCents, hint: 'From verified settlement payments'),
          line('Remaining settlement balance', f.remainingCents, strong: true, color: f.remainingCents < 0 ? AppColors.warning : null),
          if (f.remainingCents < 0)
            Text('A negative balance means more was paid out than is now payable; it is recovered in the next settlement.', style: theme.textTheme.bodySmall),
          if (!f.commissionConfigured)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text('Commission is not configured, so net payable is shown without commission.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
            ),
        ],
      ),
    );
  }
}
