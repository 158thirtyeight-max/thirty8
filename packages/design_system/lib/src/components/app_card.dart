import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_radius.dart';
import '../app_shadows.dart';
import '../app_spacing.dart';

enum AppCardVariant { standard, elevated, interactive }

/// The one card container every screen should reach for — standard cards
/// sit flush with a hairline border, elevated cards float with a soft
/// shadow, interactive cards additionally respond to taps.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.variant = AppCardVariant.standard,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpacing.md),
  });

  final Widget child;
  final AppCardVariant variant;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final cardColor = isDark ? AppColors.cardDark : AppColors.card;
    final borderColor = isDark ? AppColors.borderDark : AppColors.border;

    final decoration = BoxDecoration(
      color: cardColor,
      borderRadius: AppRadius.lgRadius,
      border: variant == AppCardVariant.elevated ? null : Border.all(color: borderColor),
      boxShadow: variant == AppCardVariant.elevated ? AppShadows.md : AppShadows.none,
    );

    final content = Container(padding: padding, decoration: decoration, child: child);

    if (onTap == null && variant != AppCardVariant.interactive) return content;

    return Material(
      color: Colors.transparent,
      borderRadius: AppRadius.lgRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.lgRadius,
        child: content,
      ),
    );
  }
}

/// A card whose sole content is a big number and a label — dashboards,
/// stat rows.
class AppStatCard extends StatelessWidget {
  const AppStatCard({super.key, required this.label, required this.value, this.icon});

  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: AppColors.textTertiary), const SizedBox(width: AppSpacing.xs)],
              Text(label, style: textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(value, style: textTheme.headlineMedium),
        ],
      ),
    );
  }
}
