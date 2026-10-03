import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../fleet/route_revision_screen.dart';
import 'route_detail_screen.dart';
import 'route_history_screen.dart';
import 'route_summary.dart';

/// A route can be changed while the bus is being set up or once it is approved / active; it is locked
/// while the bus is under admin review or suspended.
bool routeEditAllowed(RouteSummary s) {
  const allowed = {'draft', 'changes_requested', 'approved', 'active'};
  return allowed.contains(s.bus['lifecycle_status']);
}

/// Opens the revision editor (starting a draft, or resuming the open one). The live route is never
/// edited directly.
Future<void> openRouteEditor(
  BuildContext context,
  WidgetRef ref, {
  required OperatorContext ctx,
  required RouteSummary summary,
  bool returnRoute = false,
  String? baseRevisionId,
}) async {
  if (summary.isPending) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('A change is already waiting for admin approval. Withdraw it from the route details to make a new one.'),
    ));
    return;
  }
  if (!routeEditAllowed(summary)) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The route is locked while this bus is under review.')));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => RouteRevisionScreen(
      operatorId: ctx.operatorId,
      bus: summary.bus,
      isOperatorAdmin: ctx.isAdmin,
      revisionId: summary.hasDraft && baseRevisionId == null ? summary.openRevisionId : null,
      baseRevisionId: baseRevisionId,
      startWithReturn: returnRoute,
    ),
  ));
  ref.invalidate(operatorRouteSummariesProvider(ctx.operatorId));
}

void openRouteDetail(BuildContext context, RouteSummary summary, OperatorContext ctx) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => RouteDetailScreen(summary: summary, ctx: ctx)));
}

void openRouteHistory(BuildContext context, RouteSummary summary, OperatorContext ctx) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => RouteHistoryScreen(summary: summary, ctx: ctx)));
}
