/// Pure model + validation for the per-bus seat layout editor. The rules here
/// mirror `public.validate_bus_layout` in SQL (the server is authoritative and
/// re-checks on submit / approval / activation); the editor uses this for
/// instant feedback.
///
/// Storage reuses `bus_layouts` / `seats`. A seat's database `kind` decides
/// whether a customer can ever book it (only `bookable`); the operator-facing
/// [PositionType] is a friendlier view over `kind` + `role`.
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

/// Refines `reserved` (ladies / accessible) and `crew` (driver / conductor).
enum SeatRole { ladies, accessible, driver, conductor }

SeatRole? parseSeatRole(String? v) {
  for (final r in SeatRole.values) {
    if (r.name == v) return r;
  }
  return null;
}

/// What the operator picks for a position. Maps onto kind + role:
///   passenger -> bookable          ladies -> reserved/ladies   accessible -> reserved/accessible
///   crew -> crew                   driver -> crew/driver       conductor -> crew/conductor
///   unavailable -> unavailable
enum PositionType { passenger, ladies, accessible, crew, driver, conductor, unavailable }

extension PositionTypeX on PositionType {
  String get label => switch (this) {
        PositionType.passenger => 'Passenger',
        PositionType.ladies => 'Ladies Reserved',
        PositionType.accessible => 'Accessible',
        PositionType.crew => 'Crew',
        PositionType.driver => 'Driver',
        PositionType.conductor => 'Conductor',
        PositionType.unavailable => 'Unavailable',
      };

  String get hint => switch (this) {
        PositionType.passenger => 'Sold to customers',
        PositionType.ladies => 'Held back, not sold online',
        PositionType.accessible => 'Physically disabled / priority seat, not sold online',
        PositionType.crew => 'Staff seat, not sold',
        PositionType.driver => 'Driver position, not sold',
        PositionType.conductor => 'Conductor position, not sold',
        PositionType.unavailable => 'Cannot be used (e.g. engine hump, door)',
      };

  /// Only passenger seats are ever sold.
  bool get bookable => this == PositionType.passenger;
}

/// One occupied grid position. Empty cells are simply absent from the map.
class SeatCell {
  const SeatCell({required this.kind, required this.sleeper, this.category, this.role, this.number});

  final SeatKind kind;

  /// Sleeper berth (true) or a normal seat (false).
  final bool sleeper;

  /// Fare category, e.g. 'premium'; null for a standard seat. Fare rules can
  /// price a category differently (see the fare engine).
  final String? category;

  final SeatRole? role;

  /// Operator-assigned number; only used when the layout numbering is manual.
  final String? number;

  PositionType get type => switch (kind) {
        SeatKind.bookable => PositionType.passenger,
        SeatKind.reserved => role == SeatRole.accessible ? PositionType.accessible : PositionType.ladies,
        SeatKind.crew => switch (role) {
            SeatRole.driver => PositionType.driver,
            SeatRole.conductor => PositionType.conductor,
            _ => PositionType.crew,
          },
        SeatKind.unavailable || SeatKind.other => PositionType.unavailable,
      };

  /// Passenger-facing seats carry a seat number (bookable and reserved).
  bool get isNumbered => kind == SeatKind.bookable || kind == SeatKind.reserved;

  SeatCell copyWith({SeatKind? kind, bool? sleeper, Object? category = _keep, Object? role = _keep, Object? number = _keep}) =>
      SeatCell(
        kind: kind ?? this.kind,
        sleeper: sleeper ?? this.sleeper,
        category: identical(category, _keep) ? this.category : category as String?,
        role: identical(role, _keep) ? this.role : role as SeatRole?,
        number: identical(number, _keep) ? this.number : number as String?,
      );

  /// This position changed to [t]; the number is kept for numbered types.
  SeatCell withType(PositionType t) {
    final (k, r) = switch (t) {
      PositionType.passenger => (SeatKind.bookable, null),
      PositionType.ladies => (SeatKind.reserved, SeatRole.ladies),
      PositionType.accessible => (SeatKind.reserved, SeatRole.accessible),
      PositionType.crew => (SeatKind.crew, null),
      PositionType.driver => (SeatKind.crew, SeatRole.driver),
      PositionType.conductor => (SeatKind.crew, SeatRole.conductor),
      PositionType.unavailable => (SeatKind.unavailable, null),
    };
    final numbered = k == SeatKind.bookable || k == SeatKind.reserved;
    return SeatCell(
      kind: k,
      sleeper: sleeper,
      category: k == SeatKind.bookable ? category : null,
      role: r,
      number: numbered ? number : null,
    );
  }
}

