/// Pure model + validation for the per-bus seat layout editor. The rules here
/// mirror `public.validate_bus_layout` in SQL (the server is authoritative and
/// re-checks on submit / approval / activation); the editor uses this for
/// instant feedback.
library;

enum SeatKind { bookable, unavailable, reserved, crew, other }

extension SeatKindX on SeatKind {
  String get db => name;
  String get label => switch (this) {
        SeatKind.bookable => 'Available for booking',
        SeatKind.unavailable => 'Not available',
        SeatKind.reserved => 'Reserved',
        SeatKind.crew => 'Driver / crew',
        SeatKind.other => 'Other (non-bookable)',
      };
  static SeatKind parse(String? v) =>
      SeatKind.values.firstWhere((k) => k.name == v, orElse: () => SeatKind.bookable);
}

/// One occupied grid position. Empty cells are simply absent from the map.
class SeatCell {
  const SeatCell({required this.kind, required this.sleeper, this.category});

  final SeatKind kind;

  /// Sleeper berth (true) or a normal seat (false).
  final bool sleeper;

  /// Fare category, e.g. 'premium'; null for a standard seat. Fare rules can
  /// price a category differently (see the fare engine).
  final String? category;

  SeatCell copyWith({SeatKind? kind, bool? sleeper, Object? category = _keep}) => SeatCell(
        kind: kind ?? this.kind,
        sleeper: sleeper ?? this.sleeper,
        category: identical(category, _keep) ? this.category : category as String?,
      );
}

const Object _keep = Object();

typedef CellKey = (int deck, int row, int col);

enum Numbering { rowLetter, sequential }

class LayoutConfig {
  const LayoutConfig({
    required this.rows,
    required this.cols,
    required this.decks,
    required this.aisleCols,
    this.numbering = Numbering.rowLetter,
  });

  final int rows;
  final int cols;
  final int decks;
  final Set<int> aisleCols; // 1-based
  final Numbering numbering;

  LayoutConfig copyWith({int? rows, int? cols, int? decks, Set<int>? aisleCols, Numbering? numbering}) => LayoutConfig(
        rows: rows ?? this.rows,
        cols: cols ?? this.cols,
        decks: decks ?? this.decks,
        aisleCols: aisleCols ?? this.aisleCols,
        numbering: numbering ?? this.numbering,
      );

  Map<String, dynamic> toJson() => {
        'rows': rows,
        'cols': cols,
        'decks': decks,
        'aisle_cols': (aisleCols.toList()..sort()),
        'numbering': numbering == Numbering.sequential ? 'sequential' : 'row_letter',
      };

  static LayoutConfig? fromJson(Map<String, dynamic>? j, {required int deckCount}) {
    if (j == null || j['rows'] is! num || j['cols'] is! num) return null;
    return LayoutConfig(
      rows: (j['rows'] as num).toInt(),
      cols: (j['cols'] as num).toInt(),
      decks: (j['decks'] as num?)?.toInt() ?? deckCount,
      aisleCols: {for (final a in (j['aisle_cols'] as List? ?? const [])) (a as num).toInt()},
      numbering: j['numbering'] == 'sequential' ? Numbering.sequential : Numbering.rowLetter,
    );
  }
}

/// seater / sleeper / semi_sleeper part of bus_type.
String seatingOf(String busType) => busType.replaceFirst(RegExp(r'^(non_ac_|ac_)'), '');

/// A cell on deck 1 of a sleeper layout is a lower berth, deck 2 an upper berth.
String? berthFor({required bool sleeper, required int deck}) => sleeper ? (deck == 2 ? 'upper' : 'lower') : null;

