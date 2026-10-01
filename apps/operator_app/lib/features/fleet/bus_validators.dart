/// Validation and helpers for bus setup (Stage A). Pure Dart so it is unit-tested.
class BusValidators {
  BusValidators._();

  /// Standard Indian format: state/UT code (2 letters) + RTO code (2 digits)
  /// + series (1-3 letters) + number (4 digits), e.g. KA 01 AB 1234.
  static final _regRe = RegExp(r'^([A-Z]{2})(\d{2})([A-Z]{1,3})(\d{4})$');

  /// State and union-territory codes issued under the Motor Vehicles Act
  /// (includes the pre-2019 codes still in use: DD, DN, OD/OR, UK/UA, TS/TG).
  static const stateCodes = {
    'AN', 'AP', 'AR', 'AS', 'BR', 'CG', 'CH', 'DD', 'DL', 'DN', 'GA', 'GJ', 'HP', 'HR', 'JH', 'JK', 'KA', 'KL',
    'LA', 'LD', 'MH', 'ML', 'MN', 'MP', 'MZ', 'NL', 'OD', 'OR', 'PB', 'PY', 'RJ', 'SK', 'TG', 'TN', 'TR', 'TS',
    'UA', 'UK', 'UP', 'WB',
  };

  static String normalizeRegistration(String v) => v.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

  static String? registrationNumber(String? v) {
    if (v == null || v.trim().isEmpty) return 'Registration number is required';
    final m = _regRe.firstMatch(normalizeRegistration(v));
    if (m == null) return 'Enter a valid registration number in the format AA 00 AA 0000';
    if (!stateCodes.contains(m.group(1))) return '"${m.group(1)}" is not a valid Indian state/UT code';
    if (m.group(2) == '00') return 'RTO code cannot be 00';
    if (m.group(4) == '0000') return 'Vehicle number cannot be 0000';
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
