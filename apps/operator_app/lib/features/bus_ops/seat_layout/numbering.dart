import 'seat_layout_model.dart';

String _letters(int n) {
  // 1 -> A, 26 -> Z, 27 -> AA
  var s = '';
  var v = n;
  while (v > 0) {
    v--;
    s = String.fromCharCode(65 + v % 26) + s;
    v ~/= 26;
  }
  return s;
}

List<String> _sortedKeys(Map<String, SeatCell> cells, {required bool columnMajor}) {
  (int, int) rc(String k) {
    final p = k.split(',');
    return (int.parse(p[0]), int.parse(p[1]));
  }

  final keys = cells.keys.toList();
  keys.sort((a, b) {
    final (ra, ca) = rc(a);
    final (rb, cb) = rc(b);
    return columnMajor ? (ca != cb ? ca.compareTo(cb) : ra.compareTo(rb)) : (ra != rb ? ra.compareTo(rb) : ca.compareTo(cb));
  });
  return keys;
}

/// Computes a seat label for every cell under [method]. Pure: never mutates
/// the grid, so switching methods can't reset the seat map. Manual labels are
/// read from [manualLabels]; seats without one fall back to the row-wise
/// label so manual mode always starts from something sensible.
Map<String, String> computeLabels(
  Map<String, SeatCell> cells,
  NumberingMethod method, {
  Map<String, String> manualLabels = const {},
}) {
  final out = <String, String>{};
  String rowWise(String k) {
    final p = k.split(',');
    return '${p[0]}${_letters(int.parse(p[1]))}';
  }

  switch (method) {
    case NumberingMethod.rowWise:
      for (final k in cells.keys) {
        out[k] = rowWise(k);
      }
    case NumberingMethod.columnWise:
      var n = 1;
      for (final k in _sortedKeys(cells, columnMajor: true)) {
        out[k] = '${n++}';
      }
    case NumberingMethod.alphabetical:
      for (final k in cells.keys) {
        final p = k.split(',');
        out[k] = '${_letters(int.parse(p[0]))}${p[1]}';
      }
    case NumberingMethod.manual:
      for (final k in cells.keys) {
        final m = manualLabels[k]?.trim();
        out[k] = (m == null || m.isEmpty) ? rowWise(k) : m;
      }
  }
  return out;
}
