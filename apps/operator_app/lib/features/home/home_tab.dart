import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/operator_providers.dart';
import '../../core/services/operator_services.dart';
import '../bus_ops/trip_detail_screen.dart';
import '../earnings/earnings_models.dart';
import '../fleet/fleet_providers.dart';
import '../notifications/notifications.dart';
import 'home_models.dart';

/// Navigation hooks supplied by the shell (Home never owns the other tabs' stacks).
class HomeActions {
  const HomeActions({
    required this.chooseServices,
    required this.openBus,
    required this.scheduleTrip,
    required this.viewTrips,
    required this.viewLiveTrips,
    required this.viewEarnings,
  });

  final VoidCallback chooseServices;
  final VoidCallback openBus;
  final VoidCallback scheduleTrip;
  final VoidCallback viewTrips;
  final VoidCallback viewLiveTrips;
  final VoidCallback viewEarnings;
}

/// Consolidated business overview. Only services the operator enabled appear; every number
/// is read from the backend. Nothing here is a placeholder figure.
class HomeTab extends ConsumerWidget {
  const HomeTab({super.key, required this.context, required this.actions});

  final OperatorContext context;
  final HomeActions actions;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(operatorServicesProvider(context.operatorId));
    ref.invalidate(homeSummaryProvider(context.operatorId));
    ref.invalidate(cargoHomeStatsProvider(context.operatorId));
    ref.invalidate(busesProvider(context.operatorId));
  }

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final servicesAsync = ref.watch(operatorServicesProvider(context.operatorId));
    return Scaffold(
      appBar: AppBar(title: Text(context.operator['name'] as String? ?? 'Home'), actions: const [NotificationsBell()]),
      body: RefreshIndicator(
        onRefresh: () => _refresh(ref),
        child: servicesAsync.when(
          loading: () => ListView(children: const [AppLoadingState()]),
          error: (e, _) => ListView(children: [AppErrorState(message: 'Could not load your business.', onRetry: () => _refresh(ref))]),
          data: (services) {
            final visible = visibleServices(services);
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                _BusinessStatus(context: context, services: services, visible: visible),
                const SizedBox(height: AppSpacing.md),
                if (visible.isEmpty)
                  AppEmptyState(
                    icon: Icons.business_center_outlined,
                    message: 'No services selected yet.',
                    action: AppButton(label: 'Choose Services', onPressed: actions.chooseServices),
                  ),
                for (final def in visible)
                  switch (def.type) {
                    ServiceType.bus => _BusSection(context: context, actions: actions, service: services[def.type]!),
                    ServiceType.cargo => _CargoSection(context: context, service: services[def.type]!),
                    ServiceType.shopping => const SizedBox.shrink(),
                  },
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BusinessStatus extends StatelessWidget {
  const _BusinessStatus({required this.context, required this.services, required this.visible});

  final OperatorContext context;
  final Map<ServiceType, OperatorService> services;
  final List<ServiceDefinition> visible;

  @override
  Widget build(BuildContext buildContext) {
    final theme = Theme.of(buildContext);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Business status', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          Row(children: [
            Expanded(child: Text('Operator approval', style: theme.textTheme.bodyMedium)),
            AppBadge(status: context.applicationStatus),
          ]),
          for (final def in visible)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Row(children: [
                Expanded(child: Text('${def.name} service', style: theme.textTheme.bodyMedium)),
                AppBadge(status: services[def.type]!.state.key),
              ]),
            ),
        ],
      ),
    );
  }
}

class _BusSection extends ConsumerWidget {
  const _BusSection({required this.context, required this.actions, required this.service});

  final OperatorContext context;
  final HomeActions actions;
  final OperatorService service;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final theme = Theme.of(buildContext);
    final fmt = DateFormat('h:mm a');
    final dayFmt = DateFormat('EEE, d MMM · h:mm a');

