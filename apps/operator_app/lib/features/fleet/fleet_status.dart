/// Pure helpers that turn a bus row + its server-side checklist
/// (`bus_completeness`) into what the operator sees: per-section ticks, a
/// headline, and which actions to offer. Mirrors the workflow rules enforced by
/// submit_bus / activate_bus / admin_review_bus on the server.
library;

const busSections = ['basic', 'documents', 'seats', 'route', 'fare', 'schedule'];

const busSectionLabels = {
  'basic': 'Basic info',
  'documents': 'Documents',
  'seats': 'Seats',
  'route': 'Route',
  'fare': 'Fare',
  'schedule': 'Schedule',
};

class SectionState {
  const SectionState({required this.ok, required this.missing});
  final bool ok;
  final List<String> missing;
}

/// Groups the checklist items by section.
Map<String, SectionState> sectionStates(Map<String, dynamic>? completeness) {
  final out = <String, SectionState>{};
  final items = completeness == null ? const [] : List<Map<String, dynamic>>.from((completeness['items'] as List?) ?? const []);
  for (final s in busSections) {
    final inSection = items.where((i) => i['section'] == s).toList();
    final missing = [for (final i in inSection) if (i['ok'] != true) i['label'] as String];
    out[s] = SectionState(ok: inSection.isNotEmpty && missing.isEmpty, missing: missing);
  }
  return out;
}

bool isBusComplete(Map<String, dynamic>? completeness) => completeness?['complete'] == true;
int busPercent(Map<String, dynamic>? completeness) => (completeness?['percent'] as num?)?.toInt() ?? 0;

/// Legacy migration state, or the lifecycle for a normal bus.
String effectiveBusState(Map<String, dynamic> bus) {
  if (bus['is_legacy'] == true) {
    final m = bus['legacy_migration_status'] as String?;
    return m == null ? 'legacy' : 'legacy_$m';
  }
  return bus['lifecycle_status'] as String? ?? 'draft';
}

bool isAwaitingReview(Map<String, dynamic> bus) {
  final s = effectiveBusState(bus);
  return s == 'submitted' || s == 'under_review' || s == 'legacy_submitted' || s == 'legacy_under_review';
}

enum BusAction { continueSetup, submit, activate, deactivate, viewReason, manageFare, manageSchedule, configureRoute, createTrips, viewDetails }

extension BusActionX on BusAction {
  String get label => switch (this) {
        BusAction.continueSetup => 'Continue Setup',
        BusAction.submit => 'Submit for Approval',
        BusAction.activate => 'Activate',
        BusAction.deactivate => 'Deactivate',
        BusAction.viewReason => 'View Reason',
        BusAction.manageFare => 'Manage Fare',
        BusAction.manageSchedule => 'Manage Schedule',
        BusAction.configureRoute => 'Configure Route',
        BusAction.createTrips => 'Create Trips',
        BusAction.viewDetails => 'View Details',
      };
}

/// One-line status for cards and the dashboard.
String busHeadline(Map<String, dynamic> bus, Map<String, dynamic>? completeness) {
  switch (effectiveBusState(bus)) {
    case 'active':
      return 'Active';
    case 'approved':
      return 'Approved — ready to activate';
    case 'submitted':
    case 'under_review':
    case 'legacy_submitted':
    case 'legacy_under_review':
      return 'Awaiting approval';
    case 'changes_requested':
    case 'legacy_changes_requested':
      return 'Changes requested';
    case 'suspended':
      return 'Suspended';
    case 'inactive':
      return bus['approved_by'] == null ? 'Rejected' : 'Inactive';
    case 'legacy':
      return 'Legacy — not yet verified';
    default:
      return isBusComplete(completeness) ? 'Ready to submit' : 'Setup incomplete';
  }
}

/// Actions to offer, most important first.
List<BusAction> busActions(Map<String, dynamic> bus, Map<String, dynamic>? completeness) {
  final complete = isBusComplete(completeness);
  final hasReason = ((bus['review_reason'] as String?) ?? '').isNotEmpty;

  switch (effectiveBusState(bus)) {
    case 'draft':
      return complete ? [BusAction.submit, BusAction.continueSetup] : [BusAction.continueSetup];
    case 'changes_requested':
    case 'legacy_changes_requested':
      return [
        if (hasReason) BusAction.viewReason,
        if (complete) BusAction.submit,
        BusAction.continueSetup,
      ];
    case 'submitted':
    case 'under_review':
    case 'legacy_submitted':
    case 'legacy_under_review':
      return [BusAction.viewDetails];
    case 'approved':
      return [BusAction.activate, BusAction.viewDetails];
    case 'active':
      return [BusAction.viewDetails, BusAction.createTrips, BusAction.manageFare, BusAction.manageSchedule, BusAction.deactivate];
    case 'legacy':
      return complete ? [BusAction.submit, BusAction.continueSetup] : [BusAction.continueSetup, BusAction.manageFare, BusAction.manageSchedule];
    case 'suspended':
    case 'inactive':
      return [
        if (hasReason) BusAction.viewReason,
        if (bus['approved_by'] != null && effectiveBusState(bus) == 'inactive') BusAction.activate,
        BusAction.viewDetails,
      ];
    default:
      return [BusAction.viewDetails];
  }
}

/// Text for the dashboard: "Bus 2 — Setup Incomplete" style status word.
String dashboardBusStatus(Map<String, dynamic> bus, Map<String, dynamic>? completeness) {
  final h = busHeadline(bus, completeness);
  return h.split(' — ').first;
}
