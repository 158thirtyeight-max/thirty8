import 'package:flutter/material.dart';

import 'bus_setup_screen.dart';
import 'fleet_status.dart';
import 'stage_review_screen.dart';

/// Opens the right screen for a bus action chosen on a card or the dashboard.
/// Returns when the user comes back so callers can refresh.
Future<void> openBusAction(
  BuildContext context, {
  required String operatorId,
  required Map<String, dynamic> bus,
  required BusAction action,
}) {
  final busId = bus['id'] as String;
  final nav = Navigator.of(context);
  switch (action) {
    case BusAction.submit:
    case BusAction.activate:
    case BusAction.deactivate:
    case BusAction.viewReason:
      return nav.push(MaterialPageRoute(builder: (_) => StageReviewScreen(operatorId: operatorId, busId: busId)));
    case BusAction.manageFare:
    case BusAction.manageSchedule:
      final key = action == BusAction.manageFare ? 'fare' : 'schedule';
      final stage = busSetupStages.firstWhere((s) => s.key == key);
      return nav.push(MaterialPageRoute(builder: (c) => stage.builder(c, operatorId, bus)));
    case BusAction.continueSetup:
    case BusAction.viewDetails:
      return nav.push(MaterialPageRoute(builder: (_) => BusSetupScreen(operatorId: operatorId, busId: busId)));
  }
}
