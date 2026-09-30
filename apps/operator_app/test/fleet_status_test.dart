import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/fleet_status.dart';
import 'package:operator_app/features/fleet/fleet_providers.dart';

Map<String, dynamic> completeness({bool complete = false, List<Map<String, dynamic>>? items}) => {
      'complete': complete,
      'percent': complete ? 100 : 50,
      'items': items ??
          [
            for (final s in busSections) {'key': s, 'label': busSectionLabels[s], 'section': s, 'ok': complete},
          ],
    };

Map<String, dynamic> bus(String lifecycle, {bool legacy = false, String? migration, String? approvedBy, String? reason}) => {
      'lifecycle_status': lifecycle,
      'is_legacy': legacy,
      'legacy_migration_status': migration,
      'approved_by': approvedBy,
      'review_reason': reason,
    };

void main() {
  test('section states group items and list what is missing', () {
    final s = sectionStates(completeness(items: [
      {'key': 'name', 'label': 'Bus name', 'section': 'basic', 'ok': true},
      {'key': 'ext', 'label': 'Exterior photograph', 'section': 'basic', 'ok': false},
      {'key': 'doc:rc', 'label': 'RC', 'section': 'documents', 'ok': true},
      {'key': 'route', 'label': 'Route', 'section': 'route', 'ok': false},
    ]));
    expect(s['basic']!.ok, isFalse);
    expect(s['basic']!.missing, ['Exterior photograph']);
    expect(s['documents']!.ok, isTrue);
    expect(s['route']!.missing, ['Route']);
    expect(s['seats']!.ok, isFalse); // no items for the section -> not done
  });

  test('null completeness is safe', () {
    expect(sectionStates(null)['route']!.ok, isFalse);
    expect(isBusComplete(null), isFalse);
    expect(busPercent(null), 0);
  });

  group('actions by state', () {
    test('draft: continue until complete, then submit', () {
      expect(busActions(bus('draft'), completeness()), [BusAction.continueSetup]);
      expect(busActions(bus('draft'), completeness(complete: true)), [BusAction.submit, BusAction.continueSetup]);
    });
    test('changes requested shows the reason', () {
      final a = busActions(bus('changes_requested', reason: 'Blurry'), completeness(complete: true));
      expect(a, [BusAction.viewReason, BusAction.submit, BusAction.continueSetup]);
    });
    test('under review is read-only', () {
      expect(busActions(bus('under_review'), completeness(complete: true)), [BusAction.viewDetails]);
      expect(busHeadline(bus('submitted'), null), 'Awaiting approval');
    });
    test('approved offers activation; active offers fares/schedule/deactivate', () {
      expect(busActions(bus('approved', approvedBy: 'x'), completeness(complete: true)).first, BusAction.activate);
      final a = busActions(bus('active', approvedBy: 'x'), completeness(complete: true));
      expect(a, containsAll([BusAction.manageFare, BusAction.manageSchedule, BusAction.deactivate]));
    });
    test('rejected (inactive, never approved) cannot be reactivated by the operator', () {
      final a = busActions(bus('inactive', reason: 'Docs invalid'), null);
      expect(a, [BusAction.viewReason, BusAction.viewDetails]);
      expect(busHeadline(bus('inactive'), null), 'Rejected');
      final off = busActions(bus('inactive', approvedBy: 'x'), null);
      expect(off, contains(BusAction.activate));
      expect(busHeadline(bus('inactive', approvedBy: 'x'), null), 'Inactive');
    });
    test('suspended', () {
      expect(busActions(bus('suspended', reason: 'Complaint'), null), [BusAction.viewReason, BusAction.viewDetails]);
    });
  });

  group('legacy buses', () {
    test('are clearly labelled and stay operable', () {
      final b = bus('active', legacy: true);
      expect(busVerificationState(b), 'legacy');
      expect(busHeadline(b, completeness()), 'Legacy — not yet verified');
      expect(busActions(b, completeness()), [BusAction.continueSetup, BusAction.manageFare, BusAction.manageSchedule]);
      expect(busActions(b, completeness(complete: true)).first, BusAction.submit);
    });
    test('migration review states keep the bus active but read-only for the operator', () {
      final b = bus('active', legacy: true, migration: 'submitted');
      expect(effectiveBusState(b), 'legacy_submitted');
      expect(isAwaitingReview(b), isTrue);
      expect(busActions(b, completeness(complete: true)), [BusAction.viewDetails]);
    });
    test('changes requested on a legacy migration', () {
      final b = bus('active', legacy: true, migration: 'changes_requested', reason: 'Add PUC');
      expect(busActions(b, completeness(complete: true)).first, BusAction.viewReason);
    });
  });

  test('dashboard status word', () {
    expect(dashboardBusStatus(bus('draft'), completeness()), 'Setup incomplete');
    expect(dashboardBusStatus(bus('active', legacy: true), null), 'Legacy');
  });
}
