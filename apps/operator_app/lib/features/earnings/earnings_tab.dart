import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/operator_providers.dart';
import '../../core/services/operator_services.dart';
import '../bus_ops/trip_detail_screen.dart';
import '../charts/analytics_charts.dart';
import 'earnings_models.dart';
import 'payouts_screen.dart';
import 'settlement_detail_screen.dart';

/// Global Earnings: shared by every enabled service, with service-wise separation.
/// All figures come from the backend ledger RPCs; gross sales are never shown as money paid out.
class EarningsTab extends ConsumerStatefulWidget {
  const EarningsTab({super.key, required this.context});

  final OperatorContext context;

  @override
  ConsumerState<EarningsTab> createState() => _EarningsTabState();
}

class _EarningsTabState extends ConsumerState<EarningsTab> {
  DatePreset _preset = DatePreset.thisMonth;
  DateTime? _customFrom;
  DateTime? _customTo;
  String _service = 'all'; // all | bus | cargo | shopping

  OperatorContext get _ctx => widget.context;

  ({DateTime from, DateTime to}) get _range => rangeFor(_preset, DateTime.now(), customFrom: _customFrom, customTo: _customTo);

  EarningsQuery get _query => EarningsQuery(_ctx.operatorId, _range.from, _range.to, _service == 'all' ? 'bus' : _service);

  Future<void> _pickPreset(DatePreset p) async {
    if (p == DatePreset.custom) {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 3),
        lastDate: DateTime(now.year + 1),
        initialDateRange: DateTimeRange(start: _range.from, end: _range.to),
      );
      if (picked == null) return;
      setState(() {
        _preset = DatePreset.custom;
        _customFrom = picked.start;
        _customTo = picked.end;
      });
    } else {
      setState(() => _preset = p);
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(earningsSummaryProvider(_query));
    ref.invalidate(revenueTrendProvider(_query));
    ref.invalidate(earningsByTripProvider(_query));
    ref.invalidate(settlementsProvider(_ctx.operatorId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_ctx.isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Earnings')),
        body: const Center(
          child: AppEmptyState(icon: Icons.lock_outline, message: 'Earnings are visible to the account owner.'),
        ),
      );
    }

    final servicesAsync = ref.watch(operatorServicesProvider(_ctx.operatorId));
    final visible = servicesAsync.value == null ? <ServiceDefinition>[] : visibleServices(servicesAsync.value!);
    // The filter only appears when there is more than one service to choose between.
    final showFilter = visible.length > 1;
    final range = _range;
    final fmt = DateFormat('d MMM yyyy');

    return Scaffold(
      appBar: AppBar(title: const Text('Earnings')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            AppCard(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PayoutsScreen(operatorId: _ctx.operatorId))),
              child: Row(children: [
                const Icon(Icons.account_balance_outlined, color: AppColors.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Payouts, refunds & recoveries', style: theme.textTheme.titleSmall),
                    Text('Your payout account, what is waiting for the next settlement, and cancelled tickets.', style: theme.textTheme.bodySmall),
                  ]),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ]),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final p in DatePreset.values)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: AppChip(label: p.label, selected: _preset == p, onTap: () => _pickPreset(p)),
                  ),
              ]),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              range.from == range.to ? fmt.format(range.from) : '${fmt.format(range.from)} – ${fmt.format(range.to)}',
              style: theme.textTheme.bodySmall,
            ),
            if (showFilter) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                height: 40,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: AppChip(label: 'All services', selected: _service == 'all', onTap: () => setState(() => _service = 'all')),
                  ),
                  for (final d in visible)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: AppChip(label: d.name, selected: _service == d.type.key, onTap: () => setState(() => _service = d.type.key)),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            ref.watch(earningsSummaryProvider(_query)).when(
                  loading: () => const AppLoadingState(),
                  error: (e, _) => AppErrorState(message: 'Could not load earnings.', onRetry: _refresh),
                  data: (s) => !s.supported ? _Unsupported(service: _service) : _Body(ctx: _ctx, query: _query, summary: s, allServices: _service == 'all' && showFilter),
                ),
          ],
        ),
      ),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.service});

  final String service;

  @override
  Widget build(BuildContext context) => AppEmptyState(
        icon: Icons.account_balance_wallet_outlined,
        message: '${service[0].toUpperCase()}${service.substring(1)} earnings will appear here once they are available.',
      );
}

class _Body extends ConsumerWidget {
  const _Body({required this.ctx, required this.query, required this.summary, required this.allServices});

  final OperatorContext ctx;
  final EarningsQuery query;
  final EarningsSummary summary;
  final bool allServices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = summary;
    final theme = Theme.of(context);