const Object _keep = Object();

typedef CellKey = (int deck, int row, int col);

/// rowWise: 1 2 | 3 4 / 5 6 | 7 8      columnWise: 1 5 | 9 13 / 2 6 | 10 14
/// alphabetical: A1 A2 | B1 B2          manual: the operator numbers every seat
/// rowLetter is the old "1A" style, kept so saved layouts read back unchanged.
enum Numbering { rowWise, columnWise, alphabetical, manual, rowLetter }

extension NumberingX on Numbering {
  String get db => switch (this) {
        Numbering.rowWise => 'row_wise',
        Numbering.columnWise => 'column_wise',
        Numbering.alphabetical => 'alphabetical',
        Numbering.manual => 'manual',
        Numbering.rowLetter => 'row_letter',
      };

  static Numbering parse(Object? v) => switch (v) {
        'row_wise' || 'sequential' => Numbering.rowWise,
        'column_wise' => Numbering.columnWise,
        'alphabetical' => Numbering.alphabetical,
        'manual' => Numbering.manual,
        _ => Numbering.rowLetter,
      };
}

class LayoutConfig {
  const LayoutConfig({
    required this.rows,
    required this.cols,
    required this.decks,
    required this.aisleCols,
    this.numbering = Numbering.rowWise,
    this.cabRow = false,
  });

  final int rows;
  final int cols;
  final int decks;
  final Set<int> aisleCols; // 1-based
  final Numbering numbering;

  /// Row 1 is the driver's cab row (drawn under FRONT / DRIVER).
  final bool cabRow;

  LayoutConfig copyWith({int? rows, int? cols, int? decks, Set<int>? aisleCols, Numbering? numbering, bool? cabRow}) =>
      LayoutConfig(
        rows: rows ?? this.rows,
        cols: cols ?? this.cols,
        decks: decks ?? this.decks,
        aisleCols: aisleCols ?? this.aisleCols,
        numbering: numbering ?? this.numbering,
        cabRow: cabRow ?? this.cabRow,
      );

  Map<String, dynamic> toJson() => {
        'rows': rows,
        'cols': cols,
        'decks': decks,
        'aisle_cols': (aisleCols.toList()..sort()),
        'numbering': numbering.db,
        'cab_row': cabRow,
      };

  static LayoutConfig? fromJson(Map<String, dynamic>? j, {required int deckCount}) {
    if (j == null || j['rows'] is! num || j['cols'] is! num) return null;
    return LayoutConfig(
      rows: (j['rows'] as num).toInt(),
      cols: (j['cols'] as num).toInt(),
      decks: (j['decks'] as num?)?.toInt() ?? deckCount,
      aisleCols: {for (final a in (j['aisle_cols'] as List? ?? const [])) (a as num).toInt()},
      numbering: NumberingX.parse(j['numbering']),
      cabRow: j['cab_row'] == true,
    );
  }
}

/// seater / sleeper / semi_sleeper part of bus_type.
String seatingOf(String busType) => busType.replaceFirst(RegExp(r'^(non_ac_|ac_)'), '');

/// A cell on deck 1 of a sleeper layout is a lower berth, deck 2 an upper berth.
String? berthFor({required bool sleeper, required int deck}) => sleeper ? (deck == 2 ? 'upper' : 'lower') : null;

/// Placeholder codes the server stores for seats that are not numbered yet.
bool isPlaceholderCode(String? code) => code == null || code.isEmpty || code.startsWith('TMP-');

final RegExp _manualNumber = RegExp(r'^[A-Za-z0-9]{1,4}$');
bool isValidManualNumber(String v) => _manualNumber.hasMatch(v);

String _letters(int index) {
  // 0 -> A ... 25 -> Z, 26 -> AA
  var n = index;
  var s = '';
  do {
    s = String.fromCharCode(65 + n % 26) + s;
    n = n ~/ 26 - 1;
  } while (n >= 0);
  return s;
}

List<CellKey> _sortedKeys(Iterable<CellKey> keys, {bool byColumn = false}) => keys.toList()
  ..sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (byColumn) {
      if (a.$3 != b.$3) return a.$3.compareTo(b.$3);
      return a.$2.compareTo(b.$2);
    }
    if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
    return a.$3.compareTo(b.$3);
  });

