/// Pure-Dart domain model for the seat layout wizard. No Flutter or Supabase
/// imports so numbering, validation and (de)serialisation stay unit-testable.
library;

enum SeatKind { passenger, reserved, crew, unavailable }

enum NumberingMethod { rowWise, columnWise, alphabetical, manual }

enum SeatArrangement {
  twoByTwo('2+2', 2, 2),
  twoByOne('2+1', 2, 1),
  oneByTwo('1+2', 1, 2),
  oneByOne('1+1', 1, 1),
  threeByTwo('3+2', 3, 2);

  const SeatArrangement(this.label, this.left, this.right);
  final String label;
  final int left;
  final int right;

  int get columns => left + right;

  static SeatArrangement fromLabel(String? label) =>
      SeatArrangement.values.firstWhere((a) => a.label == label, orElse: () => SeatArrangement.twoByTwo);
}

class SeatCell {
  const SeatCell({required this.kind, this.sleeper = false});

  final SeatKind kind;
  final bool sleeper;

  SeatCell copyWith({SeatKind? kind, bool? sleeper}) => SeatCell(kind: kind ?? this.kind, sleeper: sleeper ?? this.sleeper);
}

String cellKey(int row, int col) => '$row,$col';

class SeatLayoutDraft {
  SeatLayoutDraft({
    this.capacity = 36,
    this.reserved = 0,
    this.crew = 0,
    this.unavailable = 0,
    this.arrangement = SeatArrangement.twoByTwo,
    this.driverLeft = true,
    this.rows = 0,
    Map<String, SeatCell>? cells,
    this.numbering = NumberingMethod.rowWise,
    Map<String, String>? manualLabels,
    this.generatedSignature,
    this.step = 0,
  })  : cells = cells ?? {},
        manualLabels = manualLabels ?? {};

  static const schemaVersion = 2;

  int capacity;
  int reserved;
  int crew;
  int unavailable;
  SeatArrangement arrangement;
  bool driverLeft;

  /// Number of grid rows; `cells` holds only the seats that exist, keyed by
  /// `cellKey(row, col)` with 1-based row/col (matching seats.row_no/col_no).
  int rows;
  final Map<String, SeatCell> cells;
  NumberingMethod numbering;

  /// Manual labels survive switching numbering methods.
  final Map<String, String> manualLabels;

  /// Signature of the step 1/2 inputs the grid was generated from; used to
  /// avoid regenerating (and wiping edits) when nothing upstream changed.
  String? generatedSignature;
  int step;

  int get passenger => capacity - reserved - crew - unavailable;
  int get columns => arrangement.columns;
  String get signature => '$capacity|$reserved|$crew|$unavailable|${arrangement.label}';

  int countKind(SeatKind k) => cells.values.where((c) => c.kind == k).length;
  int get configured => cells.length;

  /// Rebuilds the grid from the step 1/2 inputs.
  void generateGrid() {
    cells.clear();
    final order = <SeatKind>[
      ...List.filled(crew, SeatKind.crew),
      ...List.filled(reserved, SeatKind.reserved),
      ...List.filled(passenger < 0 ? 0 : passenger, SeatKind.passenger),
      ...List.filled(unavailable, SeatKind.unavailable),
    ];
    final cols = columns;
    rows = (order.length / cols).ceil();
    for (var i = 0; i < order.length; i++) {
      cells[cellKey(i ~/ cols + 1, i % cols + 1)] = SeatCell(kind: order[i]);
    }
    generatedSignature = signature;
  }

  Map<String, dynamic> toJson({bool draft = false}) => {
        'schema_version': schemaVersion,
        'draft': draft,
        'step': step,
        'capacity': capacity,
        'reserved': reserved,
        'crew': crew,
        'unavailable': unavailable,
        'arrangement': arrangement.label,
        'driver_side': driverLeft ? 'left' : 'right',
        'rows': rows,
        'cols': columns,
        'aisle_after_col': arrangement.left,
        'numbering': numbering.name,
        'generated_signature': generatedSignature,
        'manual_labels': manualLabels,
        'cells': cells.entries
            .map((e) => {'key': e.key, 'kind': e.value.kind.name, 'sleeper': e.value.sleeper})
            .toList(),
      };

  /// Loads v2 JSON, or legacy/empty layout_json (`{}` or
  /// `{rows, cols, aisle_after_col}`) which becomes a 2+2-style grid.
  factory SeatLayoutDraft.fromJson(Map<String, dynamic>? json, {int fallbackCapacity = 36}) {
    final j = json ?? const {};
    if (j['schema_version'] == schemaVersion) {
      final d = SeatLayoutDraft(
        capacity: (j['capacity'] as num?)?.toInt() ?? fallbackCapacity,
        reserved: (j['reserved'] as num?)?.toInt() ?? 0,
        crew: (j['crew'] as num?)?.toInt() ?? 0,
        unavailable: (j['unavailable'] as num?)?.toInt() ?? 0,
        arrangement: SeatArrangement.fromLabel(j['arrangement'] as String?),
        driverLeft: j['driver_side'] != 'right',
        rows: (j['rows'] as num?)?.toInt() ?? 0,
        numbering: NumberingMethod.values.firstWhere((m) => m.name == j['numbering'], orElse: () => NumberingMethod.rowWise),
        manualLabels: Map<String, String>.from((j['manual_labels'] as Map?) ?? const {}),
        generatedSignature: j['generated_signature'] as String?,
        step: (j['step'] as num?)?.toInt() ?? 0,
      );
      for (final c in (j['cells'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(c as Map);
        d.cells[m['key'] as String] = SeatCell(
          kind: SeatKind.values.firstWhere((k) => k.name == m['kind'], orElse: () => SeatKind.passenger),
          sleeper: m['sleeper'] == true,
        );
      }
      return d;
    }
    final aisle = (j['aisle_after_col'] as num?)?.toInt();
    final arrangement = aisle == 1 ? SeatArrangement.oneByTwo : SeatArrangement.twoByTwo;
    return SeatLayoutDraft(capacity: fallbackCapacity, arrangement: arrangement)..generateGrid();
  }
}
