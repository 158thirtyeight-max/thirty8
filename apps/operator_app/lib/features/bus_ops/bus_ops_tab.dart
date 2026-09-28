import 'package:flutter/material.dart';

import '../../core/operator_providers.dart';
import 'fleet_list_screen.dart';
import 'routes_list_screen.dart';
import 'services_list_screen.dart';

/// Bus-operator workspace: Fleet (buses) / Routes / Trips, as its own
/// sub-navigation inside the "Bus" bottom-nav tab.
class BusOpsTab extends StatelessWidget {
  const BusOpsTab({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bus operations'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Fleet'),
            Tab(text: 'Routes'),
            Tab(text: 'Trips'),
          ]),
        ),
        body: TabBarView(children: [
          FleetListScreen(context: context),
          RoutesListScreen(context: context),
          ServicesListScreen(context: context),
        ]),
      ),
    );
  }
}
