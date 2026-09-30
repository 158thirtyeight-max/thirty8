import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/fare_model.dart';

void main() {
  // Same scenario as supabase/tests/onboarding_phase9.sql so the preview and the
  // server engine agree: base 500, Origin->Middle 200, Middle->Dest 300,
  // anything->Dest 450, charges 10.00 flat + 5%.
  const rules = [
    FareRule(seatType: 'seater', cents: 50000),
    FareRule(seatType: 'seater', cents: 20000, fromPointId: 'bo', toPointId: 'dm'),
    FareRule(seatType: 'seater', cents: 30000, fromPointId: 'bm', toPointId: 'dd'),
    FareRule(seatType: 'seater', cents: 45000, toPointId: 'dd'),
  ];
  const charges = [
    FareCharge(name: 'Convenience fee', isPercent: false, value: 10),
    FareCharge(name: 'GST', isPercent: true, value: 5),
  ];

  int fare({String? b, String? d}) =>
      previewFare(rules: rules, charges: charges, seatType: 'seater', boardingId: b, droppingId: d);

  group('previewFare matches the server engine', () {
    test('base', () => expect(fare(), 53500));
    test('pair', () => expect(fare(b: 'bo', d: 'dm'), 22000));
    test('pair 2', () => expect(fare(b: 'bm', d: 'dd'), 32500));
    test('destination-only beats base', () => expect(fare(b: 'bo', d: 'dd'), 48250));
    test('unknown points fall back to base', () => expect(fare(b: 'x', d: 'y'), 53500));
  });

  test('category and berth specificity', () {
    const r = [
      FareRule(seatType: 'sleeper', cents: 80000),
      FareRule(seatType: 'sleeper', berth: 'upper', cents: 70000),
      FareRule(seatType: 'sleeper', berth: 'lower', category: 'premium', cents: 95000),
    ];
    int f(String berth, {String? cat}) =>
        previewFare(rules: r, charges: const [], seatType: 'sleeper', berth: berth, category: cat);
    expect(f('upper'), 70000);
    expect(f('lower'), 80000);
    expect(f('lower', cat: 'premium'), 95000);
  });

  test('no rule uses the fallback', () {
    expect(previewFare(rules: const [], charges: const [], seatType: 'seater', fallbackCents: 12345), 12345);
  });

  group('rupees', () {
    test('parse', () {
      expect(parseRupees('500'), 50000);
      expect(parseRupees('1,250.5'), 125050);
      expect(parseRupees('₹99.99'), 9999);
      expect(parseRupees('12.345'), isNull);
      expect(parseRupees('abc'), isNull);
      expect(parseRupees(''), isNull);
      expect(parseRupees('-5'), isNull);
    });
    test('format', () {
      expect(formatRupees(50000), '₹500');
      expect(formatRupees(22050), '₹220.50');
      expect(formatRupees(5), '₹0.05');
    });
  });

  group('classes from seats', () {
    test('only bookable seats; premium detected', () {
      final r = fareClassesFromSeats([
        {'kind': 'bookable', 'seat_type': 'sleeper', 'berth': 'lower', 'category': 'premium'},
        {'kind': 'bookable', 'seat_type': 'sleeper', 'berth': 'upper'},
        {'kind': 'bookable', 'seat_type': 'sleeper', 'berth': 'upper'},
        {'kind': 'crew', 'seat_type': 'seater'},
        {'kind': 'reserved', 'seat_type': 'seater'},
      ]);
      expect(r.classes.map((c) => c.label), ['Sleeper · lower berth', 'Sleeper · upper berth']);
      expect(r.hasPremium, isTrue);
    });
  });

  group('validation', () {
    const seater = FareClass(seatType: 'seater');
    test('needs a base fare per class', () {
      expect(validateFares(classes: [seater], rules: const [], charges: const []), contains('Enter a base fare for Seater'));
      expect(validateFares(classes: [seater], rules: const [FareRule(seatType: 'seater', cents: 100)], charges: const []), isEmpty);
    });
    test('a pair fare alone is not a base fare', () {
      final e = validateFares(
        classes: [seater],
        rules: const [FareRule(seatType: 'seater', cents: 100, fromPointId: 'a', toPointId: 'b')],
        charges: const [],
      );
      expect(e, contains('Enter a base fare for Seater'));
    });
    test('duplicates, zero and bad charges', () {
      final e = validateFares(
        classes: [seater],
        rules: const [FareRule(seatType: 'seater', cents: 0), FareRule(seatType: 'seater', cents: 5)],
        charges: const [FareCharge(name: ' ', isPercent: true, value: 150)],
      );
      expect(e, containsAll(['Fares must be greater than zero', 'Two fares are defined for the same seats and stops', 'Every extra charge needs a name', 'A percentage charge cannot exceed 100%']));
    });
    test('charge json', () {
      expect(const FareCharge(name: 'Fee', isPercent: false, value: 12.5).toJson(), {'name': 'Fee', 'kind': 'flat', 'flat_cents': 1250});
      expect(const FareCharge(name: 'GST', isPercent: true, value: 5).toJson(), {'name': 'GST', 'kind': 'percent', 'percent': 5.0});
    });
  });
}
