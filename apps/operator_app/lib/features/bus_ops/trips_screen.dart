import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/operator_providers.dart';
import 'schedule_trip_screen.dart';
import 'trip_detail_screen.dart';
import 'trip_models.dart';

/// Operations → Bus → Trips: the daily working list. Filtered by bucket
/// (Upcoming / Active / Completed, Cancelled behind a secondary chip). When
/// [busId] is set the list is limited to that bus (Manage Bus → Trips).
class TripsScreen extends ConsumerStatefulWidget {
  const TripsScreen({super.key, required this.context, this.busId, this.showScheduleButton = true, this.initialBucket = TripBucket.upcoming});

  final OperatorContext context;
  final String? busId;
  final bool showScheduleButton;
  final TripBucket initialBucket;

  @override
  ConsumerState<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends ConsumerState<TripsScreen> {
  late TripBucket _bucket = widget.initialBucket;

  OperatorContext get _ctx => widget.context;

  TripQuery get _query => TripQuery(_ctx.operatorId, _bucket, widget.busId);

  Future<void> _schedule() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ScheduleTripScreen(context: _ctx, initialBusId: widget.busId)),
    );
    for (final b in TripBucket.values) {
      ref.invalidate(operatorTripsProvider(TripQuery(_ctx.operatorId, b, widget.busId)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(operatorTripsProvider(_query));
    final counts = async.value?.counts;

    return Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              children: [
                for (final b in TripBucket.values)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: AppChip(
                      label: counts == null ? b.label : '${b.label} (${counts[b] ?? 0})',
                      selected: _bucket == b,
                      onTap: () => setState(() => _bucket = b),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.refresh(operatorTripsProvider(_query).future),
              child: async.when(
                loading: () => const Center(child: AppLoadingState()),
                error: (e, _) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    AppErrorState(message: 'Could not load trips.', onRetry: () => ref.invalidate(operatorTripsProvider(_query))),
                  ],
                ),
                data: (result) => result.items.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [AppEmptyState(message: _bucket.emptyMessage, icon: Icons.event_busy_outlined)],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, 88),
                        itemCount: result.items.length,
                        itemBuilder: (c, i) => Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: TripCard(
                            trip: result.items[i],
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => TripDetailScreen(tripId: result.items[i].id, operatorContext: _ctx),
                                ),
                              );
                              ref.invalidate(operatorTripsProvider(_query));
                            },
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: widget.showScheduleButton && _ctx.isApproved
          ? FloatingActionButton.extended(
              onPressed: _schedule,
              icon: const Icon(Icons.add),
              label: const Text('Schedule Trip'),
            )
          : null,
    );
  }
}

/// One trip in a list. Shows the route once, the bus, when it runs and how full it is.
class TripCard extends StatelessWidget {
  const TripCard({super.key, required this.trip, required this.onTap});

  final OperatorTrip trip;
  final VoidCallback onTap;

  static final _date = DateFormat('EEE, d MMM');
  static final _time = DateFormat('h:mm a');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final arr = trip.arrivalAt;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(trip.routeLabel, style: theme.textTheme.titleMedium)),
              AppBadge(status: trip.status),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${trip.busRegistration} · ${_date.format(trip.departureAt)} · '
            '${_time.format(trip.departureAt)}${arr == null ? '' : ' – ${_time.format(arr)}'}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: trip.soldFraction, minHeight: 6),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('${trip.soldSeats}/${trip.totalSeats} sold', style: theme.textTheme.labelLarge),
            ],
          ),
          if (trip.heldSeats > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('${trip.heldSeats} held at checkout', style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
