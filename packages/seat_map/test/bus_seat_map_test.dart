import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seat_map/seat_map.dart';

MapSeat s(String code, int row, int col, SeatStatus st, {int deck = 1, String type = 'seater'}) =>
    MapSeat(seatId: code, code: code, deck: deck, row: row, col: col, status: st, rev: 1, seatType: type);

Widget host(Widget child, {double width = 360}) => MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: width, child: SingleChildScrollView(child: child)))),
    );

void main() {
  const layout2x1 = SeatLayoutConfig(rows: 3, cols: 4, decks: 1, aisleCols: {3});

  testWidgets('draws the real seat codes at their positions and leaves the aisle empty', (tester) async {
    // 2 + 1 layout: cols 1,2 seats, col 3 aisle, col 4 single seat
    await tester.pumpWidget(host(BusSeatMap(
      layout: layout2x1,
      seats: [
        s('1A', 1, 1, SeatStatus.available),
        s('1B', 1, 2, SeatStatus.booked),
        s('1C', 1, 4, SeatStatus.held),
        s('2A', 2, 1, SeatStatus.blocked),
      ],
    )));
    expect(find.text('1A'), findsOneWidget);
    expect(find.text('1B'), findsOneWidget);
    expect(find.text('1C'), findsOneWidget);
    expect(find.text('2A'), findsOneWidget);
    expect(find.text('3A'), findsNothing); // no seat is invented

    // positions: 1A left of 1B; 1C to the right past the aisle gap
    final a = tester.getCenter(find.text('1A')).dx;
    final b = tester.getCenter(find.text('1B')).dx;
    final c = tester.getCenter(find.text('1C')).dx;
    expect(a < b, isTrue);
    expect(c - b, greaterThan(b - a), reason: 'the aisle makes the gap before 1C larger than between 1A and 1B');
  });

  testWidgets('tap reports the seat; status is exposed to accessibility, not colour only', (tester) async {
    MapSeat? tapped;
    await tester.pumpWidget(host(BusSeatMap(
      layout: layout2x1,
      seats: [s('1A', 1, 1, SeatStatus.available), s('1B', 1, 2, SeatStatus.booked)],
      onSeatTap: (seat) => tapped = seat,
    )));
    await tester.tap(find.text('1B'));
    expect(tapped?.code, '1B');
    expect(find.bySemanticsLabel('Seat 1A, Available'), findsOneWidget);
    expect(find.bySemanticsLabel('Seat 1B, Booked'), findsOneWidget);
    expect(find.byIcon(Icons.person), findsOneWidget, reason: 'booked seats carry an icon');
  });

  testWidgets('selected seats are announced as selected', (tester) async {
    await tester.pumpWidget(host(BusSeatMap(
      layout: layout2x1,
      seats: [s('1A', 1, 1, SeatStatus.available)],
      selectedSeatIds: const {'1A'},
    )));
    expect(find.bySemanticsLabel('Seat 1A, selected'), findsOneWidget);
  });

  testWidgets('a double-deck bus shows one deck at a time with a deck switcher', (tester) async {
    await tester.pumpWidget(host(BusSeatMap(
      layout: const SeatLayoutConfig(rows: 1, cols: 2, decks: 2, aisleCols: {}),
      seats: [
        s('L1', 1, 1, SeatStatus.available, deck: 1, type: 'sleeper'),
        s('U1', 1, 1, SeatStatus.booked, deck: 2, type: 'sleeper'),
      ],
    )));
    expect(find.text('L1'), findsOneWidget);
    expect(find.text('U1'), findsNothing);
    expect(find.text('Lower deck'), findsOneWidget);
    await tester.tap(find.text('Upper deck'));
    await tester.pump();
    expect(find.text('U1'), findsOneWidget);
    expect(find.text('L1'), findsNothing);
  });

  testWidgets('empty seat list shows an empty state', (tester) async {
    await tester.pumpWidget(host(const BusSeatMap(layout: layout2x1, seats: [])));
    expect(find.text('No seats to show.'), findsOneWidget);
  });

  testWidgets('does not overflow on a 320 dp wide phone with a 5-column layout', (tester) async {
    final seats = [
      for (var r = 1; r <= 8; r++)
        for (final c in [1, 2, 4, 5]) s('$r${String.fromCharCode(64 + c)}', r, c, SeatStatus.available),
    ];
    await tester.pumpWidget(host(
      BusSeatMap(layout: const SeatLayoutConfig(rows: 8, cols: 5, decks: 1, aisleCols: {3}), seats: seats),
      width: 320,
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unverified availability is visually dimmed', (tester) async {
    await tester.pumpWidget(host(BusSeatMap(
      layout: layout2x1,
      seats: [s('1A', 1, 1, SeatStatus.available), s('1B', 1, 2, SeatStatus.booked)],
      dimAvailable: true,
    )));
    final opacities = tester.widgetList<Opacity>(find.byType(Opacity)).map((o) => o.opacity).toList();
    expect(opacities.where((o) => o < 1).length, 1, reason: 'only the available seat is dimmed');
  });

  testWidgets('legend lists each status with a label', (tester) async {
    await tester.pumpWidget(host(const SeatStatusLegend(showSelected: true)));
    for (final t in ['Available', 'Held', 'Booked', 'Blocked', 'Selected']) {
      expect(find.text(t), findsOneWidget);
    }
  });
}