/// Assigns seat numbers. Row/letter: "1A" (letters skip aisle columns),
/// prefixed L/U for sleeper berths. Sequential: 1, 2, 3... in reading order,
/// same prefixes. Crew positions are numbered DRV, DRV2, ...
Map<CellKey, String> generateSeatCodes(LayoutConfig config, Map<CellKey, SeatCell> cells) {
  final seatCols = [for (var c = 1; c <= config.cols; c++) if (!config.aisleCols.contains(c)) c];
  final keys = cells.keys.toList()
    ..sort((a, b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.compareTo(b.$3);
    });

  final codes = <CellKey, String>{};
  var seq = 0;
  var crew = 0;
  for (final k in keys) {
    final cell = cells[k]!;
    if (cell.kind == SeatKind.crew) {
      crew++;
      codes[k] = crew == 1 ? 'DRV' : 'DRV$crew';
      continue;
    }
    final prefix = cell.sleeper ? (k.$1 == 2 ? 'U' : 'L') : '';
    if (config.numbering == Numbering.sequential) {
      seq++;
      codes[k] = '$prefix$seq';
    } else {
      final idx = seatCols.indexOf(k.$3);
      final letter = String.fromCharCode(65 + (idx < 0 ? 0 : idx));
      codes[k] = '$prefix${k.$2}$letter';
    }
  }
  return codes;
}

/// Payload for the save_bus_layout RPC.
List<Map<String, dynamic>> seatsToJson(LayoutConfig config, Map<CellKey, SeatCell> cells, String busType) {
  final codes = generateSeatCodes(config, cells);
  final seating = seatingOf(busType);
  return [
    for (final e in cells.entries)
      () {
        final k = e.key;
        final c = e.value;
        // Crew positions are exempt from berth rules; give them the bus's base type.
        final sleeper = c.kind == SeatKind.crew ? seating == 'sleeper' : c.sleeper;
        final berth = c.kind == SeatKind.crew ? null : berthFor(sleeper: sleeper, deck: k.$1);
        return {
          'seat_code': codes[k],
          'deck': k.$1,
          'row_no': k.$2,
          'col_no': k.$3,
          'seat_type': sleeper ? 'sleeper' : 'seater',
          'berth': berth,
          'kind': c.kind.db,
          'category': c.kind == SeatKind.bookable ? c.category : null,
        };
      }(),
  ];
}

int bookableCount(Map<CellKey, SeatCell> cells) => cells.values.where((c) => c.kind == SeatKind.bookable).length;

class LayoutValidation {
  const LayoutValidation(this.errors, this.warnings);
  final List<String> errors;
  final List<String> warnings;
  bool get valid => errors.isEmpty;
}

