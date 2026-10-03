import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/core/operator_providers.dart';
import 'package:operator_app/core/services/operator_services.dart';
import 'package:operator_app/features/earnings/earnings_models.dart';
import 'package:operator_app/features/fleet/fleet_providers.dart';
import 'package:operator_app/features/home/home_models.dart';
import 'package:operator_app/features/home/home_shell.dart';
import 'package:operator_app/features/operations/operations_screen.dart';
import 'package:operator_app/features/profile/my_services_section.dart';
import 'package:design_system/design_system.dart';

OperatorContext ctx({String role = 'operator_admin', String status = 'approved', String type = 'bus'}) => OperatorContext(
      role: role,
      operator: {
        'id': 'op1',
        'name': 'Island Travels',
        'business_type': type,
        'status': status,
        'application_status': status == 'approved' ? 'approved' : 'submitted',
        'contact_email': 'a@b.c',
        'contact_phone': '9876543210',
      },
    );

OperatorService svc(ServiceType t, ServiceState s) => OperatorService(type: t, state: s);

Override servicesOverride(Map<ServiceType, OperatorService> m) =>
    operatorServicesProvider('op1').overrideWith((ref) async => m);

Widget app(Widget child, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: AppTheme.light(), home: child),
    );

HomeSummary emptyHome() => const HomeSummary(
      todaysTrips: 0, activeTrips: 0, ticketsSoldToday: 0, today: [], upcoming: [], financialsVisible: true, todaysTicketSalesCents: 0, pendingPayoutCents: 0);

