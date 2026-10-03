import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/operator_providers.dart';
import '../earnings/earnings_tab.dart';
import '../operations/operations_screen.dart';
import '../profile/profile_tab.dart';
import '../bus_ops/bus_module_screen.dart';
import '../bus_ops/schedule_trip_screen.dart';
import '../bus_ops/trip_models.dart';
import 'home_tab.dart';

/// Fixed four-tab workspace: Home | Operations | Earnings | Profile.
/// New services (Cargo, Shopping, ...) appear inside Operations — never as
/// additional bottom tabs. Each tab keeps its own navigation stack.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.context});

  final OperatorContext context;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

enum _Tab { home, operations, earnings, profile }

class _HomeShellState extends State<HomeShell> {
  _Tab _tab = _Tab.home;
  final _navKeys = {for (final t in _Tab.values) t: GlobalKey<NavigatorState>()};

  void _select(_Tab tab) {
    if (tab == _tab) {
      // Re-tapping the current tab returns to its root.
      _navKeys[tab]!.currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _tab = tab);
    }
  }

  /// Switches to Operations and opens [screen] there, on top of the Operations landing page.
  void _openOperations(Widget screen) {
    setState(() => _tab = _Tab.operations);
    final nav = _navKeys[_Tab.operations]!.currentState;
    nav?.popUntil((r) => r.isFirst);
    nav?.push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  void _handleBack() {
    final nav = _navKeys[_tab]!.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    } else if (_tab != _Tab.home) {
      setState(() => _tab = _Tab.home);
    } else {
      SystemNavigator.pop();
    }
  }

  Widget _root(_Tab tab) {
    final ctx = widget.context;
    return switch (tab) {
      _Tab.home => HomeTab(
          context: ctx,
          actions: HomeActions(
            chooseServices: () => _select(_Tab.profile),
            openBus: () => _openOperations(BusModuleScreen(context: ctx)),
            scheduleTrip: () => _openOperations(ScheduleTripScreen(context: ctx)),
            viewTrips: () => _openOperations(BusModuleScreen(context: ctx, initialTab: 1)),
            viewLiveTrips: () => _openOperations(BusModuleScreen(context: ctx, initialTab: 1, initialBucket: TripBucket.active)),
            viewEarnings: () => _select(_Tab.earnings),
          ),
        ),
      _Tab.operations => OperationsScreen(context: ctx, onChooseServices: () => _select(_Tab.profile)),
      _Tab.earnings => EarningsTab(context: ctx),
      _Tab.profile => ProfileTab(context: ctx),
    };
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab.index,
          children: [
            for (final t in _Tab.values)
              Navigator(
                key: _navKeys[t],
                onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => _root(t)),
              ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab.index,
          onDestinationSelected: (i) => _select(_Tab.values[i]),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.business_center_outlined), selectedIcon: Icon(Icons.business_center), label: 'Operations'),
            NavigationDestination(icon: Icon(Icons.account_balance_wallet_outlined), selectedIcon: Icon(Icons.account_balance_wallet), label: 'Earnings'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}
