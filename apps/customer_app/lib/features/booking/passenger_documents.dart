/// Identity document every passenger must provide for boarding verification: the TYPE and the NUMBER only
/// (no photo or scan is ever collected). Formats mirror `private.normalize_document` on the server,
/// which is the authority and refuses a booking without a valid ID.
library;

enum DocType { aadhaar, pan, passport, drivingLicence, voterId, other }

extension DocTypeX on DocType {
  String get wire => switch (this) {
        DocType.aadhaar => 'aadhaar',
        DocType.pan => 'pan',
        DocType.passport => 'passport',
        DocType.drivingLicence => 'driving_licence',
        DocType.voterId => 'voter_id',
        DocType.other => 'other',
      };

  String get label => switch (this) {
        DocType.aadhaar => 'Aadhaar card',
        DocType.pan => 'PAN',
        DocType.passport => 'Passport',
        DocType.drivingLicence => 'Driving licence',
        DocType.voterId => 'Voter ID',
        DocType.other => 'Other Indian ID document',
      };
}

/// The choices offered to the passenger. (PAN, passport and voter ID are entered as "Other Indian ID document".)
const bookableDocTypes = <DocType>[DocType.aadhaar, DocType.drivingLicence, DocType.other];

/// Uppercase, without spaces and hyphens.
String normalizeDocumentNumber(String input) => input.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

/// Returns an error message, or null when the number is acceptable.
String? validateDocumentNumber(DocType type, String input) {
  final v = normalizeDocumentNumber(input);
  final ok = switch (type) {
    DocType.aadhaar => RegExp(r'^[0-9]{12}$').hasMatch(v),
    DocType.pan => RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$').hasMatch(v),
    DocType.passport => RegExp(r'^[A-Z][0-9]{7}$').hasMatch(v),
    DocType.voterId => RegExp(r'^[A-Z]{3}[0-9]{7}$').hasMatch(v),
    DocType.drivingLicence || DocType.other => RegExp(r'^[A-Z0-9/]{4,20}$').hasMatch(v),
  };
  return ok ? null : 'Enter a valid ${type.label} number';
}

/// What the operator will see for a document: type + last four characters only.
String maskDocumentNumber(DocType type, String input) {
  final v = normalizeDocumentNumber(input);
  final last4 = v.length <= 4 ? v : v.substring(v.length - 4);
  return switch (type) {
    DocType.aadhaar => 'XXXX-XXXX-$last4',
    DocType.pan => 'XXXXXX$last4',
    _ => 'XXXX$last4',
  };
}

/// ID fields added to each passenger sent to `create_booking`.
Map<String, String> documentFields(DocType type, String number) => {'doc_type': type.wire, 'doc_number': number.trim()};

/// Null when this passenger's ID is complete and valid, otherwise what to tell the customer.
String? validatePassengerId(DocType? type, String number) {
  if (type == null) return 'Choose an ID type';
  if (number.trim().isEmpty) return 'Enter the ${type.label} number';
  return validateDocumentNumber(type, number);
}
