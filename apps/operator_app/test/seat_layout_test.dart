import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/bus_ops/seat_layout/numbering.dart';
import 'package:operator_app/features/bus_ops/seat_layout/seat_layout_model.dart';
import 'package:operator_app/features/bus_ops/seat_layout/validation.dart';

void main() {
  SeatLayoutDraft draft() => SeatLayoutDraft(capacity: 8, reserved: 1, crew: 1, unavailable: 1)..generateGrid();

  test('generateGrid fills capacity by kind', () {
    final d = draft();
    expect(d.configured, 8);
    expect(d.countKind(SeatKind.passenger), 5);
    expect(d.countKind(SeatKind.reserved), 1);
    expect(d.rows, 2);
  });

  for (final m in NumberingMethod.values) {
    test('${m.name} labels are unique', () {
      final labels = computeLabels(draft().cells, m);
      expect(labels.values.toSet().length, labels.length);
    });
  }

  test('row-wise matches legacy codes', () {
    final labels = computeLabels(draft().cells, NumberingMethod.rowWise);
    expect(labels[cellKey(1, 1)], '1A');
    expect(labels[cellKey(2, 4)], '2D');
  });

  test('switching numbering never changes the grid and keeps manual labels', () {
    final d = draft();
    final before = d.cells.keys.toList();
    d.manualLabels[cellKey(1, 1)] = 'X1';
    d.numbering = NumberingMethod.columnWise;
    d.numbering = NumberingMethod.manual;
    expect(d.cells.keys.toList(), before);
    expect(computeLabels(d.cells, d.numbering, manualLabels: d.manualLabels)[cellKey(1, 1)], 'X1');
  });

  test('duplicate manual labels are flagged', () {
    final d = draft()..numbering = NumberingMethod.manual;
    d.manualLabels[cellKey(1, 1)] = 'Z';
    d.manualLabels[cellKey(1, 2)] = 'Z';
    expect(validateLayout(d).any((i) => i.blocking && i.message.contains('Duplicate')), isTrue);
  });

  test('capacity mismatch warns without blocking', () {
    final d = draft()..cells.remove(cellKey(1, 1));
    final issue = validateLayout(d).firstWhere((i) => i.message.contains('capacity'));
    expect(issue.blocking, isFalse);
  });

  test('json round trip and legacy load', () {
    final d = draft()..numbering = NumberingMethod.alphabetical;
    final back = SeatLayoutDraft.fromJson(d.toJson());
    expect(back.cells.length, d.cells.length);
    expect(back.numbering, NumberingMethod.alphabetical);
    expect(SeatLayoutDraft.fromJson({}, fallbackCapacity: 10).configured, 10);
  });
}
