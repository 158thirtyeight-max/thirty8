import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// Which brand mark to render. `plain` is the customer-facing `thirty8`
/// mark; `plus` is the operator/seller `thirty8 plus` mark (same monogram +
/// pink "+" badge), used by the operator app and the admin panel.
enum AppLogoVariant { plain, plus }

/// The "38" monogram, from the single source of truth in
/// `design-system/brand/` (copied into this package's `assets/brand/` since
/// Flutter can't reference assets outside the package root — see
/// `DESIGN_SYSTEM.md`). Use this for standalone icon placement (splash
/// screens); use [AppLogoLockup] wherever the wordmark should appear too.
class AppLogoMark extends StatelessWidget {
  const AppLogoMark({super.key, this.variant = AppLogoVariant.plain, this.size = 48});

  final AppLogoVariant variant;
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = variant == AppLogoVariant.plus
        ? 'packages/design_system/assets/brand/thirty8-plus-mark.png'
        : 'packages/design_system/assets/brand/thirty8-mark.png';
    return Image.asset(asset, width: size, height: size);
  }
}

/// Mark + wordmark, for headers and login/auth screens. Renders "thirty8"
/// in the app's own type system (not baked into the artwork) so it always
/// matches the surrounding UI; the `plus` variant adds a small "plus"
/// caption next to it.
class AppLogoLockup extends StatelessWidget {
  const AppLogoLockup({super.key, this.variant = AppLogoVariant.plain, this.markSize = 32, this.color});

  final AppLogoVariant variant;
  final double markSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final textColor = color ?? AppColors.textPrimary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppLogoMark(variant: variant, size: markSize),
        SizedBox(width: AppSpacing.xs),
        Text('thirty8', style: AppTypography.h3(textColor).copyWith(fontWeight: FontWeight.w800)),
        if (variant == AppLogoVariant.plus) ...[
          SizedBox(width: AppSpacing.xs / 2),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text('plus', style: AppTypography.label(AppColors.textSecondary)),
          ),
        ],
      ],
    );
  }
}