    Widget tile(String label, int cents, {String? hint, Color? color}) => _MoneyTile(label: label, cents: cents, hint: hint, color: color);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (allServices)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text('Totals currently cover Bus. Other services are added here as their earnings become available.', style: theme.textTheme.bodySmall),
          ),
        if (!s.commissionConfigured)
          _Notice(icon: Icons.info_outline, text: 'The platform commission rate has not been set yet, so platform fees show as ₹0 and net payable is before commission.'),
        if (s.discrepancyCents != 0)
          _Notice(icon: Icons.warning_amber_rounded, text: 'Money received differs from ticket sales by ${formatMoney(s.discrepancyCents)} in this period. This is flagged for review.'),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          childAspectRatio: 1.9,
          children: [
            tile('Gross sales', s.grossSalesCents, hint: '${s.ticketsSold} tickets'),
            tile('Refunds', s.refundsCompletedCents, hint: s.refundsInitiatedCents > 0 ? '${formatMoney(s.refundsInitiatedCents)} initiated' : 'Completed', color: AppColors.error),
            tile('Platform fees', s.platformFeesCents, hint: s.feesAreEstimate ? 'Estimated until settled' : 'Settled'),
            tile('Net payable', s.netPayableCents, hint: 'After fees'),
            tile('Paid to operator', s.paidToOperatorCents, hint: 'From verified payouts', color: AppColors.success),
            tile('Pending settlement', s.pendingSettlementCents, hint: 'Not yet paid out', color: s.pendingSettlementCents > 0 ? AppColors.warning : null),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _TicketSales(summary: s),
        const SizedBox(height: AppSpacing.sm),
        ref.watch(revenueTrendProvider(query)).when(
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(message: 'Could not load the revenue trend.', onRetry: () => ref.invalidate(revenueTrendProvider(query))),
              data: (points) => RevenueTrendChart(points: points),
            ),
        const SizedBox(height: AppSpacing.sm),
        SettlementStatusChart(buckets: s.settlements),
        const SizedBox(height: AppSpacing.lg),
        Text('Settlement history', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        _Settlements(ctx: ctx),
        const SizedBox(height: AppSpacing.lg),
        Text('Earnings by trip', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        _TripEarnings(ctx: ctx, query: query),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: AppCard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: AppColors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          ]),
        ),
      );
}

class _MoneyTile extends StatelessWidget {
  const _MoneyTile({required this.label, required this.cents, this.hint, this.color});

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
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(formatMoney(cents), style: theme.textTheme.titleLarge?.copyWith(color: color)),
          ),
          if (hint != null) Text(hint!, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _TicketSales extends StatelessWidget {
  const _TicketSales({required this.summary});

  final EarningsSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final theme = Theme.of(context);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Text(value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ]),
        );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ticket sales (Bus)', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          row('Total tickets sold', '${s.ticketsSold}'),
          row('Total gross ticket value', formatMoney(s.grossSalesCents)),
          row('Completed bookings', '${s.completedBookings}'),
          row('Cancelled bookings', '${s.cancelledBookings}'),
          row('Refunds completed', formatMoney(s.refundsCompletedCents)),
          row('Net booking value', formatMoney(s.grossSalesCents)),
          row('Money collected', formatMoney(s.collectedCents)),
        ],
      ),
    );
  }
}

class _Settlements extends ConsumerWidget {
  const _Settlements({required this.ctx});

  final OperatorContext ctx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(settlementsProvider(ctx.operatorId));
    final fmt = DateFormat('d MMM yyyy');
    final theme = Theme.of(context);
    return async.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(message: 'Could not load settlements.', onRetry: () => ref.invalidate(settlementsProvider(ctx.operatorId))),
      data: (rows) => rows.isEmpty
          ? const AppEmptyState(icon: Icons.receipt_long_outlined, message: 'No settlements yet. They appear here once thirty8 settles your completed trips.')
          : Column(children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettlementDetailScreen(settlementId: r.id))),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text(r.reference, style: theme.textTheme.titleSmall)),
                          SettlementBadge(status: r.status),
                        ]),
                        const SizedBox(height: 2),
                        Text(formatMoney(r.netPayableCents), style: theme.textTheme.titleMedium),
                        Text(
                          'Initiated ${r.initiatedAt == null ? '—' : fmt.format(r.initiatedAt!)}'
                          '${r.completedAt == null ? '' : ' · Paid ${fmt.format(r.completedAt!)}'}',
                          style: theme.textTheme.bodySmall,
                        ),
                        if (r.method != null || r.txnReference != null)
                          Text('${r.method?.replaceAll('_', ' ') ?? ''}${r.txnReference == null ? '' : ' · ${r.txnReference}'}', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
            ]),
    );
  }
}

class _TripEarnings extends ConsumerWidget {
  const _TripEarnings({required this.ctx, required this.query});

  final OperatorContext ctx;
  final EarningsQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(earningsByTripProvider(query));
    final fmt = DateFormat('EEE, d MMM');
    final theme = Theme.of(context);
    return async.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(message: 'Could not load trips.', onRetry: () => ref.invalidate(earningsByTripProvider(query))),
      data: (rows) => rows.isEmpty
          ? const AppEmptyState(icon: Icons.directions_bus_outlined, message: 'No trips in this period.')
          : Column(children: [
              for (final t in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TripDetailScreen(tripId: t.tripId, operatorContext: ctx))),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text(t.routeLabel, style: theme.textTheme.titleSmall)),
                          AppBadge(status: t.status),
                        ]),
                        Text('${t.busRegistration} · ${fmt.format(t.departureAt)} · ${t.soldTickets} tickets', style: theme.textTheme.bodySmall),
                        const SizedBox(height: 4),
                        Row(children: [
                          Expanded(child: Text('Gross ${formatMoney(t.grossCents)}', style: theme.textTheme.bodyMedium)),
                          Text('Net ${formatMoney(t.netPayableCents)}', style: theme.textTheme.bodyMedium),
                        ]),
                        Text(
                          t.remainingCents == 0 ? 'Fully settled' : 'Outstanding ${formatMoney(t.remainingCents)}',
                          style: theme.textTheme.bodySmall?.copyWith(color: t.remainingCents == 0 ? AppColors.success : AppColors.warning),
                        ),
                      ],
                    ),
                  ),
                ),
            ]),
    );
  }
}