/// Assigns a code to every position.
///
/// Passenger-facing seats (bookable + reserved) are numbered by the layout's
/// method; manual numbering uses exactly what the operator typed ('' when not
/// numbered yet) and never reorders. Non-passenger positions get fixed labels
/// (DRV, CND, CRW, NA).
Map<CellKey, String> generateSeatCodes(LayoutConfig config, Map<CellKey, SeatCell> cells) {
  final codes = <CellKey, String>{};
  final labelCount = <String, int>{};
  String label(String prefix) {
    final n = (labelCount[prefix] ?? 0) + 1;
    labelCount[prefix] = n;
    return n == 1 ? prefix : '$prefix$n';
  }

  final seatCols = [for (var c = 1; c <= config.cols; c++) if (!config.aisleCols.contains(c)) c];
  String berthPrefix(CellKey k, SeatCell c) => c.sleeper ? (k.$1 == 2 ? 'U' : 'L') : '';

  for (final k in _sortedKeys(cells.keys)) {
    final c = cells[k]!;
    if (c.isNumbered) continue;
    codes[k] = switch (c.type) {
      PositionType.driver => label('DRV'),
      PositionType.conductor => label('CND'),
      PositionType.crew => label('CRW'),
      _ => label(c.kind == SeatKind.other ? 'OTH' : 'NA'),
    };
  }

  final numbered = cells.keys.where((k) => cells[k]!.isNumbered);
  switch (config.numbering) {
    case Numbering.manual:
      for (final k in numbered) {
        codes[k] = cells[k]!.number ?? '';
      }
    case Numbering.rowWise:
      var seq = 0;
      for (final k in _sortedKeys(numbered)) {
        seq++;
        codes[k] = '${berthPrefix(k, cells[k]!)}$seq';
      }
    case Numbering.columnWise:
      var seq = 0;
      for (final k in _sortedKeys(numbered, byColumn: true)) {
        seq++;
        codes[k] = '${berthPrefix(k, cells[k]!)}$seq';
      }
    case Numbering.alphabetical:
      var rowIndex = -1;
      var position = 0;
      (int, int)? lastRow;
      for (final k in _sortedKeys(numbered)) {
        if (lastRow != (k.$1, k.$2)) {
          lastRow = (k.$1, k.$2);
          rowIndex++;
          position = 0;
        }
        position++;
        codes[k] = '${_letters(rowIndex)}$position';
      }
    case Numbering.rowLetter:
      for (final k in _sortedKeys(numbered)) {
        final idx = seatCols.indexOf(k.$3);
        codes[k] = '${berthPrefix(k, cells[k]!)}${k.$2}${String.fromCharCode(65 + (idx < 0 ? 0 : idx))}';
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
          'role': c.role?.name,
        };
      }(),
  ];
}

class LayoutStats {
  const LayoutStats({required this.bookable, required this.reserved, required this.crew, required this.unavailable, required this.other});

  final int bookable;
  final int reserved;
  final int crew;
  final int unavailable;
  final int other;

  /// Physical positions counted against the declared bus capacity.
  int get configured => bookable + reserved + crew + other;
}

LayoutStats layoutStats(Map<CellKey, SeatCell> cells) {
  int n(SeatKind k) => cells.values.where((c) => c.kind == k).length;
  return LayoutStats(
    bookable: n(SeatKind.bookable),
    reserved: n(SeatKind.reserved),
    crew: n(SeatKind.crew),
    unavailable: n(SeatKind.unavailable),
    other: n(SeatKind.other),
  );
}

int bookableCount(Map<CellKey, SeatCell> cells) => cells.values.where((c) => c.kind == SeatKind.bookable).length;