    if (!service.state.isOperational) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: AppCard(
          child: Text(
            switch (service.state) {
              ServiceState.pendingApproval => 'Bus is awaiting approval. Trips and sales will appear here once it is active.',
              ServiceState.setupRequired => 'Finish your business setup to start using Bus.',
              ServiceState.suspended => 'Bus is suspended. Contact support.',
              _ => 'Bus is not active.',
            },
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final async = ref.watch(homeSummaryProvider(context.operatorId));
    final buses = ref.watch(busesProvider(context.operatorId)).value;

    return async.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(message: 'Could not load Bus activity.', onRetry: () => ref.invalidate(homeSummaryProvider(context.operatorId))),
      data: (s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Bus', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (buses != null && buses.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Add your first bus to start setting up routes, fares and trips.'),
                  const SizedBox(height: AppSpacing.sm),
                  AppButton(label: 'Add a bus', icon: Icons.add, size: AppButtonSize.small, onPressed: actions.openBus),
                ]),
              ),
            ),
          _Metrics(summary: s),
          const SizedBox(height: AppSpacing.md),
          Text("Today's activity", style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          if (s.today.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm), child: Text('No trips today.', style: theme.textTheme.bodySmall))
          else
            for (final t in s.today) _TripRow(trip: t, subtitle: '${fmt.format(t.departureAt)} · ${t.busRegistration}', context: context),
          const SizedBox(height: AppSpacing.md),
          Row(children: [
            Expanded(child: Text('Upcoming trips', style: theme.textTheme.titleSmall)),
            if (s.upcoming.isNotEmpty) TextButton(onPressed: actions.viewTrips, child: const Text('View all')),
          ]),
          if (s.upcoming.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm), child: Text('No upcoming trips scheduled.', style: theme.textTheme.bodySmall))
          else
            for (final t in s.upcoming) _TripRow(trip: t, subtitle: '${dayFmt.format(t.departureAt)} · ${t.busRegistration}', context: context),
          const SizedBox(height: AppSpacing.md),
          Text('Quick actions', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          Wrap(spacing: AppSpacing.sm, runSpacing: AppSpacing.sm, children: [
            if (context.isApproved && context.isAdmin)
              AppButton(label: 'Schedule Trip', icon: Icons.add, size: AppButtonSize.small, onPressed: actions.scheduleTrip),
            AppButton(label: 'View Live Trips', icon: Icons.sensors, size: AppButtonSize.small, variant: AppButtonVariant.outline, onPressed: actions.viewLiveTrips),
            if (s.financialsVisible)
              AppButton(label: 'View Earnings', icon: Icons.account_balance_wallet_outlined, size: AppButtonSize.small, variant: AppButtonVariant.outline, onPressed: actions.viewEarnings),
          ]),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.summary});

  final HomeSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final tiles = <(String, String, IconData)>[
      ("Today's trips", '${s.todaysTrips}', Icons.today),
      ('Active trips', '${s.activeTrips}', Icons.directions_bus),
      ('Tickets sold today', '${s.ticketsSoldToday}', Icons.confirmation_number_outlined),
      if (s.financialsVisible) ("Today's ticket sales", formatMoney(s.todaysTicketSalesCents ?? 0), Icons.currency_rupee),
      if (s.financialsVisible) ('Pending payout', formatMoney(s.pendingPayoutCents ?? 0), Icons.hourglass_bottom),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppSpacing.sm,
      crossAxisSpacing: AppSpacing.sm,
      childAspectRatio: 1.9,
      children: [
        for (final t in tiles)
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(children: [
                  Icon(t.$3, size: 16, color: AppColors.textTertiary),
                  const SizedBox(width: 4),
                  Expanded(child: Text(t.$1, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
                const SizedBox(height: 2),
                FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(t.$2, style: Theme.of(context).textTheme.titleLarge)),
              ],
            ),
          ),
      ],
    );
  }
}

class _TripRow extends StatelessWidget {
  const _TripRow({required this.trip, required this.subtitle, required this.context});

  final HomeTrip trip;
  final String subtitle;
  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: AppListItem(
          title: trip.routeLabel,
          subtitle: '$subtitle · ${trip.soldSeats}/${trip.totalSeats} sold',
          trailing: AppBadge(status: trip.status),
          onTap: () => Navigator.of(buildContext).push(
            MaterialPageRoute<void>(builder: (_) => TripDetailScreen(tripId: trip.id, operatorContext: context)),
          ),
        ),
      ),
    );
  }
}

class _CargoSection extends ConsumerWidget {
  const _CargoSection({required this.context, required this.service});

  final OperatorContext context;
  final OperatorService service;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    if (!service.state.isOperational) return const SizedBox.shrink();
    final theme = Theme.of(buildContext);
    final async = ref.watch(cargoHomeStatsProvider(context.operatorId));
    return async.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(message: 'Could not load Cargo activity.', onRetry: () => ref.invalidate(cargoHomeStatsProvider(context.operatorId))),
      data: (c) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cargo', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Row(children: [
              Expanded(child: AppStatCard(label: 'Awaiting acceptance', value: '${c.awaitingAcceptance}', icon: Icons.inbox)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: AppStatCard(label: 'In transit', value: '${c.inTransit}', icon: Icons.local_shipping)),
            ]),
          ],
        ),
      ),
    );
  }
}
