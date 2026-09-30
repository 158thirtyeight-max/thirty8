/// Validation and helpers for bus setup (Stage A). Pure Dart so it is unit-tested.
class BusValidators {
  BusValidators._();

  static final _regRe = RegExp(r'^[A-Z0-9]{6,13}$');

  static String normalizeRegistration(String v) => v.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

  /// Indian registrations look like AN01A1234 / KA01AB1234 / 22BH1234AA. We
  /// don't try to encode every state format; we require 6-13 letters/digits
  /// with at least one letter and one digit.
  static String? registrationNumber(String? v) {
    if (v == null || v.trim().isEmpty) return 'Registration number is required';
    final n = normalizeRegistration(v);
    if (!_regRe.hasMatch(n) || !n.contains(RegExp(r'[A-Z]')) || !n.contains(RegExp(r'[0-9]'))) {
      return 'Enter a valid registration number (e.g. AN01A1234)';
    }
    return null;
  }

  static String? year(String? v, {required String label, int? notBefore, int? maxYear}) {
    if (v == null || v.trim().isEmpty) return '$label is required';
    final y = int.tryParse(v.trim());
    final max = maxYear ?? DateTime.now().year + 1;
    if (y == null || y < 1980 || y > max) return 'Enter a year between 1980 and $max';
    if (notBefore != null && y < notBefore) return '$label cannot be before the manufacturing year';
    return null;
  }

  static String? seats(String? v) {
    final n = int.tryParse((v ?? '').trim());
    if (n == null || n < 1 || n > 80) return 'Enter a number between 1 and 80';
    return null;
  }
}

/// bus_type values allowed by the buses table CHECK constraint.
String composeBusType({required bool ac, required String seating}) {
  assert(const ['seater', 'sleeper', 'semi_sleeper'].contains(seating));
  return '${ac ? 'ac' : 'non_ac'}_$seating';
}

({bool ac, String seating}) parseBusType(String busType) {
  final ac = !busType.startsWith('non_ac');
  final seating = busType.replaceFirst(ac ? 'ac_' : 'non_ac_', '');
  return (ac: ac, seating: seating);
}

String busTypeLabel(String busType) {
  final t = parseBusType(busType);
  final seating = switch (t.seating) {
    'seater' => 'Seater',
    'sleeper' => 'Sleeper',
    'semi_sleeper' => 'Semi-sleeper',
    _ => t.seating,
  };
  return '${t.ac ? 'AC' : 'Non-AC'} $seating';
}

/// Mirrors `private.bus_requirement_applies` in SQL.
bool busRequirementApplies(Map<String, dynamic>? condition, String busType) {
  if (condition == null || condition.isEmpty) return true;
  if (condition.containsKey('bus_type_in') && !(condition['bus_type_in'] as List).contains(busType)) return false;
  if (condition.containsKey('bus_type_not_in') && (condition['bus_type_not_in'] as List).contains(busType)) return false;
  return true;
}

enum DocExpiryState { noExpiry, valid, expiringSoon, expired }

DocExpiryState docExpiryState(DateTime? expiry, {DateTime? today, int soonDays = 30}) {
  if (expiry == null) return DocExpiryState.noExpiry;
  final now = today ?? DateTime.now();
  final t = DateTime(now.year, now.month, now.day);
  final e = DateTime(expiry.year, expiry.month, expiry.day);
  if (e.isBefore(t)) return DocExpiryState.expired;
  if (e.difference(t).inDays <= soonDays) return DocExpiryState.expiringSoon;
  return DocExpiryState.valid;
}

/// Client-side check for the issue/expiry dates entered for a document.
String? validateDocDates({required DateTime? issue, required DateTime? expiry, required bool expiryRequired}) {
  if (expiryRequired && expiry == null) return 'Expiry date is required';
  if (issue != null && expiry != null && expiry.isBefore(issue)) return 'Expiry date cannot be before the issue date';
  if (issue != null && issue.isAfter(DateTime.now().add(const Duration(days: 1)))) return 'Issue date cannot be in the future';
  return null;
}
