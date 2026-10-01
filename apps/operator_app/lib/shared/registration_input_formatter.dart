import 'package:flutter/services.dart';

/// Formats an Indian vehicle registration as the user types, following the
/// standard layout: 2 letters (state) + 2 digits (RTO) + 1-3 letters (series)
/// + 4 digits — e.g. `KA 01 AB 1234`. Characters that don't fit the next slot
/// are dropped, and a space is inserted between groups automatically.
class RegistrationInputFormatter extends TextInputFormatter {
  const RegistrationInputFormatter();

  static final _letter = RegExp(r'[A-Z]');
  static final _digit = RegExp(r'[0-9]');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final input = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final state = StringBuffer(), rto = StringBuffer(), series = StringBuffer(), number = StringBuffer();

    for (final ch in input.split('')) {
      if (state.length < 2) {
        if (_letter.hasMatch(ch)) state.write(ch);
      } else if (rto.length < 2) {
        if (_digit.hasMatch(ch)) rto.write(ch);
      } else if (number.isEmpty && series.length < 3 && _letter.hasMatch(ch)) {
        series.write(ch);
      } else if (number.length < 4 && _digit.hasMatch(ch) && series.isNotEmpty) {
        number.write(ch);
      }
    }

    final groups = [state, rto, series, number].map((b) => b.toString()).where((s) => s.isNotEmpty);
    var text = groups.join(' ');
    // Keep the auto-space visible once a group is complete, so typing flows on.
    final complete = (state.length == 2 && rto.isEmpty) ||
        (rto.length == 2 && series.isEmpty && number.isEmpty);
    if (complete && newValue.text.length >= oldValue.text.length) text += ' ';
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}
