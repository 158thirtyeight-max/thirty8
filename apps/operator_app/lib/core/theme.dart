// Thirty8's visual identity now lives in the shared `design_system`
// package (`packages/design_system`) so the customer and operator apps
// never drift apart. Don't redefine colors/typography/radii here — add a
// token to that package instead. Re-exported so existing call sites
// (`AppTheme.light()` / `AppTheme.dark()`) keep working unchanged.
export 'package:design_system/design_system.dart' show AppTheme;
