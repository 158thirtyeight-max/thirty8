/// Pure validation helpers for operator onboarding. Every rule here has a
/// matching CHECK constraint (or is a stricter client-side check) in
/// supabase/migrations/20260926000100_onboarding_foundation.sql, so bad data is
/// rejected on both sides.
class Validators {
  Validators._();

  static final _panRe = RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$');
  static final _gstinRe = RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$');
  static final _pinRe = RegExp(r'^[1-9][0-9]{5}$');
  static final _mobileRe = RegExp(r'^[6-9][0-9]{9}$');
  static final _emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static String? required(String? v, [String label = 'This field']) =>
      (v == null || v.trim().isEmpty) ? '$label is required' : null;

  static String normalizePan(String v) => v.trim().toUpperCase();
  static String normalizeGstin(String v) => v.trim().toUpperCase();

  static String? pan(String? v) {
    if (v == null || v.trim().isEmpty) return 'PAN is required';
    return _panRe.hasMatch(normalizePan(v)) ? null : 'Enter a valid PAN (e.g. ABCDE1234F)';
  }

  /// GSTIN is 15 chars: 2-digit state code, the holder's PAN, entity number,
  /// 'Z', checksum. When [pan] is supplied the embedded PAN must match it.
  static String? gstin(String? v, {String? pan}) {
    if (v == null || v.trim().isEmpty) return 'GSTIN is required';
    final g = normalizeGstin(v);
    if (!_gstinRe.hasMatch(g)) return 'Enter a valid 15-character GSTIN';
    final state = int.parse(g.substring(0, 2));
    if (state < 1 || state > 38) return 'GSTIN has an invalid state code';
    if (pan != null && pan.trim().isNotEmpty && g.substring(2, 12) != normalizePan(pan)) {
      return 'GSTIN does not match the PAN entered';
    }
    return null;
  }

  static String? pinCode(String? v) {
    if (v == null || v.trim().isEmpty) return 'PIN code is required';
    return _pinRe.hasMatch(v.trim()) ? null : 'Enter a valid 6-digit PIN code';
  }

  /// Indian mobile number; tolerates spaces/dashes and a +91 / 91 / 0 prefix.
  static String? mobile(String? v) {
    if (v == null || v.trim().isEmpty) return 'Mobile number is required';
    return _mobileRe.hasMatch(normalizeMobile(v)) ? null : 'Enter a valid 10-digit mobile number';
  }

  static String normalizeMobile(String v) {
    var d = v.replaceAll(RegExp(r'[\s\-()]'), '');
    if (d.startsWith('+91')) {
      d = d.substring(3);
    } else if (d.length == 12 && d.startsWith('91')) {
      d = d.substring(2);
    } else if (d.length == 11 && d.startsWith('0')) {
      d = d.substring(1);
    }
    return d;
  }

  static final _ifscRe = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');
  static final _accountRe = RegExp(r'^[0-9]{9,18}$');
  static final _micrRe = RegExp(r'^[0-9]{9}$');

  static String normalizeIfsc(String v) => v.trim().toUpperCase();
  static String normalizeDigits(String v) => v.replaceAll(RegExp(r'[\s-]'), '');

  /// IFSC: 4 letters (bank), a literal 0, then 6 alphanumerics (branch).
  static String? ifsc(String? v) {
    if (v == null || v.trim().isEmpty) return 'IFSC is required';
    return _ifscRe.hasMatch(normalizeIfsc(v)) ? null : 'Enter a valid IFSC (e.g. SBIN0001234)';
  }

  static String? accountNumber(String? v) {
    if (v == null || v.trim().isEmpty) return 'Account number is required';
    return _accountRe.hasMatch(normalizeDigits(v)) ? null : 'Account number must be 9 to 18 digits';
  }

  static String? confirmAccountNumber(String? v, String original) {
    if (v == null || v.trim().isEmpty) return 'Please re-enter the account number';
    return normalizeDigits(v) == normalizeDigits(original) ? null : 'Account numbers do not match';
  }

  /// MICR is optional; when given it must be exactly 9 digits.
  static String? micr(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    return _micrRe.hasMatch(normalizeDigits(v)) ? null : 'MICR must be 9 digits';
  }

  static String? email(String? v) {
    if (v == null || v.trim().isEmpty) return 'Email is required';
    return _emailRe.hasMatch(v.trim()) ? null : 'Enter a valid email address';
  }
}

/// Mirrors `private.requirement_applies` in SQL: does an admin-configured
/// document requirement apply to this operator? Supported condition keys:
/// `gst_registered` (bool) and `business_type_in` (list of bus/cargo/both).
bool requirementApplies(
  Map<String, dynamic>? condition, {
  required String businessType,
  required bool? gstRegistered,
}) {
  if (condition == null || condition.isEmpty) return true;
  if (condition.containsKey('gst_registered') &&
      condition['gst_registered'] != (gstRegistered ?? false)) {
    return false;
  }
  if (condition.containsKey('business_type_in') &&
      !(condition['business_type_in'] as List).contains(businessType)) {
    return false;
  }
  return true;
}

const allowedDocumentExtensions = ['pdf', 'jpg', 'jpeg', 'png'];
const maxDocumentBytes = 10 * 1024 * 1024;

/// Client-side check matching the private bucket's mime/size limits.
String? validateDocumentFile({required String fileName, required int sizeBytes}) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  if (!allowedDocumentExtensions.contains(ext)) return 'Only PDF, JPG or PNG files are allowed';
  if (sizeBytes > maxDocumentBytes) return 'File is larger than 10 MB';
  if (sizeBytes == 0) return 'File is empty';
  return null;
}