/// Passenger-facing seats that still need a number (manual numbering).
int unnumberedCount(LayoutConfig config, Map<CellKey, SeatCell> cells) {
  if (config.numbering != Numbering.manual) return 0;
  return cells.values.where((c) => c.isNumbered && isPlaceholderCode(c.number)).length;
}

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
  final reported = <String>{};
  for (final e in codes.entries) {
    final code = e.value;
    if (isPlaceholderCode(code)) continue;
    if (!seen.add(code.toUpperCase()) && reported.add(code.toUpperCase())) errors.add('Duplicate seat number $code');
  }
  if (config.numbering == Numbering.manual) {
    for (final e in cells.entries) {
      final n = e.value.number;
      if (e.value.isNumbered && n != null && n.isNotEmpty && !isValidManualNumber(n)) {
        errors.add('Seat number "$n" is not valid (use up to 4 letters or digits)');
      }
    }
  }
  final unnumbered = unnumberedCount(config, cells);
  if (unnumbered > 0) errors.add('$unnumbered seat(s) have not been numbered yet');

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

  final stats = layoutStats(cells);
  if (cells.isEmpty) {
    errors.add('The layout has no seats');
  } else if (stats.bookable == 0) {
    errors.add('At least one seat must be available for booking');
  }
  if (stats.bookable > capacity) {
    errors.add('Bookable seats (${stats.bookable}) exceed the bus capacity ($capacity)');
  } else if (cells.isNotEmpty && stats.configured != capacity) {
    warnings.add('The layout has ${stats.configured} positions but the declared bus capacity is $capacity');
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
  if (!cells.values.any((c) => c.kind == SeatKind.crew && (c.role == null || c.role == SeatRole.driver))) {
    warnings.add('No driver position is marked');
  }

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
    cells[(deck, row, col)] = seatCellFromRow(s, sleeperBus: sleeperBus);
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

/// A saved `seats` row as an editor cell. Older driver positions (kind crew,
/// no role, coded DRV*) are read back as drivers.
SeatCell seatCellFromRow(Map<String, dynamic> s, {bool? sleeperBus}) {
  final kind = SeatKindX.parse(s['kind'] as String?);
  var role = parseSeatRole(s['role'] as String?);
  final code = s['seat_code'] as String?;
  if (kind == SeatKind.crew && role == null && (code?.startsWith('DRV') ?? false)) role = SeatRole.driver;
  final numbered = kind == SeatKind.bookable || kind == SeatKind.reserved;
  return SeatCell(
    kind: kind,
    sleeper: (sleeperBus ?? false) || s['seat_type'] == 'sleeper',
    category: s['category'] as String?,
    role: role,
    number: numbered && !isPlaceholderCode(code) ? code : null,
  );
}

/// Seats on each side of the aisle, e.g. 2 + 2.
class AislePreset {
  const AislePreset(this.left, this.right);
  final int left;
  final int right;
  String get label => '$left + $right';
  int get seatsPerRow => left + right;
}

const seaterPresets = [AislePreset(2, 2), AislePreset(2, 1), AislePreset(1, 2), AislePreset(3, 2), AislePreset(2, 3)];
const sleeperPresets = [AislePreset(1, 2), AislePreset(2, 1), AislePreset(2, 2), AislePreset(1, 1)];

/// Builds a starting layout for [capacity] positions: passenger seats in rows
/// either side of the aisle, plus (optionally) a front cab row with the driver.
/// The operator then fine-tunes by tapping seats / the aisle.
({LayoutConfig config, Map<CellKey, SeatCell> cells}) buildLayout({
  required AislePreset preset,
  required int capacity,
  required int decks,
  required bool sleeper,
  required bool cabRow,
  required bool driverOnRight,
  Numbering numbering = Numbering.rowWise,
}) {
  final hasAisle = preset.left > 0 && preset.right > 0;
  final cols = preset.seatsPerRow + (hasAisle ? 1 : 0);
  final seatCols = [
    for (var c = 1; c <= cols; c++)
      if (!(hasAisle && c == preset.left + 1)) c,
  ];

  final n = (capacity - (cabRow ? 1 : 0)).clamp(1, 1000);
  final perDeck = decks == 2 ? (n + 1) ~/ 2 : n;
  final seatRows = (perDeck + preset.seatsPerRow - 1) ~/ preset.seatsPerRow;
  final firstRow = cabRow ? 2 : 1;
  final rows = (seatRows + (cabRow ? 1 : 0)).clamp(1, 40);

  final cells = <CellKey, SeatCell>{};
  void fill(int deck, int count) {
    var left = count;
    for (var r = firstRow; r < firstRow + seatRows && left > 0; r++) {
      for (final c in seatCols) {
        if (left == 0) break;
        if (r > rows) return;
        cells[(deck, r, c)] = SeatCell(kind: SeatKind.bookable, sleeper: sleeper);
        left--;
      }
    }
  }

  fill(1, perDeck);
  if (decks == 2) fill(2, n - perDeck);

  if (cabRow) {
    final driverCol = driverOnRight ? seatCols.last : seatCols.first;
    cells[(1, 1, driverCol)] = SeatCell(kind: SeatKind.crew, sleeper: false, role: SeatRole.driver);
  }

  return (
    config: LayoutConfig(
      rows: rows,
      cols: cols,
      decks: decks,
      aisleCols: {if (hasAisle) preset.left + 1},
      numbering: numbering,
      cabRow: cabRow,
    ),
    cells: cells,
  );
}
