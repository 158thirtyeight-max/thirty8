import 'package:flutter/material.dart';

import '../../core/operator_providers.dart';
import 'cargo_vehicles_screen.dart';
import 'shipment_queue_screen.dart';

/// Cargo-operator workspace: Shipments (accept/reject/track) / Vehicles.
class CargoOpsTab extends StatelessWidget {
  const CargoOpsTab({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Cargo operations'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Shipments'),
            Tab(text: 'Vehicles'),
          ]),
        ),
        body: TabBarView(children: [
          ShipmentQueueScreen(context: context),
          CargoVehiclesScreen(context: context),
        ]),
      ),
    );
  }
}
