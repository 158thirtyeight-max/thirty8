import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/seat_layout_model.dart';

const _cfg = LayoutConfig(rows: 3, cols: 3, decks: 1, aisleCols: {2});

Map<CellKey, SeatCell> _cells(List<(int, int, int, SeatKind, bool)> l) => {
      for (final c in l) (c.$1, c.$2, c.$3): SeatCell(kind: c.$4, sleeper: c.$5),
    };

void main() {
  group('numbering', () {
    final legacy = _cfg.copyWith(numbering: Numbering.rowLetter);
    test('legacy row/letter skips aisle columns', () {
      final cells = _cells([
        (1, 1, 1, SeatKind.bookable, false),
        (1, 1, 3, SeatKind.bookable, false),
        (1, 2, 1, SeatKind.bookable, false),
      ]);
      final codes = generateSeatCodes(legacy, cells);
      expect(codes[(1, 1, 1)], '1A');
      expect(codes[(1, 1, 3)], '1B');
      expect(codes[(1, 2, 1)], '2A');
    });

    // 2 + 2 grid: columns 1,2 | aisle 3 | 4,5
    const grid = LayoutConfig(rows: 2, cols: 5, decks: 1, aisleCols: {3});
    final four = _cells([
      for (var r = 1; r <= 2; r++)
        for (final c in [1, 2, 4, 5]) (1, r, c, SeatKind.bookable, false),
    ]);

    test('row-wise reads left to right, top to bottom', () {
      final codes = generateSeatCodes(grid, four);
      expect([for (final c in [1, 2, 4, 5]) codes[(1, 1, c)]], ['1', '2', '3', '4']);
      expect([for (final c in [1, 2, 4, 5]) codes[(1, 2, c)]], ['5', '6', '7', '8']);
    });

    test('column-wise runs down each column', () {
      final codes = generateSeatCodes(grid.copyWith(numbering: Numbering.columnWise), four);
      expect([for (final r in [1, 2]) codes[(1, r, 1)]], ['1', '2']);
      expect([for (final r in [1, 2]) codes[(1, r, 2)]], ['3', '4']);
      expect([for (final r in [1, 2]) codes[(1, r, 5)]], ['7', '8']);
    });

    test('alphabetical is row letter + position in row', () {
      final codes = generateSeatCodes(grid.copyWith(numbering: Numbering.alphabetical), four);
      expect([for (final c in [1, 2, 4, 5]) codes[(1, 1, c)]], ['A1', 'A2', 'A3', 'A4']);
      expect(codes[(1, 2, 1)], 'B1');
    });

    test('driver and crew are never numbered and do not shift passenger numbers', () {
      final cells = {
        ...four,
        (1, 1, 1): const SeatCell(kind: SeatKind.crew, sleeper: false, role: SeatRole.driver),
        (1, 1, 2): const SeatCell(kind: SeatKind.unavailable, sleeper: false),
      };
      final codes = generateSeatCodes(grid, cells);
      expect(codes[(1, 1, 1)], 'DRV');
      expect(codes[(1, 1, 2)], 'NA');
      expect(codes[(1, 1, 4)], '1');
      expect(codes[(1, 1, 5)], '2');
    });

    test('ladies / accessible seats keep a seat number', () {
      final cells = {
        ...four,
        (1, 1, 1): const SeatCell(kind: SeatKind.reserved, sleeper: false, role: SeatRole.ladies),
      };
      expect(generateSeatCodes(grid, cells)[(1, 1, 1)], '1');
    });

    test('sleeper berths get L/U prefixes in row-wise numbering', () {
      final cfg = _cfg.copyWith(decks: 2);
      final cells = _cells([
        (1, 1, 1, SeatKind.crew, false),
        (1, 1, 3, SeatKind.bookable, true),
        (2, 1, 3, SeatKind.bookable, true),
      ]);
      final codes = generateSeatCodes(cfg, cells);
      expect(codes[(1, 1, 3)], 'L1');
      expect(codes[(2, 1, 3)], 'U2');
    });

    test('manual numbering keeps exactly what the operator assigned', () {
      final cfg = grid.copyWith(numbering: Numbering.manual);
      final cells = {
        (1, 1, 1): const SeatCell(kind: SeatKind.bookable, sleeper: false, number: '7'),
        (1, 1, 2): const SeatCell(kind: SeatKind.bookable, sleeper: false, number: '1'),
        (1, 2, 1): const SeatCell(kind: SeatKind.bookable, sleeper: false),
      };
      final codes = generateSeatCodes(cfg, cells);
      expect(codes[(1, 1, 1)], '7'); // not renumbered by position
      expect(codes[(1, 1, 2)], '1');
      expect(codes[(1, 2, 1)], ''); // not numbered yet
      expect(unnumberedCount(cfg, cells), 1);
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

    test('valid seater layout, capacity is bookable + reserved + crew', () {
      final v = validateLayout(config: _cfg, cells: good, busType: 'ac_seater', capacity: 5);
      expect(v.errors, isEmpty);
      expect(v.warnings, isEmpty);
    });

    test('capacity mismatch is a warning, never silently changed', () {
      final v = validateLayout(config: _cfg, cells: good, busType: 'ac_seater', capacity: 6);
      expect(v.errors, isEmpty);
      expect(v.warnings.single, contains('declared bus capacity is 6'));
    });

    test('more bookable seats than the capacity is an error', () {
      final v = validateLayout(config: _cfg, cells: good, busType: 'ac_seater', capacity: 2);
      expect(v.errors.single, contains('exceed the bus capacity'));
    });

    test('duplicate and missing manual numbers are rejected', () {
      final cfg = _cfg.copyWith(numbering: Numbering.manual);
      final cells = {
        (1, 1, 1): const SeatCell(kind: SeatKind.bookable, sleeper: false, number: '1'),
        (1, 2, 1): const SeatCell(kind: SeatKind.bookable, sleeper: false, number: '1'),
        (1, 3, 1): const SeatCell(kind: SeatKind.bookable, sleeper: false),
      };
      final v = validateLayout(config: cfg, cells: cells, busType: 'ac_seater', capacity: 3);
      expect(v.errors.join('|'), contains('Duplicate seat number 1'));
      expect(v.errors.join('|'), contains('1 seat(s) have not been numbered yet'));
      final ok = {
        ...cells,
        (1, 2, 1): const SeatCell(kind: SeatKind.bookable, sleeper: false, number: '2'),
        (1, 3, 1): const SeatCell(kind: SeatKind.bookable, sleeper: false, number: '3'),
      };
      expect(validateLayout(config: cfg, cells: ok, busType: 'ac_seater', capacity: 3).errors, isEmpty);
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
      expect(validateLayout(config: _cfg, cells: cells, busType: 'ac_sleeper', capacity: 2).errors, isEmpty);
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
      final j = _cfg.copyWith(numbering: Numbering.columnWise, cabRow: true).toJson();
      final c = LayoutConfig.fromJson(j, deckCount: 1)!;
      expect(c.rows, 3);
      expect(c.aisleCols, {2});
      expect(c.numbering, Numbering.columnWise);
      expect(c.cabRow, isTrue);
      expect(LayoutConfig.fromJson({}, deckCount: 1), isNull);
    });

    test('older numbering values still load', () {
      expect(NumberingX.parse('sequential'), Numbering.rowWise);
      expect(NumberingX.parse('row_letter'), Numbering.rowLetter);
      expect(NumberingX.parse(null), Numbering.rowLetter);
    });

    test('only passenger seats are bookable; roles map to non-bookable kinds', () {
      for (final t in PositionType.values) {
        final cell = const SeatCell(kind: SeatKind.bookable, sleeper: false).withType(t);
        expect(cell.kind == SeatKind.bookable, t == PositionType.passenger, reason: t.name);
        expect(cell.type, t, reason: t.name);
      }
      final ladies = const SeatCell(kind: SeatKind.bookable, sleeper: false).withType(PositionType.ladies);
      expect(seatsToJson(_cfg, {(1, 1, 1): ladies}, 'ac_seater').single['role'], 'ladies');
    });

    test('a saved seat row reads back with its role and manual number', () {
      final c = seatCellFromRow({'kind': 'reserved', 'role': 'accessible', 'seat_type': 'seater', 'seat_code': '12'});
      expect(c.type, PositionType.accessible);
      expect(c.number, '12');
      expect(seatCellFromRow({'kind': 'bookable', 'seat_type': 'seater', 'seat_code': 'TMP-1-2-3'}).number, isNull);
      expect(seatCellFromRow({'kind': 'crew', 'seat_type': 'seater', 'seat_code': 'DRV'}).type, PositionType.driver);
    });
  });

  group('legacy conversion and layout builder', () {
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

    test('buildLayout: 40 capacity, 2+2, cab row -> 39 passenger seats + driver', () {
      final b = buildLayout(
          preset: const AislePreset(2, 2), capacity: 40, decks: 1, sleeper: false, cabRow: true, driverOnRight: true);
      final st = layoutStats(b.cells);
      expect(st.bookable, 39);
      expect(st.crew, 1);
      expect(st.configured, 40);
      expect(b.config.aisleCols, {3});
      expect(b.config.cols, 5);
      expect(b.cells[(1, 1, 5)]!.type, PositionType.driver);
      expect(b.cells.keys.every((k) => k.$3 != 3), isTrue);
      expect(validateLayout(config: b.config, cells: b.cells, busType: 'ac_seater', capacity: 40).errors, isEmpty);
    });

    test('buildLayout: two-deck sleeper has a lower berth under every upper', () {
      final b = buildLayout(
          preset: const AislePreset(1, 2), capacity: 31, decks: 2, sleeper: true, cabRow: true, driverOnRight: false);
      final v = validateLayout(config: b.config, cells: b.cells, busType: 'ac_sleeper', capacity: 31);
      expect(v.errors, isEmpty);
      expect(layoutStats(b.cells).configured, 31);
    });
  });
}
