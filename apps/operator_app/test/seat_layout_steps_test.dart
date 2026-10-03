import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/bus_ops/seat_layout/seat_layout_model.dart';
import 'package:operator_app/features/bus_ops/seat_layout/wizard_steps.dart';

void main() {
  Widget host(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

  Future<void> phone(WidgetTester t) async {
    t.view.physicalSize = const Size(390 * 3, 780 * 3);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
  }

  testWidgets('steps render at phone width without errors', (t) async {
    await phone(t);
    final d = SeatLayoutDraft(capacity: 40, reserved: 2)..generateGrid();
    for (final w in [
      CapacityStep(draft: d, onChanged: () {}),
      ArrangementStep(draft: d, onChanged: () {}),
      SeatMapStep(draft: d, onChanged: () {}),
      NumberingStep(draft: d, onChanged: () {}),
      ReviewStep(draft: d),
    ]) {
      await t.pumpWidget(host(w));
      await t.pump();
      expect(tester(t), isNull);
    }
  });

  testWidgets('manual numbering editor renders and tap opens seat sheet', (t) async {
    await phone(t);
    final d = SeatLayoutDraft(capacity: 8)..generateGrid();
    d.numbering = NumberingMethod.manual;
    await t.pumpWidget(host(NumberingStep(draft: d, onChanged: () {})));
    await t.pump();
    expect(t.takeException(), isNull);

    d.numbering = NumberingMethod.rowWise;
    await t.pumpWidget(host(SeatMapStep(draft: d, onChanged: () {})));
    await t.tap(find.text('1A'));
    await t.pumpAndSettle();
    expect(find.text('Remove seat'), findsOneWidget);
  });
}

Object? tester(WidgetTester t) => t.takeException();