LayoutValidation validateLayout({
  required LayoutConfig config,
  required Map<CellKey, SeatCell> cells,
  required String busType,
  required int capacity,
}) {
  final errors = <String>[];
  final warnings = <String>[];
  final seating = seatingOf(busType);

  if (config.rows < 1 || config.rows > 40 || config.cols < 1 || config.cols > 8) {
    errors.add('Layout size must be 1-40 rows and 1-8 columns');
  }
  if (config.decks != 1 && config.decks != 2) errors.add('Decks must be 1 or 2');

  final codes = generateSeatCodes(config, cells);
  final seen = <String>{};
  for (final code in codes.values) {
    if (!seen.add(code.toUpperCase())) errors.add('Duplicate seat number $code');
  }

  var outside = 0;
  var onAisle = 0;
  var wrongDeck = 0;
  for (final k in cells.keys) {
    if (k.$2 < 1 || k.$2 > config.rows || k.$3 < 1 || k.$3 > config.cols) outside++;
    if (config.aisleCols.contains(k.$3)) onAisle++;
    if (k.$1 < 1 || k.$1 > config.decks) wrongDeck++;
  }
  if (outside > 0) errors.add('$outside seat(s) are outside the layout grid');
  if (onAisle > 0) errors.add('$onAisle seat(s) are placed on the aisle');
  if (wrongDeck > 0) errors.add('$wrongDeck seat(s) are on a deck that does not exist');

  final bookable = bookableCount(cells);
  if (cells.isEmpty) {
    errors.add('The layout has no seats');
  } else if (bookable == 0) {
    errors.add('At least one seat must be available for booking');
  }
  if (bookable != capacity) {
    errors.add('Bookable seats ($bookable) do not match the bus capacity ($capacity)');
  }

  final nonCrew = cells.entries.where((e) => e.value.kind != SeatKind.crew).toList();
  if (seating == 'seater') {
    final n = nonCrew.where((e) => e.value.sleeper).length;
    if (n > 0) errors.add('$n seat(s) are sleeper berths but this is a seater bus');
  } else if (seating == 'sleeper') {
    final n = nonCrew.where((e) => !e.value.sleeper).length;
    if (n > 0) errors.add('$n seat(s) are not sleeper berths but this is a sleeper bus');
  }

  // lower berths on deck 1, upper on deck 2, every upper has a lower below it
  final berths = nonCrew.where((e) => e.value.sleeper).toList();
  final badDeck = berths.where((e) => e.key.$1 != 1 && e.key.$1 != 2).length;
  if (badDeck > 0) errors.add('$badDeck berth(s) are on the wrong deck (lower = deck 1, upper = deck 2)');
  final orphanUpper = berths.where((e) {
    if (e.key.$1 != 2) return false;
    return !berths.any((l) => l.key.$1 == 1 && l.key.$2 == e.key.$2 && l.key.$3 == e.key.$3);
  }).length;
  if (orphanUpper > 0) errors.add('$orphanUpper upper berth(s) have no lower berth in the same position');

  if (config.decks == 2 && !cells.keys.any((k) => k.$1 == 2)) {
    errors.add('Two decks are configured but the upper deck has no seats');
  }
  if (!cells.values.any((c) => c.kind == SeatKind.crew)) warnings.add('No driver / crew position is marked');

  return LayoutValidation(errors, warnings);
}

/// Older layouts (created by the previous bus form) are a plain 4-column grid
/// with no aisle and empty layout_json. Convert them: put an aisle after
/// column 2 so the seat map reads 2+2.
({LayoutConfig config, Map<CellKey, SeatCell> cells}) convertLegacySeats(
  List<Map<String, dynamic>> seats, {
  required String busType,
}) {
  final sleeperBus = seatingOf(busType) == 'sleeper';
  var maxRow = 1;
  var maxCol = 1;
  for (final s in seats) {
    maxRow = maxRow > (s['row_no'] as int? ?? 1) ? maxRow : (s['row_no'] as int? ?? 1);
    maxCol = maxCol > (s['col_no'] as int? ?? 1) ? maxCol : (s['col_no'] as int? ?? 1);
  }
  final aisle = maxCol >= 3 ? 3 : null;
  final cells = <CellKey, SeatCell>{};
  for (final s in seats) {
    final row = s['row_no'] as int? ?? 1;
    var col = s['col_no'] as int? ?? 1;
    if (aisle != null && col >= aisle) col++;
    final deck = s['deck'] as int? ?? 1;
    cells[(deck, row, col)] = SeatCell(
      kind: SeatKindX.parse(s['kind'] as String?),
      sleeper: sleeperBus || s['seat_type'] == 'sleeper',
      category: s['category'] as String?,
    );
  }
  return (
    config: LayoutConfig(
      rows: maxRow,
      cols: aisle != null ? maxCol + 1 : maxCol,
      decks: 1,
      aisleCols: {?aisle},
    ),
    cells: cells,
  );
}

/// Convenience for the editor's "auto-fill" helper: fills the grid with
/// bookable seats (skipping aisles) until [count] seats are placed.
Map<CellKey, SeatCell> autoFillSeats(LayoutConfig config, {required int count, required bool sleeper}) {
  final cells = <CellKey, SeatCell>{};
  var left = count;
  for (var row = 1; row <= config.rows && left > 0; row++) {
    for (var col = 1; col <= config.cols && left > 0; col++) {
      if (config.aisleCols.contains(col)) continue;
      cells[(1, row, col)] = SeatCell(kind: SeatKind.bookable, sleeper: sleeper);
      left--;
    }
  }
  return cells;
}
