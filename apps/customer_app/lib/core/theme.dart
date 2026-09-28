import 'package:design_system/design_system.dart';
import 'package:flutter/widgets.dart' show Color;

// Thirty8's visual identity now lives in the shared `design_system`
// package (`packages/design_system`) so the customer and operator apps
// never drift apart. Don't redefine colors/typography/radii here — add a
// token to that package instead. Re-exported so existing call sites
// (`AppTheme.light()` / `AppTheme.dark()`) keep working unchanged.
export 'package:design_system/design_system.dart' show AppTheme;

/// Seat-map colors are semantic, not cosmetic — never rely on color alone
/// (also carry a label/icon), per the plan's accessibility requirement.
/// This is booking-domain logic specific to the customer app, so it stays
/// here rather than in the shared package, but draws from the same brand
/// palette where a token applies.
class SeatColors {
  SeatColors._();

  static const available = AppColors.success;
  static const selected = AppColors.primary;
  static const booked = AppColors.textTertiary;
  static const blocked = AppColors.error;
  static const ladiesOnly = Color(0xFFEC4899);
}
