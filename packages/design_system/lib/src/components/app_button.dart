import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_radius.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

enum AppButtonVariant { primary, secondary, outline, ghost, destructive }

enum AppButtonSize { medium, small }

/// The one button widget every screen should reach for. Variants map to the
/// component list in DESIGN_SYSTEM.md — add a new variant there before
/// inventing a one-off button style in a screen.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.medium,
    this.icon,
    this.expand = false,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final IconData? icon;
  final bool expand;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = onPressed == null || loading;

    final (Color background, Color foreground, BorderSide? border) = switch (variant) {
      AppButtonVariant.primary => (scheme.primary, scheme.onPrimary, null),
      AppButtonVariant.secondary => (AppColors.secondary, Colors.white, null),
      AppButtonVariant.destructive => (AppColors.error, Colors.white, null),
      AppButtonVariant.outline => (Colors.transparent, scheme.primary, BorderSide(color: AppColors.border)),
      AppButtonVariant.ghost => (Colors.transparent, scheme.primary, null),
    };

    final verticalPadding = size == AppButtonSize.small ? AppSpacing.sm : AppSpacing.md;
    final horizontalPadding = size == AppButtonSize.small ? AppSpacing.md : AppSpacing.lg;

    final child = loading
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: foreground), const SizedBox(width: AppSpacing.sm)],
              Text(label, style: AppTypography.button(foreground)),
            ],
          );

    final button = ElevatedButton(
      onPressed: disabled ? null : onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: background,
        disabledBackgroundColor: background.withValues(alpha: variant == AppButtonVariant.ghost || variant == AppButtonVariant.outline ? 0 : 0.4),
        foregroundColor: foreground,
        elevation: 0,
        padding: EdgeInsets.symmetric(vertical: verticalPadding, horizontal: horizontalPadding),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdRadius, side: border ?? BorderSide.none),
      ),
      child: child,
    );

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
