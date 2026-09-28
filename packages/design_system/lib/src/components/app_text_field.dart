import 'package:flutter/material.dart';

/// Thin wrapper over [TextField] — exists so every text input in the app
/// carries the same label/hint/error conventions, even though the actual
/// visuals come from `InputDecorationTheme` in [AppTheme]. Prefer this over
/// a bare `TextField` so a future convention change (e.g. a required
/// asterisk on `label`) only needs to change here.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.errorText,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffixIcon,
    this.enabled = true,
    this.onChanged,
    this.maxLines = 1,
    this.maxLength,
    this.textAlign = TextAlign.start,
    this.style,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? errorText;
  final bool obscureText;
  final TextInputType? keyboardType;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final int maxLines;

  /// Caps input length. When set, the character counter is hidden — most
  /// call sites (e.g. an OTP field) use this for a fixed-length code, not to
  /// show a live count.
  final int? maxLength;
  final TextAlign textAlign;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      enabled: enabled,
      onChanged: onChanged,
      maxLines: obscureText ? 1 : maxLines,
      maxLength: maxLength,
      textAlign: textAlign,
      style: style,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: errorText,
        prefixIcon: prefixIcon != null ? Icon(prefixIcon) : null,
        suffixIcon: suffixIcon,
        counterText: maxLength != null ? '' : null,
      ),
    );
  }
}

/// A search field — same visuals as [AppTextField] but always carries the
/// search icon and a rounded-pill shape for the "search this list" pattern.
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    this.controller,
    this.hint = 'Search',
    this.onChanged,
  });

  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AppTextField(
      controller: controller,
      hint: hint,
      prefixIcon: Icons.search,
      onChanged: onChanged,
    );
  }
}
