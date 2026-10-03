import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/core/services/operator_services.dart';

OperatorService svc(ServiceType t, String state, {String? source, String? reason}) => OperatorService.fromRow({
      'service_type': t.key,
      'state': state,
      'suspension_source': source,
      'suspension_reason': reason,
    })!;

void main() {
  group('service state', () {
    test('parses every backend state and round-trips', () {
      for (final s in ServiceState.values) {
        expect(ServiceStateX.parse(s.key), s);
      }
      expect(ServiceStateX.parse('garbage'), ServiceState.notSelected);
      expect(ServiceStateX.parse(null), ServiceState.notSelected);
    });

    test('only active is operational; selection is not approval', () {
      expect(ServiceState.active.isOperational, isTrue);
      for (final s in ServiceState.values.where((s) => s != ServiceState.active)) {
        expect(s.isOperational, isFalse, reason: s.key);
      }
      expect(ServiceState.pendingApproval.isSelected, isTrue);
      expect(ServiceState.disabled.isSelected, isFalse);
      expect(ServiceState.notSelected.isSelected, isFalse);
    });
  });

  group('visibleServices', () {
    test('bus-only operator sees only Bus', () {
      final services = {ServiceType.bus: svc(ServiceType.bus, 'active')};
      expect(visibleServices(services).map((d) => d.type), [ServiceType.bus]);
    });

    test('bus + cargo in registry order; shopping hidden unless selected', () {
      final services = {
        ServiceType.cargo: svc(ServiceType.cargo, 'pending_approval'),
        ServiceType.bus: svc(ServiceType.bus, 'active'),
      };
      expect(visibleServices(services).map((d) => d.type), [ServiceType.bus, ServiceType.cargo]);
    });

    test('no services, or only disabled ones, shows nothing', () {
      expect(visibleServices({}), isEmpty);
      expect(visibleServices({ServiceType.bus: svc(ServiceType.bus, 'disabled')}), isEmpty);
    });

    test('pending approval is visible but not operational', () {
      final services = {ServiceType.bus: svc(ServiceType.bus, 'pending_approval')};
      expect(visibleServices(services), hasLength(1));
      expect(serviceIsOperational(services, ServiceType.bus), isFalse);
    });

    test('shopping is registered as not yet available', () {
      expect(serviceDefinition(ServiceType.shopping).available, isFalse);
      expect(serviceDefinition(ServiceType.bus).available, isTrue);
    });
  });

  test('admin suspension is distinguishable from operator-status suspension', () {
    expect(svc(ServiceType.bus, 'suspended', source: 'admin').suspendedByAdmin, isTrue);
    expect(svc(ServiceType.bus, 'suspended', source: 'operator_status').suspendedByAdmin, isFalse);
  });

  test('describeDisableImpact lists only non-zero items', () {
    final lines = describeDisableImpact({
      'active_trips': 1,
      'upcoming_trips': 0,
      'confirmed_bookings': 12,
      'pending_bookings': 0,
      'active_shipments': 0,
      'unsettled_cents': 150050,
    });
    expect(lines, hasLength(3));
    expect(lines.last, contains('1500.50'));
    expect(describeDisableImpact({}), isEmpty);
  });

  test('role and business labels never expose raw identifiers', () {
    expect(roleLabel('operator_admin'), 'Owner / Admin');
    expect(roleLabel('operator_staff'), 'Staff');
    expect(roleLabel('something_else'), 'Team member');
    expect(businessTypeLabel('both'), 'Bus & cargo operator');
  });
}
