import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'earnings_models.dart';
import 'finance_models.dart';

/// Payouts, refund adjustments and recoveries: strictly READ-ONLY.
///
/// There is deliberately no button here to start, approve, change or execute a refund, to edit a cancellation policy or
/// a commission, or to change a payout. thirty8 manages all of that centrally; an operator only sees the result for
/// its own tickets. (The database refuses those actions for operators as well; hiding buttons is not the security.)
class PayoutsScreen extends ConsumerWidget {
  const PayoutsScreen({super.key, required this.operatorId});

  final String operatorId;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(earningsBreakdownProvider(operatorId));
    ref.invalidate(paymentProfileProvider(operatorId));
    ref.invalidate(refundAdjustmentsProvider(operatorId));
    ref.invalidate(operatorRecoveriesProvider(operatorId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Payouts & adjustments')),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            AppCard(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.visibility_outlined, size: 18, color: AppColors.textTertiary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'This page is for viewing only. thirty8 decides refunds, cancellation terms, commission and payouts, and settles you weekly by bank transfer.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ]),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Payout account', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            _ProfileCard(operatorId: operatorId),
            const SizedBox(height: AppSpacing.lg),
            Text('Your earnings', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            _BreakdownGrid(operatorId: operatorId),
            const SizedBox(height: AppSpacing.lg),
            Text('Recoveries', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text('Money owed to thirty8 after a refund on a ticket you were already paid for. It is deducted from your next payouts.', style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
            _Recoveries(operatorId: operatorId),
            const SizedBox(height: AppSpacing.lg),
            Text('Cancelled & refunded tickets', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            _Adjustments(operatorId: operatorId),
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.operatorId});

  final String operatorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ref.watch(paymentProfileProvider(operatorId)).when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load your payout account.', onRetry: () => ref.invalidate(paymentProfileProvider(operatorId))),
          data: (p) {
            final ok = p.settlementEligible;
            final color = ok ? AppColors.success : (p.verificationStatus == 'failed' ? AppColors.error : AppColors.warning);
            return AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(ok ? Icons.verified_outlined : Icons.pending_outlined, color: color),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: Text(p.statusLabel, style: theme.textTheme.titleSmall)),
                    Text(ok ? 'Ready for payouts' : 'Not ready', style: AppTypography.label(color)),
                  ]),
                  const SizedBox(height: AppSpacing.sm),
                  if (p.hasBankDetails) ...[
                    Text(p.accountHolder ?? '', style: theme.textTheme.bodyMedium),
                    Text('${p.bankName ?? ''} · ${p.accountMasked} · IFSC ${p.ifscMasked ?? ''}', style: theme.textTheme.bodySmall),
                  ] else
                    Text('No bank account on file.', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text('Payout method: ${p.payoutMethodLabel}', style: theme.textTheme.bodySmall),
                  if (p.requiredAction != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
                      const SizedBox(width: 6),
                      Expanded(child: Text(p.requiredAction!, style: theme.textTheme.bodySmall)),
                    ]),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  Text('Full account numbers are never shown in the app. Bank details are managed in your business profile.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textTertiary)),
                ],
              ),
            );
          },
        );
  }
}

class _BreakdownGrid extends ConsumerWidget {
  const _BreakdownGrid({required this.operatorId});

