import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/seat_layout_model.dart';
import 'package:operator_app/features/fleet/seat_layout_widgets.dart';

void main() {
  final built = buildLayout(
    preset: const AislePreset(2, 2),
    capacity: 9,
    decks: 1,
    sleeper: false,
    cabRow: true,
    driverOnRight: true,
  );

  Widget host(CanvasMode mode, void Function(int, int) onCell, void Function(int) onAisle, {LayoutConfig? config}) {
    final cfg = config ?? built.config;
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: BusCanvas(
            config: cfg,
            cells: built.cells,
            codes: generateSeatCodes(cfg, built.cells),
            deck: 1,
            mode: mode,
            editable: true,
            onCell: onCell,
            onToggleAisle: onAisle,
          ),
        ),
      ),
    );
  }

  testWidgets('shows FRONT / DRIVER, REAR, seat numbers and the driver', (tester) async {
    await tester.pumpWidget(host(CanvasMode.types, (_, _) {}, (_) {}));
    expect(find.text('FRONT / DRIVER'), findsOneWidget);
    expect(find.text('REAR'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.byIcon(Icons.drive_eta), findsOneWidget);
  });

  testWidgets('tapping a seat reports its row and column', (tester) async {
    (int, int)? tapped;
    await tester.pumpWidget(host(CanvasMode.types, (r, c) => tapped = (r, c), (_) {}));
    await tester.tap(find.text('1'));
    expect(tapped, (2, 1)); // first passenger row sits under the cab row
  });

  testWidgets('aisle mode shows column toggles and reports the tapped column', (tester) async {
    int? col;
    await tester.pumpWidget(host(CanvasMode.aisle, (_, _) {}, (c) => col = c));
    expect(find.text('│'), findsOneWidget); // the aisle column
    await tester.tap(find.byIcon(Icons.event_seat_outlined).first);
    expect(col, 1);
  });

  testWidgets('manual numbering shows ? on seats that are not numbered yet', (tester) async {
    final cfg = built.config.copyWith(numbering: Numbering.manual);
    await tester.pumpWidget(host(CanvasMode.number, (_, _) {}, (_) {}, config: cfg));
    expect(find.text('?'), findsNWidgets(8));
  });
}
