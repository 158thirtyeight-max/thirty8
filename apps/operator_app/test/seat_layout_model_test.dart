import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/seat_layout_model.dart';

const _cfg = LayoutConfig(rows: 3, cols: 3, decks: 1, aisleCols: {2});

Map<CellKey, SeatCell> _cells(List<(int, int, int, SeatKind, bool)> l) => {
      for (final c in l) (c.$1, c.$2, c.$3): SeatCell(kind: c.$4, sleeper: c.$5),
    };

void main() {
  group('numbering', () {
    test('row/letter skips aisle columns', () {
      final cells = _cells([
        (1, 1, 1, SeatKind.bookable, false),
        (1, 1, 3, SeatKind.bookable, false),
        (1, 2, 1, SeatKind.bookable, false),
      ]);
      final codes = generateSeatCodes(_cfg, cells);
      expect(codes[(1, 1, 1)], '1A');
      expect(codes[(1, 1, 3)], '1B');
      expect(codes[(1, 2, 1)], '2A');
    });
    test('sequential, sleeper prefixes and crew', () {
      final cfg = _cfg.copyWith(numbering: Numbering.sequential, decks: 2);
      final cells = _cells([
        (1, 1, 1, SeatKind.crew, false),
        (1, 1, 3, SeatKind.bookable, true),
        (2, 1, 3, SeatKind.bookable, true),
      ]);
      final codes = generateSeatCodes(cfg, cells);
      expect(codes[(1, 1, 1)], 'DRV');
      expect(codes[(1, 1, 3)], 'L1');
      expect(codes[(2, 1, 3)], 'U2');
    });
  });

  group('validation', () {
    final good = _cells([
      (1, 1, 3, SeatKind.crew, false),
      (1, 2, 1, SeatKind.bookable, false),
      (1, 2, 3, SeatKind.bookable, false),
      (1, 3, 1, SeatKind.bookable, false),
      (1, 3, 3, SeatKind.reserved, false),
    ]);

    test('valid seater layout, capacity counts only bookable seats', () {
      final v = validateLayout(config: _cfg, cells: good, busType: 'ac_seater', capacity: 3);
      expect(v.errors, isEmpty);
      expect(v.warnings, isEmpty);
    });

    test('capacity mismatch', () {
      final v = validateLayout(config: _cfg, cells: good, busType: 'ac_seater', capacity: 4);
      expect(v.errors.single, contains('do not match the bus capacity'));
    });

    test('no seats / no bookable seats', () {
      expect(validateLayout(config: _cfg, cells: {}, busType: 'ac_seater', capacity: 1).errors,
          contains('The layout has no seats'));
      final none = _cells([(1, 1, 1, SeatKind.unavailable, false)]);
      expect(validateLayout(config: _cfg, cells: none, busType: 'ac_seater', capacity: 1).errors,
          contains('At least one seat must be available for booking'));
    });

    test('aisle, outside grid, missing deck', () {
      final bad = _cells([
        (1, 1, 2, SeatKind.bookable, false), // aisle
        (1, 9, 1, SeatKind.bookable, false), // outside
        (3, 1, 1, SeatKind.bookable, false), // deck 3
      ]);
      final e = validateLayout(config: _cfg, cells: bad, busType: 'ac_seater', capacity: 3).errors.join('|');
      expect(e, contains('on the aisle'));
      expect(e, contains('outside the layout grid'));
      expect(e, contains('deck that does not exist'));
    });

    test('sleeper berth in a seater bus and vice versa', () {
      final sl = _cells([(1, 1, 1, SeatKind.bookable, true)]);
      expect(validateLayout(config: _cfg, cells: sl, busType: 'ac_seater', capacity: 1).errors.join(),
          contains('sleeper berths but this is a seater bus'));
      final st = _cells([(1, 1, 1, SeatKind.bookable, false)]);
      expect(validateLayout(config: _cfg, cells: st, busType: 'ac_sleeper', capacity: 1).errors.join(),
          contains('not sleeper berths but this is a sleeper bus'));
    });

    test('semi-sleeper allows a mix', () {
      final mix = _cells([
        (1, 1, 1, SeatKind.bookable, false),
        (1, 1, 3, SeatKind.bookable, true),
      ]);
      expect(validateLayout(config: _cfg, cells: mix, busType: 'ac_semi_sleeper', capacity: 2).errors, isEmpty);
    });

    test('two-deck sleeper: upper needs a lower below; empty upper deck rejected', () {
      final cfg = _cfg.copyWith(decks: 2);
      final orphan = _cells([
        (2, 1, 1, SeatKind.bookable, true),
        (1, 1, 3, SeatKind.bookable, true),
      ]);
      expect(validateLayout(config: cfg, cells: orphan, busType: 'ac_sleeper', capacity: 2).errors.join(),
          contains('no lower berth in the same position'));
      final onlyLower = _cells([(1, 1, 1, SeatKind.bookable, true)]);
      expect(validateLayout(config: cfg, cells: onlyLower, busType: 'ac_sleeper', capacity: 1).errors.join(),
          contains('upper deck has no seats'));
      final paired = _cells([
        (1, 1, 1, SeatKind.bookable, true),
        (2, 1, 1, SeatKind.bookable, true),
      ]);
      expect(validateLayout(config: cfg, cells: paired, busType: 'ac_sleeper', capacity: 2).errors, isEmpty);
    });

    test('crew positions are exempt from seat-type rules', () {
      final cells = _cells([
        (1, 1, 1, SeatKind.crew, false),
        (1, 1, 3, SeatKind.bookable, true),
      ]);
      expect(validateLayout(config: _cfg, cells: cells, busType: 'ac_sleeper', capacity: 1).errors, isEmpty);
    });

    test('bad dimensions', () {
      final v = validateLayout(
        config: const LayoutConfig(rows: 50, cols: 9, decks: 3, aisleCols: {}),
        cells: {},
        busType: 'ac_seater',
        capacity: 1,
      );
      expect(v.errors.join(), contains('1-40 rows'));
      expect(v.errors.join(), contains('Decks must be 1 or 2'));
    });
  });

  group('payload', () {
    test('seatsToJson sets berth by deck and crew has no berth', () {
      final cfg = _cfg.copyWith(decks: 2);
      final cells = _cells([
        (1, 1, 1, SeatKind.crew, false),
        (1, 2, 1, SeatKind.bookable, true),
        (2, 2, 1, SeatKind.bookable, true),
      ]);
      final json = seatsToJson(cfg, cells, 'ac_sleeper');
      final crew = json.firstWhere((s) => s['kind'] == 'crew');
      expect(crew['berth'], isNull);
      expect(crew['seat_type'], 'sleeper'); // base type of a sleeper bus
      expect(json.firstWhere((s) => s['deck'] == 2)['berth'], 'upper');
      expect(json.firstWhere((s) => s['deck'] == 1 && s['kind'] == 'bookable')['berth'], 'lower');
    });

    test('config json round trip', () {
      final j = _cfg.copyWith(numbering: Numbering.sequential).toJson();
      final c = LayoutConfig.fromJson(j, deckCount: 1)!;
      expect(c.rows, 3);
      expect(c.aisleCols, {2});
      expect(c.numbering, Numbering.sequential);
      expect(LayoutConfig.fromJson({}, deckCount: 1), isNull);
    });
  });

  group('legacy conversion and auto-fill', () {
    test('legacy 4-column grid gets an aisle after column 2', () {
      final seats = [
        for (var r = 1; r <= 2; r++)
          for (var c = 1; c <= 4; c++) {'row_no': r, 'col_no': c, 'deck': 1, 'seat_type': 'seater'},
      ];
      final res = convertLegacySeats(seats, busType: 'ac_seater');
      expect(res.config.cols, 5);
      expect(res.config.aisleCols, {3});
      expect(res.cells.length, 8);
      expect(res.cells.containsKey((1, 1, 3)), isFalse); // aisle column is empty
      expect(res.cells.containsKey((1, 1, 5)), isTrue);
    });

    test('auto-fill skips aisles and stops at count', () {
      final cells = autoFillSeats(const LayoutConfig(rows: 5, cols: 5, decks: 1, aisleCols: {3}), count: 6, sleeper: false);
      expect(cells.length, 6);
      expect(cells.keys.every((k) => k.$3 != 3), isTrue);
    });
  });
}
