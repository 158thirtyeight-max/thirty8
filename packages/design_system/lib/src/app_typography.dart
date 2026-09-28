import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Type scale. Mirrors `design-system/tokens.json` → `typography`.
/// Built on Inter so Flutter and the Next.js admin share the same typeface
/// family and proportions.
class AppTypography {
  AppTypography._();

  static TextStyle _style(double size, FontWeight weight, double height, double letterSpacing, Color color) {
    return GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  static TextStyle display(Color color) => _style(34, FontWeight.w700, 1.15, -0.5, color);
  static TextStyle h1(Color color) => _style(28, FontWeight.w700, 1.2, -0.3, color);
  static TextStyle h2(Color color) => _style(24, FontWeight.w700, 1.25, -0.2, color);
  static TextStyle h3(Color color) => _style(20, FontWeight.w600, 1.3, 0, color);
  static TextStyle h4(Color color) => _style(18, FontWeight.w600, 1.35, 0, color);
  static TextStyle bodyLarge(Color color) => _style(16, FontWeight.w400, 1.5, 0, color);
  static TextStyle body(Color color) => _style(14, FontWeight.w400, 1.5, 0, color);
  static TextStyle bodySmall(Color color) => _style(13, FontWeight.w400, 1.45, 0, color);
  static TextStyle caption(Color color) => _style(12, FontWeight.w400, 1.4, 0.1, color);
  static TextStyle button(Color color) => _style(15, FontWeight.w600, 1.2, 0.1, color);
  static TextStyle label(Color color) => _style(13, FontWeight.w500, 1.3, 0.1, color);
  static TextStyle navLabel(Color color) => _style(12, FontWeight.w500, 1.2, 0.1, color);

  /// Builds a full Material [TextTheme] from the scale above, for the
  /// `textPrimary`/`textSecondary` tokens of the given brightness.
  static TextTheme textTheme({required Color primaryText, required Color secondaryText}) {
    return TextTheme(
      displayLarge: display(primaryText),
      headlineLarge: h1(primaryText),
      headlineMedium: h2(primaryText),
      headlineSmall: h3(primaryText),
      titleLarge: h4(primaryText),
      bodyLarge: bodyLarge(primaryText),
      bodyMedium: body(primaryText),
      bodySmall: bodySmall(secondaryText),
      labelLarge: button(primaryText),
      labelMedium: label(secondaryText),
      labelSmall: navLabel(secondaryText),
    );
  }
}