void main() {
  group('Operations shows only the services the operator selected', () {
    testWidgets('no services: empty state with a Choose Services action', (tester) async {
      var chose = false;
      await tester.pumpWidget(app(OperationsScreen(context: ctx(), onChooseServices: () => chose = true), [servicesOverride({})]));
      await tester.pumpAndSettle();
      expect(find.text('No services selected yet.'), findsOneWidget);
      await tester.tap(find.text('Choose Services'));
      expect(chose, isTrue);
      expect(find.text('Bus'), findsNothing);
    });

    testWidgets('bus-only operator sees Bus and not Cargo or Shopping', (tester) async {
      await tester.pumpWidget(app(OperationsScreen(context: ctx(), onChooseServices: () {}), [servicesOverride({ServiceType.bus: svc(ServiceType.bus, ServiceState.active)})]));
      await tester.pumpAndSettle();
      expect(find.text('Bus'), findsOneWidget);
      expect(find.text('Cargo'), findsNothing);
      expect(find.text('Shopping'), findsNothing);
      expect(find.text('Open Bus'), findsOneWidget);
    });

    testWidgets('bus + cargo shows both, in registry order', (tester) async {
      await tester.pumpWidget(app(OperationsScreen(context: ctx(type: 'both'), onChooseServices: () {}), [
        servicesOverride({ServiceType.cargo: svc(ServiceType.cargo, ServiceState.active), ServiceType.bus: svc(ServiceType.bus, ServiceState.active)}),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Bus'), findsOneWidget);
      expect(find.text('Cargo'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Bus')).dy < tester.getTopLeft(find.text('Cargo')).dy, isTrue);
    });

    testWidgets('pending approval shows approval information, not operational actions', (tester) async {
      await tester.pumpWidget(app(OperationsScreen(context: ctx(status: 'pending'), onChooseServices: () {}), [servicesOverride({ServiceType.bus: svc(ServiceType.bus, ServiceState.pendingApproval)})]));
      await tester.pumpAndSettle();
      expect(find.textContaining('awaiting approval'), findsOneWidget);
      expect(find.text('Open Bus'), findsNothing);
    });

    testWidgets('a disabled Bus service is hidden from Operations', (tester) async {
      await tester.pumpWidget(app(OperationsScreen(context: ctx(), onChooseServices: () {}), [servicesOverride({ServiceType.bus: svc(ServiceType.bus, ServiceState.disabled)})]));
      await tester.pumpAndSettle();
      expect(find.text('Bus'), findsNothing);
      expect(find.text('No services selected yet.'), findsOneWidget);
    });

    testWidgets('a suspended service is visible but cannot be opened', (tester) async {
      await tester.pumpWidget(app(OperationsScreen(context: ctx(), onChooseServices: () {}), [servicesOverride({ServiceType.bus: svc(ServiceType.bus, ServiceState.suspended)})]));
      await tester.pumpAndSettle();
      expect(find.text('Bus'), findsOneWidget);
      expect(find.textContaining('suspended'), findsOneWidget);
      expect(find.text('Open Bus'), findsNothing);
    });
  });

  group('Profile → My Services', () {
    testWidgets('lists every service; Shopping is "Coming soon" and cannot be switched on', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: MyServicesSection(context: ctx()))), [servicesOverride({ServiceType.bus: svc(ServiceType.bus, ServiceState.active)})]));
      await tester.pumpAndSettle();
      expect(find.text('Bus'), findsOneWidget);
      expect(find.text('Cargo'), findsOneWidget);
      expect(find.text('Shopping'), findsOneWidget);
      expect(find.text('Coming soon'), findsWidgets);
      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.length, 3);
      expect(switches[2].onChanged, isNull, reason: 'Shopping cannot be enabled');
      expect(switches[0].value, isTrue);
      expect(switches[1].value, isFalse);
    });

    testWidgets('staff cannot change services', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: MyServicesSection(context: ctx(role: 'operator_staff')))), [servicesOverride({ServiceType.bus: svc(ServiceType.bus, ServiceState.active)})]));
      await tester.pumpAndSettle();
      for (final s in tester.widgetList<Switch>(find.byType(Switch))) {
        expect(s.onChanged, isNull);
      }
      expect(find.text('Only the account owner can change services.'), findsWidgets);
    });

    testWidgets('service state badges show approval state, selection does not imply approval', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: MyServicesSection(context: ctx(type: 'both')))), [
        servicesOverride({ServiceType.bus: svc(ServiceType.bus, ServiceState.active), ServiceType.cargo: svc(ServiceType.cargo, ServiceState.pendingApproval)}),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Pending approval'), findsOneWidget);
      expect(find.textContaining('Waiting for approval'), findsOneWidget);
    });

    testWidgets('an admin-suspended service cannot be re-enabled', (tester) async {
      await tester.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: MyServicesSection(context: ctx()))), [
        servicesOverride({ServiceType.bus: const OperatorService(type: ServiceType.bus, state: ServiceState.suspended, suspensionSource: 'admin', suspensionReason: 'Documents expired')}),
      ]));
      await tester.pumpAndSettle();
      expect(find.textContaining('Documents expired'), findsOneWidget);
      expect(tester.widgetList<Switch>(find.byType(Switch)).first.onChanged, isNull);
    });
  });

  group('Home | Operations | Earnings | Profile', () {
    List<Override> shellOverrides() => [
          servicesOverride({}),
          homeSummaryProvider('op1').overrideWith((ref) async => emptyHome()),
          busesProvider('op1').overrideWith((ref) async => <Map<String, dynamic>>[]),
          cargoHomeStatsProvider('op1').overrideWith((ref) async => const CargoHomeStats(awaitingAcceptance: 0, inTransit: 0)),
          earningsSummaryProvider.overrideWith((ref, q) async => EarningsSummary.fromJson({'supported': true})),
        ];

    testWidgets('exactly four bottom tabs; Cargo and Shopping are never tabs', (tester) async {
      await tester.pumpWidget(app(HomeShell(context: ctx(type: 'both')), shellOverrides()));
      await tester.pumpAndSettle();
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations.length, 4);
      expect([for (final d in bar.destinations) (d as NavigationDestination).label], ['Home', 'Operations', 'Earnings', 'Profile']);
    });

    testWidgets('Home with no services offers Choose Services, which opens Profile', (tester) async {
      await tester.pumpWidget(app(HomeShell(context: ctx()), shellOverrides()));
      await tester.pumpAndSettle();
      expect(find.text('No services selected yet.'), findsOneWidget);
      await tester.tap(find.text('Choose Services'));
      await tester.pumpAndSettle();
      expect(find.text('My Services'), findsWidgets);
    });

    testWidgets('each tab keeps its own screen; Operations shows the empty state', (tester) async {
      await tester.pumpWidget(app(HomeShell(context: ctx()), shellOverrides()));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Operations')));
      await tester.pumpAndSettle();
      expect(find.text('No services selected yet.'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Earnings')));
      await tester.pumpAndSettle();
      expect(find.text('Earnings'), findsWidgets);
    });

    testWidgets('staff see a locked Earnings tab', (tester) async {
      await tester.pumpWidget(app(HomeShell(context: ctx(role: 'operator_staff')), shellOverrides()));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Earnings')));
      await tester.pumpAndSettle();
      expect(find.text('Earnings are visible to the account owner.'), findsOneWidget);
    });
  });
}
