import 'package:flutter/material.dart';

import '../../core/operator_providers.dart';
import '../fleet/my_buses_screen.dart';
import 'trip_models.dart';
import 'trips_screen.dart';

/// Bus module (Operations → Bus): Fleet | Trips. Routes are setup data owned by
/// each bus (Manage Bus → Route), not a permanent tab.
class BusModuleScreen extends StatelessWidget {
  const BusModuleScreen({super.key, required this.context, this.initialTab = 0, this.initialBucket = TripBucket.upcoming});

  final OperatorContext context;

  /// 0 = Fleet, 1 = Trips.
  final int initialTab;
  final TripBucket initialBucket;

  @override
  Widget build(BuildContext buildContext) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bus Operations'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Fleet'),
            Tab(text: 'Trips'),
          ]),
        ),
        body: TabBarView(children: [
          MyBusesScreen(context: context),
          TripsScreen(context: context, initialBucket: initialBucket),
        ]),
      ),
    );
  }
}
