import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../operator_providers.dart';
import '../supabase_providers.dart';

/// Services an operator can run. Cargo/Shopping are architecturally supported;
/// only modules whose [ServiceDefinition.available] is true get an operational UI.
enum ServiceType { bus, cargo, shopping }

extension ServiceTypeX on ServiceType {
  String get key => name;
  static ServiceType? parse(String? v) {
    for (final t in ServiceType.values) {
      if (t.name == v) return t;
    }
    return null;
  }
}

/// Mirrors the Postgres enum `operator_service_state`.
enum ServiceState { notSelected, selected, setupRequired, pendingApproval, active, suspended, disabled }

extension ServiceStateX on ServiceState {
  String get key => switch (this) {
        ServiceState.notSelected => 'not_selected',
        ServiceState.selected => 'selected',
        ServiceState.setupRequired => 'setup_required',
        ServiceState.pendingApproval => 'pending_approval',
        ServiceState.active => 'active',
        ServiceState.suspended => 'suspended',
        ServiceState.disabled => 'disabled',
      };

  String get label => switch (this) {
        ServiceState.notSelected => 'Not selected',
        ServiceState.selected => 'Selected',
        ServiceState.setupRequired => 'Setup required',
        ServiceState.pendingApproval => 'Pending approval',
        ServiceState.active => 'Active',
        ServiceState.suspended => 'Suspended',
        ServiceState.disabled => 'Disabled',
      };

  static ServiceState parse(String? v) => ServiceState.values.firstWhere(
        (s) => s.key == v,
        orElse: () => ServiceState.notSelected,
      );

  /// The operator turned it on (it appears in Operations), regardless of approval.
  bool get isSelected =>
      this == ServiceState.selected ||
      this == ServiceState.setupRequired ||
      this == ServiceState.pendingApproval ||
      this == ServiceState.active ||
      this == ServiceState.suspended;

  /// Operational screens (new trips, buses, ...) may be used.
  bool get isOperational => this == ServiceState.active;
}

class ServiceDefinition {
  const ServiceDefinition({
    required this.type,
    required this.name,
    required this.description,
    required this.icon,
    required this.available,
  });

  final ServiceType type;
  final String name;
  final String description;
  final IconData icon;

  /// False for services that are not built yet ("Coming soon").
  final bool available;
}

/// Static registry. Adding a service = one entry here + its module screen in
/// Operations; the bottom navigation never changes.
const List<ServiceDefinition> serviceDefinitions = [
  ServiceDefinition(
    type: ServiceType.bus,
    name: 'Bus',
    description: 'Manage vehicles, passenger bookings, trips, and tracking.',
    icon: Icons.directions_bus,
    available: true,
  ),
  ServiceDefinition(
    type: ServiceType.cargo,
    name: 'Cargo',
    description: 'Manage parcel bookings, shipment tracking, and deliveries.',
    icon: Icons.local_shipping,
    available: true,
  ),
  ServiceDefinition(
    type: ServiceType.shopping,
    name: 'Shopping',
    description: 'Manage products, inventory, customer orders, and fulfilment.',
    icon: Icons.storefront,
    available: false,
  ),
];

ServiceDefinition serviceDefinition(ServiceType t) => serviceDefinitions.firstWhere((d) => d.type == t);

class OperatorService {
  const OperatorService({required this.type, required this.state, this.suspensionSource, this.suspensionReason});

  final ServiceType type;
  final ServiceState state;
  final String? suspensionSource;
  final String? suspensionReason;

  bool get suspendedByAdmin => state == ServiceState.suspended && suspensionSource == 'admin';

  static OperatorService? fromRow(Map<String, dynamic> row) {
    final type = ServiceTypeX.parse(row['service_type'] as String?);
    if (type == null) return null;
    return OperatorService(
      type: type,
      state: ServiceStateX.parse(row['state'] as String?),
      suspensionSource: row['suspension_source'] as String?,
      suspensionReason: row['suspension_reason'] as String?,
    );
  }
}

/// All service rows for an operator, keyed by type. Missing = not selected.
final operatorServicesProvider =
    FutureProvider.autoDispose.family<Map<ServiceType, OperatorService>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  final rows = await supabase.from('operator_services').select().eq('operator_id', operatorId);
  final out = <ServiceType, OperatorService>{};
  for (final row in rows) {
    final s = OperatorService.fromRow(row);
    if (s != null) out[s.type] = s;
  }
  return out;
});

/// Services shown in Operations: selected by the operator (any approval state),
/// in registry order.
List<ServiceDefinition> visibleServices(Map<ServiceType, OperatorService> services) => [
      for (final def in serviceDefinitions)
        if (services[def.type]?.state.isSelected ?? false) def,
    ];

/// Whether an operator-selected service can be used operationally.
bool serviceIsOperational(Map<ServiceType, OperatorService> services, ServiceType t) =>
    services[t]?.state.isOperational ?? false;

/// Result of `set_operator_service`.
class ServiceChangeResult {
  const ServiceChangeResult({required this.ok, this.state, this.impact});

  final bool ok;
  final ServiceState? state;

  /// Non-null when the change needs confirmation (disable with open work).
  final Map<String, dynamic>? impact;

  bool get needsConfirmation => !ok && impact != null;
}

Future<ServiceChangeResult> setOperatorService(
  WidgetRef ref,
  OperatorContext ctx,
  ServiceType type,
  bool enable, {
  bool confirm = false,
}) async {
  final supabase = ref.read(supabaseProvider);
  final res = await supabase.rpc('set_operator_service', params: {
    'p_operator_id': ctx.operatorId,
    'p_service': type.key,
    'p_enable': enable,
    'p_confirm': confirm,
  }) as Map<String, dynamic>;
  ref.invalidate(operatorServicesProvider(ctx.operatorId));
  if (res['ok'] == true) {
    return ServiceChangeResult(ok: true, state: ServiceStateX.parse(res['state'] as String?));
  }
  return ServiceChangeResult(ok: false, impact: res['impact'] as Map<String, dynamic>?);
}

/// Human-readable lines for the disable-confirmation dialog.
List<String> describeDisableImpact(Map<String, dynamic> impact) {
  int n(String k) => (impact[k] as num?)?.toInt() ?? 0;
  final lines = <String>[];
  if (n('active_trips') > 0) lines.add('${n('active_trips')} trip(s) in progress');
  if (n('upcoming_trips') > 0) lines.add('${n('upcoming_trips')} upcoming trip(s)');
  if (n('confirmed_bookings') > 0) lines.add('${n('confirmed_bookings')} confirmed booking(s) on open trips');
  if (n('pending_bookings') > 0) lines.add('${n('pending_bookings')} booking(s) awaiting payment');
  if (n('active_shipments') > 0) lines.add('${n('active_shipments')} shipment(s) in progress');
  final unsettled = n('unsettled_cents');
  if (unsettled > 0) lines.add('₹${(unsettled / 100).toStringAsFixed(2)} in sales not yet settled');
  return lines;
}

/// Friendly role labels — never show raw DB role identifiers.
String roleLabel(String role) => switch (role) {
      'operator_admin' => 'Owner / Admin',
      'operator_staff' => 'Staff',
      'driver' => 'Driver',
      'conductor' => 'Conductor',
      _ => 'Team member',
    };

String businessTypeLabel(String type) => switch (type) {
      'bus' => 'Bus operator',
      'cargo' => 'Cargo operator',
      'both' => 'Bus & cargo operator',
      _ => type,
    };
