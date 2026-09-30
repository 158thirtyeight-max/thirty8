/// Pure model for a bus's fare setup (Stage E) plus a Dart mirror of the
/// server's fare engine (`private.resolve_seat_fare`) used ONLY to preview
/// prices. The server is authoritative: search, seat map, seat hold and
/// booking all price through the SQL function.
library;

/// A kind of bookable seat that needs a fare: seat type + berth (+ optional fare category).
class FareClass {
  const FareClass({required this.seatType, this.berth});

  final String seatType; // seater | sleeper
  final String? berth; // lower | upper | null

  String get key => '$seatType|${berth ?? ''}';

  String get label {
    if (seatType == 'seater') return 'Seater';
    return switch (berth) {
      'lower' => 'Sleeper · lower berth',
      'upper' => 'Sleeper · upper berth',
      _ => 'Sleeper',
    };
  }

  @override
  bool operator ==(Object other) => other is FareClass && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// Distinct (seat type, berth) among bookable seats, and whether any premium seats exist.
({List<FareClass> classes, bool hasPremium}) fareClassesFromSeats(List<Map<String, dynamic>> seats) {
  final classes = <FareClass>{};
  var premium = false;
  for (final s in seats) {
    if (s['kind'] != 'bookable') continue;
    classes.add(FareClass(seatType: s['seat_type'] as String, berth: s['berth'] as String?));
    if (s['category'] == 'premium') premium = true;
  }
  final list = classes.toList()..sort((a, b) => a.key.compareTo(b.key));
  return (classes: list, hasPremium: premium);
}

/// One row of `fare_rules`.
class FareRule {
  const FareRule({
    required this.seatType,
    this.berth,
    this.category,
    this.fromPointId,
    this.toPointId,
    required this.cents,
  });

  final String seatType;
  final String? berth;
  final String? category;
  final String? fromPointId;
  final String? toPointId;
  final int cents;

  Map<String, dynamic> toJson() => {
        'seat_type': seatType,
        'berth': berth,
        'seat_category': category,
        'from_point_id': fromPointId,
        'to_point_id': toPointId,
        'base_fare_cents': cents,
      };

  static FareRule fromRow(Map<String, dynamic> r) => FareRule(
        seatType: r['seat_type'] as String,
        berth: r['berth'] as String?,
        category: r['seat_category'] as String?,
        fromPointId: r['from_boarding_point_id'] as String?,
        toPointId: r['to_dropping_point_id'] as String?,
        cents: r['base_fare_cents'] as int,
      );
}

class FareCharge {
  const FareCharge({required this.name, required this.isPercent, required this.value});

  final String name;
  final bool isPercent;

  /// Rupees for a flat charge, percent for a percentage charge.
  final double value;

  Map<String, dynamic> toJson() => {
        'name': name.trim(),
        'kind': isPercent ? 'percent' : 'flat',
        if (isPercent) 'percent': value else 'flat_cents': (value * 100).round(),
      };

  static FareCharge fromRow(Map<String, dynamic> r) {
    final isPercent = r['kind'] == 'percent';
    return FareCharge(
      name: r['name'] as String,
      isPercent: isPercent,
      value: isPercent ? (r['percent'] as num).toDouble() : (r['flat_cents'] as num) / 100,
    );
  }
}

/// Parses rupee input ("500", "1,250.5", "₹99.99") into paise; null if invalid or > 2 decimals.
int? parseRupees(String? input) {
  if (input == null) return null;
  final t = input.replaceAll(RegExp(r'[₹,\s]'), '');
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(t)) return null;
  final parts = t.split('.');
  final whole = int.parse(parts[0]);
  final frac = parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0'));
  return whole * 100 + frac;
}

String formatRupees(int cents) {
  final whole = cents ~/ 100;
  final frac = cents % 100;
  return frac == 0 ? '₹$whole' : '₹$whole.${frac.toString().padLeft(2, '0')}';
}

/// Mirror of private.resolve_seat_fare (preview only). Most specific rule wins:
/// pair > destination only > boarding only > base; then category, then berth.
int previewFare({
  required List<FareRule> rules,
  required List<FareCharge> charges,
  required String seatType,
  String? berth,
  String? category,
  String? boardingId,
  String? droppingId,
  int fallbackCents = 0,
}) {
  final matches = rules.where((r) =>
      r.seatType == seatType &&
      (r.berth == null || r.berth == berth) &&
      (r.category == null || r.category == category) &&
      (r.fromPointId == null || r.fromPointId == boardingId) &&
      (r.toPointId == null || r.toPointId == droppingId)).toList();

  int tier(FareRule r) => r.fromPointId != null && r.toPointId != null
      ? 3
      : r.toPointId != null
          ? 2
          : r.fromPointId != null
              ? 1
              : 0;

  matches.sort((a, b) {
    final t = tier(b).compareTo(tier(a));
    if (t != 0) return t;
    final c = ((b.category != null) ? 1 : 0).compareTo((a.category != null) ? 1 : 0);
    if (c != 0) return c;
    return ((b.berth != null) ? 1 : 0).compareTo((a.berth != null) ? 1 : 0);
  });

  final base = matches.isEmpty ? fallbackCents : matches.first.cents;
  var flat = 0;
  double pct = 0;
  for (final c in charges) {
    if (c.isPercent) {
      pct += c.value;
    } else {
      flat += (c.value * 100).round();
    }
  }
  return base + flat + (base * pct / 100).round();
}

/// Client-side checks mirroring validate_bus_fares / save_bus_fares.
List<String> validateFares({
  required List<FareClass> classes,
  required List<FareRule> rules,
  required List<FareCharge> charges,
}) {
  final errors = <String>[];
  for (final c in classes) {
    final hasBase = rules.any((r) =>
        r.seatType == c.seatType &&
        r.fromPointId == null &&
        r.toPointId == null &&
        r.category == null &&
        (r.berth == null || r.berth == c.berth));
    if (!hasBase) errors.add('Enter a base fare for ${c.label}');
  }
  for (final r in rules) {
    if (r.cents <= 0) errors.add('Fares must be greater than zero');
    if (r.cents > 10000000) errors.add('A fare is unrealistically high');
  }
  final seen = <String>{};
  for (final r in rules) {
    final k = '${r.seatType}|${r.berth}|${r.category}|${r.fromPointId}|${r.toPointId}';
    if (!seen.add(k)) errors.add('Two fares are defined for the same seats and stops');
  }
  for (final c in charges) {
    if (c.name.trim().isEmpty) errors.add('Every extra charge needs a name');
    if (c.value < 0) errors.add('Charges cannot be negative');
    if (c.isPercent && c.value > 100) errors.add('A percentage charge cannot exceed 100%');
  }
  return errors.toSet().toList();
}
