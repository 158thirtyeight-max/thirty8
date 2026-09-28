import 'package:flutter/material.dart';

import '../../core/operator_providers.dart';
import '../bus_ops/bus_ops_tab.dart';
import '../cargo_ops/cargo_ops_tab.dart';
import '../profile/profile_tab.dart';
import 'dashboard_tab.dart';

/// Bottom-navigation shell. Tabs adapt to the operator's business_type: a
/// bus-only operator never sees the Cargo tab and vice versa.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.context});

  final OperatorContext context;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final ctx = widget.context;
    final tabs = <Widget>[DashboardTab(context: ctx)];
    final destinations = <NavigationDestination>[
      const NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
    ];

    if (ctx.servesBus) {
      tabs.add(BusOpsTab(context: ctx));
      destinations.add(const NavigationDestination(
        icon: Icon(Icons.directions_bus_outlined),
        selectedIcon: Icon(Icons.directions_bus),
        label: 'Bus',
      ));
    }
    if (ctx.servesCargo) {
      tabs.add(CargoOpsTab(context: ctx));
      destinations.add(const NavigationDestination(
        icon: Icon(Icons.local_shipping_outlined),
        selectedIcon: Icon(Icons.local_shipping),
        label: 'Cargo',
      ));
    }

    tabs.add(ProfileTab(context: ctx));
    destinations.add(const NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'));

    final safeIndex = _index >= tabs.length ? 0 : _index;

    return Scaffold(
      body: IndexedStack(index: safeIndex, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: safeIndex,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: destinations,
      ),
    );
  }
}
