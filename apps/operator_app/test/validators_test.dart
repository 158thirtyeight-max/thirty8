import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/onboarding/validators.dart';

void main() {
  group('PAN', () {
    test('accepts valid, normalizes case', () {
      expect(Validators.pan('ABCDE1234F'), isNull);
      expect(Validators.pan(' abcde1234f '), isNull);
    });
    test('rejects bad formats', () {
      expect(Validators.pan(''), isNotNull);
      expect(Validators.pan('ABCDE12345'), isNotNull);
      expect(Validators.pan('ABCD1234EF'), isNotNull);
      expect(Validators.pan('ABCDE1234'), isNotNull);
    });
  });

  group('GSTIN', () {
    const pan = 'ABCDE1234F';
    const good = '35ABCDE1234F1Z5';
    test('accepts valid GSTIN matching PAN', () {
      expect(Validators.gstin(good, pan: pan), isNull);
      expect(Validators.gstin(good.toLowerCase(), pan: pan.toLowerCase()), isNull);
    });
    test('rejects wrong length/format', () {
      expect(Validators.gstin('35ABCDE1234F1Z'), isNotNull);
      expect(Validators.gstin('35ABCDE1234F1X5'), isNotNull);
      expect(Validators.gstin(''), isNotNull);
    });
    test('rejects invalid state code', () {
      expect(Validators.gstin('99ABCDE1234F1Z5'), 'GSTIN has an invalid state code');
      expect(Validators.gstin('00ABCDE1234F1Z5'), 'GSTIN has an invalid state code');
    });
    test('rejects GSTIN whose embedded PAN differs', () {
      expect(Validators.gstin(good, pan: 'ZZZZZ9999Z'), 'GSTIN does not match the PAN entered');
    });
    test('skips PAN match when no PAN given', () {
      expect(Validators.gstin(good), isNull);
    });
  });

  group('PIN code', () {
    test('valid/invalid', () {
      expect(Validators.pinCode('744101'), isNull);
      expect(Validators.pinCode('044101'), isNotNull);
      expect(Validators.pinCode('7441'), isNotNull);
      expect(Validators.pinCode('74410a'), isNotNull);
      expect(Validators.pinCode(''), isNotNull);
    });
  });

  group('mobile', () {
    test('accepts common Indian formats', () {
      expect(Validators.mobile('9876543210'), isNull);
      expect(Validators.mobile('+91 98765 43210'), isNull);
      expect(Validators.mobile('919876543210'), isNull);
      expect(Validators.mobile('09876543210'), isNull);
    });
    test('rejects invalid', () {
      expect(Validators.mobile('1234567890'), isNotNull);
      expect(Validators.mobile('98765'), isNotNull);
      expect(Validators.mobile(''), isNotNull);
    });
    test('normalizes', () {
      expect(Validators.normalizeMobile('+91 98765-43210'), '9876543210');
    });
  });

  group('bank', () {
    test('IFSC', () {
      expect(Validators.ifsc('SBIN0001234'), isNull);
      expect(Validators.ifsc(' sbin0001234 '), isNull);
      expect(Validators.ifsc('SBIN1001234'), isNotNull);
      expect(Validators.ifsc('SBI0001234'), isNotNull);
      expect(Validators.ifsc(''), isNotNull);
    });
    test('account number', () {
      expect(Validators.accountNumber('123456789'), isNull);
      expect(Validators.accountNumber('1234 5678 9012 3456'), isNull);
      expect(Validators.accountNumber('12345678'), isNotNull);
      expect(Validators.accountNumber('1234567890123456789'), isNotNull);
      expect(Validators.accountNumber('12345678A'), isNotNull);
    });
    test('confirm account number', () {
      expect(Validators.confirmAccountNumber('1234 5678 90', '1234567890'), isNull);
      expect(Validators.confirmAccountNumber('1234567891', '1234567890'), 'Account numbers do not match');
      expect(Validators.confirmAccountNumber('', '1234567890'), isNotNull);
    });
    test('MICR is optional but must be 9 digits', () {
      expect(Validators.micr(''), isNull);
      expect(Validators.micr('744002001'), isNull);
      expect(Validators.micr('7440'), isNotNull);
    });
  });

  group('email / required', () {
    test('email', () {
      expect(Validators.email('a@b.co'), isNull);
      expect(Validators.email('a@b'), isNotNull);
      expect(Validators.email(''), isNotNull);
    });
    test('required', () {
      expect(Validators.required('  ', 'City'), 'City is required');
      expect(Validators.required('x'), isNull);
    });
  });

  group('requirementApplies', () {
    test('empty condition always applies', () {
      expect(requirementApplies({}, businessType: 'bus', gstRegistered: null), isTrue);
      expect(requirementApplies(null, businessType: 'bus', gstRegistered: null), isTrue);
    });
    test('GST condition depends on registration', () {
      const c = {'gst_registered': true};
      expect(requirementApplies(c, businessType: 'bus', gstRegistered: true), isTrue);
      expect(requirementApplies(c, businessType: 'bus', gstRegistered: false), isFalse);
      expect(requirementApplies(c, businessType: 'bus', gstRegistered: null), isFalse);
    });
    test('business type condition', () {
      const c = {'business_type_in': ['cargo', 'both']};
      expect(requirementApplies(c, businessType: 'cargo', gstRegistered: false), isTrue);
      expect(requirementApplies(c, businessType: 'bus', gstRegistered: false), isFalse);
    });
  });

  group('document file validation', () {
    test('type and size', () {
      expect(validateDocumentFile(fileName: 'a.pdf', sizeBytes: 100), isNull);
      expect(validateDocumentFile(fileName: 'a.JPG', sizeBytes: 100), isNull);
      expect(validateDocumentFile(fileName: 'a.exe', sizeBytes: 100), isNotNull);
      expect(validateDocumentFile(fileName: 'noext', sizeBytes: 100), isNotNull);
      expect(validateDocumentFile(fileName: 'a.pdf', sizeBytes: maxDocumentBytes + 1), isNotNull);
      expect(validateDocumentFile(fileName: 'a.pdf', sizeBytes: 0), isNotNull);
    });
  });
}
