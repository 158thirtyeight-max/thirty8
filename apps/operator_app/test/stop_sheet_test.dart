import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/bus_ops/stops/stop_schedule.dart';
import 'package:operator_app/features/bus_ops/stops/stop_sheet.dart';

const _cities = [
  {'id': 'c1', 'name': 'Middle Strait'},
  {'id': 'c2', 'name': 'Rangat'},
];

void main() {
  StopSheetResult? result;

  Future<void> open(WidgetTester t, StopDraft stop, {int? nextArrival, double height = 780}) async {
    t.view.physicalSize = Size(390 * 3, height * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    result = null;
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showStopSheet(
              context,
              initial: stop,
              stopNumber: 2,
              cities: _cities,
              prevDeparture: 0,
              nextArrival: nextArrival,
              totalMinutes: 628, // 10:00 -> 20:28
              departureMinuteOfDay: 600,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  StopDraft base() => StopDraft(locationCityId: 'c1', locationName: 'Middle Strait', arrivalOffset: 300);

  testWidgets('purpose section sits after Pickup/Drop and before the arrival slider', (t) async {
    await open(t, base());
    final pickup = t.getTopLeft(find.text('Pickup')).dy;
    final heading = t.getTopLeft(find.text('Stop Purpose & Facilities')).dy;
    final arrives = t.getTopLeft(find.text('Bus arrives')).dy;
    expect(pickup < heading && heading < arrives, isTrue);
    for (final label in ['Meal Break', 'Tea / Refreshment', 'Toilet Break', 'Rest Break', 'Ferry Transfer', 'Passenger Transfer', 'Other']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('sub-options appear only under their parent purpose', (t) async {
    await open(t, base());
    expect(find.text('Lunch'), findsNothing);
    expect(find.text('Coffee'), findsNothing);
    await t.tap(find.text('Meal Break'));
    await t.pumpAndSettle();
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
    await t.tap(find.text('Tea / Refreshment'));
    await t.pumpAndSettle();
    expect(find.text('Coffee'), findsOneWidget);
    await t.tap(find.text('Meal Break'));
    await t.pumpAndSettle();
    expect(find.text('Lunch'), findsNothing);
  });

  testWidgets('meal break adds 20/30/45 quick durations without changing the duration', (t) async {
    await open(t, base());
    expect(find.text('30 min'), findsNothing);
    await t.tap(find.text('Meal Break'));
    await t.pumpAndSettle();
    expect(find.text('20 min'), findsOneWidget);
    expect(find.text('45 min'), findsOneWidget);
    // still the 2 min default: operator stays in control
    expect(find.textContaining('Bus leaves at ${clockLabel(600, 302)}', findRichText: true), findsOneWidget);
    await t.ensureVisible(find.text('30 min'));
    await t.tap(find.text('30 min'));
    await t.pumpAndSettle();
    expect(find.textContaining('Bus leaves at ${clockLabel(600, 330)}', findRichText: true), findsOneWidget);
  });

  testWidgets('lunch stop with 30 min saves structured values and a calculated departure', (t) async {
    await open(t, base());
    await t.tap(find.text('Meal Break'));
    await t.pumpAndSettle();
    await t.tap(find.text('Lunch'));
    await t.ensureVisible(find.text('30 min'));
    await t.tap(find.text('30 min'));
    await t.ensureVisible(find.text('Toilet'));
    await t.tap(find.text('Toilet'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Done'));
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    final s = result!.stop!;
    expect(s.purposes, {'meal_break'});
    expect(s.mealTypes, {'lunch'});
    expect(s.facilities, {'toilet'});
    expect(s.departureOffset, 330);
  });

  testWidgets('removing Meal Break discards its meal types', (t) async {
    await open(t, StopDraft(locationCityId: 'c1', locationName: 'Middle Strait', arrivalOffset: 300, purposes: ['meal_break'], mealTypes: ['dinner']));
    await t.tap(find.text('Meal Break'));
    await t.pumpAndSettle();
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(result!.stop!.purposes, isEmpty);
    expect(result!.stop!.mealTypes, isEmpty);
  });

  testWidgets('durations that would hit the next stop are disabled; fine adjust respects the window', (t) async {
    await open(t, base(), nextArrival: 312); // 12 min of room
    final fifteen = t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '15 min'));
    expect(fifteen.onSelected, isNull);
    final ten = t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '10 min'));
    expect(ten.onSelected, isNotNull);
    await t.tap(find.byIcon(Icons.add));
    await t.pumpAndSettle();
    expect(find.textContaining('Bus arrives'), findsOneWidget);
  });

  testWidgets('overnight arrival shows +1 day', (t) async {
    await open(t, StopDraft(locationCityId: 'c1', locationName: 'Middle Strait', arrivalOffset: 18 * 60 + 55)); // 10:00 + 18h55 = 04:55
    expect(find.text('04:55 (+1 day)'), findsOneWidget);
  });

  testWidgets('Done stays reachable on a short screen and delete returns a delete result', (t) async {
    await open(t, base(), height: 520);
    expect(tester(t), isNull);
    expect(find.text('Done'), findsOneWidget);
    await t.tap(find.byIcon(Icons.delete_outline));
    await t.pumpAndSettle();
    expect(result!.delete, isTrue);
  });
}

Object? tester(WidgetTester t) => t.takeException();
