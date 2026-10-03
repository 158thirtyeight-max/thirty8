import 'package:customer_app/features/booking/booking_errors.dart';
import 'package:customer_app/features/booking/passenger_documents.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the passenger chooses between Aadhaar card, Driving licence and Other Indian ID document', () {
    expect(bookableDocTypes.map((t) => t.label), ['Aadhaar card', 'Driving licence', 'Other Indian ID document']);
  });

  group('validatePassengerId (mandatory)', () {
    test('a type and a number are both required', () {
      expect(validatePassengerId(null, '1234 5678 9012'), 'Choose an ID type');
      expect(validatePassengerId(DocType.aadhaar, ''), contains('Enter the Aadhaar card number'));
      expect(validatePassengerId(DocType.aadhaar, '   '), isNotNull);
    });

    test('Aadhaar: 12 digits, spaces and hyphens allowed', () {
      expect(validatePassengerId(DocType.aadhaar, '1234 5678 9012'), isNull);
      expect(validatePassengerId(DocType.aadhaar, '1234-5678-9012'), isNull);
      expect(validatePassengerId(DocType.aadhaar, '123'), isNotNull);
      expect(validatePassengerId(DocType.aadhaar, '1234 5678 90AB'), isNotNull);
    });

    test('Driving licence and Other Indian ID: 4-20 letters/digits', () {
      expect(validatePassengerId(DocType.drivingLicence, 'AN01 2020 0012345'), isNull);
      expect(validatePassengerId(DocType.other, 'ABCDE1234F'), isNull, reason: 'a PAN fits under Other Indian ID');
      expect(validatePassengerId(DocType.other, 'K1234567'), isNull, reason: 'a passport number too');
      expect(validatePassengerId(DocType.other, 'ab'), isNotNull);
    });
  });

  test('only the type and number are sent — no image, no extra personal data', () {
    final f = documentFields(DocType.drivingLicence, ' AN01 2020 0012345 ');
    expect(f.keys.toSet(), {'doc_type', 'doc_number'});
    expect(f['doc_type'], 'driving_licence');
    expect(f['doc_number'], 'AN01 2020 0012345');
    expect(documentFields(DocType.aadhaar, '1234 5678 9012')['doc_type'], 'aadhaar');
    expect(documentFields(DocType.other, 'X1234')['doc_type'], 'other');
  });

  test('masking keeps only the last four characters', () {
    expect(maskDocumentNumber(DocType.aadhaar, '1234 5678 9012'), 'XXXX-XXXX-9012');
    expect(maskDocumentNumber(DocType.other, 'K1234567'), 'XXXX4567');
  });

  test('normalisation matches the server (uppercase, no spaces/hyphens)', () {
    expect(normalizeDocumentNumber(' ab-12 cd '), 'AB12CD');
  });

  test('missing/invalid ID errors from the server are explained', () {
    expect(bookingErrorMessage(Exception('document_required: an ID type and number are required'), holdExpired: false), contains('ID type and number'));
    expect(bookingErrorMessage(Exception('invalid_document: the aadhaar number is not in a valid format'), holdExpired: false), contains('not valid'));
  });
}
