import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/fleet/bus_validators.dart';
import 'package:operator_app/shared/registration_input_formatter.dart';

void main() {
  group('registration number', () {
    test('accepts the standard AA 00 AA 0000 format', () {
      expect(BusValidators.registrationNumber('AN01A1234'), isNull);
      expect(BusValidators.registrationNumber('ka 01-ab 1234'), isNull);
      expect(BusValidators.registrationNumber('MH 12 ABC 1234'), isNull);
    });
    test('rejects invalid values', () {
      expect(BusValidators.registrationNumber(''), isNotNull);
      expect(BusValidators.registrationNumber('AB12'), isNotNull);
      expect(BusValidators.registrationNumber('ABCDEFGH'), isNotNull);
      expect(BusValidators.registrationNumber('12345678'), isNotNull);
      expect(BusValidators.registrationNumber('AN01A1234@'), isNotNull);
      expect(BusValidators.registrationNumber('XX 01 AB 1234'), isNotNull); // unknown state
      expect(BusValidators.registrationNumber('KA 00 AB 1234'), isNotNull);
      expect(BusValidators.registrationNumber('KA 01 AB 0000'), isNotNull);
      expect(BusValidators.registrationNumber('KA 01 1234'), isNotNull); // no series
    });
    test('normalizes', () {
      expect(BusValidators.normalizeRegistration(' an-01 a1234'), 'AN01A1234');
    });
    test('formatter inserts spaces while typing', () {
      const f = RegistrationInputFormatter();
      String type(String s) {
        var v = TextEditingValue.empty;
        for (final ch in s.split('')) {
          v = f.formatEditUpdate(v, TextEditingValue(text: v.text + ch));
        }
        return v.text;
      }

      expect(type('ka01ab1234'), 'KA 01 AB 1234');
      expect(type('mh12a5'), 'MH 12 A 5');
      expect(type('1KA01AB12345'), 'KA 01 AB 1234'); // stray leading digit / extra digit dropped
    });
  });

  group('years / seats', () {
    test('year bounds and ordering', () {
      expect(BusValidators.year('2020', label: 'Year'), isNull);
      expect(BusValidators.year('1979', label: 'Year'), isNotNull);
      expect(BusValidators.year('abc', label: 'Year'), isNotNull);
      expect(BusValidators.year('2018', label: 'Registration year', notBefore: 2020), isNotNull);
      expect(BusValidators.year('2020', label: 'Registration year', notBefore: 2020), isNull);
    });
    test('seats 1..80', () {
      expect(BusValidators.seats('40'), isNull);
      expect(BusValidators.seats('0'), isNotNull);
      expect(BusValidators.seats('81'), isNotNull);
      expect(BusValidators.seats('x'), isNotNull);
    });
  });

  group('bus type', () {
    test('compose / parse round trip matches the DB CHECK values', () {
      for (final ac in [true, false]) {
        for (final s in ['seater', 'sleeper', 'semi_sleeper']) {
          final t = composeBusType(ac: ac, seating: s);
          expect(
            const [
              'ac_seater', 'ac_sleeper', 'non_ac_seater', 'non_ac_sleeper', 'ac_semi_sleeper', 'non_ac_semi_sleeper'
            ],
            contains(t),
          );
          final p = parseBusType(t);
          expect(p.ac, ac);
          expect(p.seating, s);
        }
      }
    });
    test('labels', () {
      expect(busTypeLabel('non_ac_semi_sleeper'), 'Non-AC Semi-sleeper');
      expect(busTypeLabel('ac_seater'), 'AC Seater');
    });
  });

  group('documents', () {
    test('requirement conditions', () {
      expect(busRequirementApplies({}, 'ac_seater'), isTrue);
      expect(busRequirementApplies({'bus_type_in': ['ac_sleeper']}, 'ac_seater'), isFalse);
      expect(busRequirementApplies({'bus_type_in': ['ac_sleeper']}, 'ac_sleeper'), isTrue);
      expect(busRequirementApplies({'bus_type_not_in': ['ac_seater']}, 'ac_seater'), isFalse);
    });
    test('expiry state', () {
      final today = DateTime(2026, 6, 1);
      expect(docExpiryState(null, today: today), DocExpiryState.noExpiry);
      expect(docExpiryState(DateTime(2026, 5, 31), today: today), DocExpiryState.expired);
      expect(docExpiryState(DateTime(2026, 6, 1), today: today), DocExpiryState.expiringSoon);
      expect(docExpiryState(DateTime(2026, 6, 30), today: today), DocExpiryState.expiringSoon);
      expect(docExpiryState(DateTime(2026, 8, 1), today: today), DocExpiryState.valid);
    });
    test('date validation', () {
      expect(validateDocDates(issue: null, expiry: null, expiryRequired: true), isNotNull);
      expect(validateDocDates(issue: null, expiry: null, expiryRequired: false), isNull);
      expect(validateDocDates(issue: DateTime(2026, 2, 1), expiry: DateTime(2026, 1, 1), expiryRequired: true), isNotNull);
      expect(validateDocDates(issue: DateTime(2026, 1, 1), expiry: DateTime(2027, 1, 1), expiryRequired: true), isNull);
    });
  });
}