  final String operatorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(earningsBreakdownProvider(operatorId)).when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load your earnings.', onRetry: () => ref.invalidate(earningsBreakdownProvider(operatorId))),
          data: (b) {
            Widget tile(String label, int cents, {String? hint, Color? color}) => _Tile(label: label, cents: cents, hint: hint, color: color);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (b.commissionUnresolvedCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: AppCard(
                      child: Text('${b.commissionUnresolvedCount} ticket(s) are waiting for thirty8 to set your commission rate, so their net amount is not final yet.', style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                  childAspectRatio: 1.9,
                  children: [
                    tile('Ticket revenue', b.grossCents, hint: '${b.tickets} tickets'),
                    tile('thirty8 commission', b.commissionCents, hint: 'Rate frozen per ticket'),
                    tile('Your net earnings', b.netCents, hint: 'After commission'),
                    tile('Waiting for boarding', b.pendingBoardingCents, hint: 'Earned once passengers board'),
                    tile('Boarded, next settlement', b.eligibleCents, hint: 'Included in the next weekly batch', color: b.eligibleCents > 0 ? AppColors.warning : null),
                    tile('On hold', b.onHoldCents, hint: 'Refund or review in progress'),
                    tile('In a settlement', b.processingCents, hint: 'Being paid out', color: AppColors.info),
                    tile('Paid to you', b.settledCents, hint: 'Confirmed by the bank', color: AppColors.success),
                    tile('Refund adjustments', b.refundAdjustmentCents, hint: 'Reduced by cancellations', color: b.refundAdjustmentCents > 0 ? AppColors.error : null),
                    tile('Recovery balance', b.recoveryOpenCents, hint: 'To be netted from payouts', color: b.recoveryOpenCents > 0 ? AppColors.error : null),
                  ],
                ),
              ],
            );
          },
        );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.cents, this.hint, this.color});

  final String label;
  final int cents;
  final String? hint;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label, style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(formatMoney(cents), style: theme.textTheme.titleLarge?.copyWith(color: color))),
          if (hint != null) Text(hint!, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _Recoveries extends ConsumerWidget {
  const _Recoveries({required this.operatorId});

  final String operatorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fmt = DateFormat('d MMM yyyy');
    return ref.watch(operatorRecoveriesProvider(operatorId)).when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load recoveries.', onRetry: () => ref.invalidate(operatorRecoveriesProvider(operatorId))),
          data: (rows) => rows.isEmpty
              ? const AppEmptyState(icon: Icons.check_circle_outline, message: 'Nothing is owed to thirty8.')
              : Column(children: [
                  for (final r in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(child: Text('Outstanding ${formatMoney(r.outstandingCents)}', style: theme.textTheme.titleSmall)),
                            Text(r.statusLabel, style: AppTypography.label(r.status == 'recovered' ? AppColors.success : AppColors.warning)),
                          ]),
                          Text('Original ${formatMoney(r.amountCents)} · recovered ${formatMoney(r.recoveredCents)} · ${fmt.format(r.createdAt)}', style: theme.textTheme.bodySmall),
                          if (r.reason.isNotEmpty) Text(r.reason, style: theme.textTheme.bodySmall),
                        ]),
                      ),
                    ),
                ]),
        );
  }
}

class _Adjustments extends ConsumerWidget {
  const _Adjustments({required this.operatorId});

  final String operatorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fmt = DateFormat('d MMM yyyy');
    return ref.watch(refundAdjustmentsProvider(operatorId)).when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(message: 'Could not load refund adjustments.', onRetry: () => ref.invalidate(refundAdjustmentsProvider(operatorId))),
          data: (rows) => rows.isEmpty
              ? const AppEmptyState(icon: Icons.confirmation_number_outlined, message: 'No tickets have been cancelled or refunded.')
              : Column(children: [
                  for (final r in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(child: Text(r.ticketReference, style: theme.textTheme.titleSmall)),
                            Text(r.statusLabel, style: AppTypography.label(r.refundStatus == 'processed' ? AppColors.success : AppColors.warning)),
                          ]),
                          const SizedBox(height: 4),
                          _line(theme, 'Ticket amount', formatMoney(r.originalAmountCents)),
                          if (r.refundAmountCents != null) _line(theme, 'Refunded to the customer', formatMoney(r.refundAmountCents!)),
                          if ((r.cancellationDeductionCents ?? 0) > 0) _line(theme, 'Cancellation deduction', formatMoney(r.cancellationDeductionCents!)),
                          if (r.commissionAdjustmentCents > 0) _line(theme, 'Commission returned', formatMoney(r.commissionAdjustmentCents)),
                          if (r.netImpactCents != null) _line(theme, 'Effect on your earnings', formatMoney(r.netImpactCents!), color: r.netImpactCents! < 0 ? AppColors.error : AppColors.success),
                          if (r.afterPayout) Text('This ticket had already been paid out, so the amount is recovered from your next payouts.', style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
                          if (r.processedAt != null) Text('Processed ${fmt.format(r.processedAt!)}', style: theme.textTheme.bodySmall),
                        ]),
                      ),
                    ),
                ]),
        );
  }

  Widget _line(ThemeData theme, String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          Text(value, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: color)),
        ]),
      );
}
