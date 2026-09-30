import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_radius.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// Semantic status → color mapping shared with the admin web `Badge`
/// component (`apps/admin_web/src/components/ui.tsx`). Keep the two lists
/// of statuses in sync when either grows.
const Map<String, Color> _statusColors = {
  'approved': AppColors.success,
  'active': AppColors.success,
  'captured': AppColors.success,
  'confirmed': AppColors.success,
  'delivered': AppColors.success,
  'verified': AppColors.success,
  'submitted': AppColors.warning,
  'under_review': AppColors.warning,
  'changes_requested': AppColors.warning,
  'legacy': AppColors.warning,
  'pending': AppColors.warning,
  'draft': AppColors.warning,
  'processing': AppColors.warning,
  'rejected': AppColors.error,
  'suspended': AppColors.error,
  'cancelled': AppColors.error,
  'failed': AppColors.error,
};

/// A pill-shaped status badge. Pass a raw status string (e.g. `"pending"`,
/// `"cancelled"`) — casing and underscores are normalized for display.
class AppBadge extends StatelessWidget {
  const AppBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColors[status.toLowerCase()] ?? AppColors.textTertiary;
    final label = status.replaceAll('_', ' ');
    final display = label.isEmpty ? label : label[0].toUpperCase() + label.substring(1);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs / 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.pillRadius,
      ),
      child: Text(display, style: AppTypography.label(color)),
    );
  }
}

/// A small rounded-pill chip for filters/tags — visually distinct from
/// [AppBadge] (which is always a status color) by using the neutral/primary
/// palette instead.
class AppChip extends StatelessWidget {
  const AppChip({super.key, required this.label, this.selected = false, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final background = selected ? AppColors.primary : AppColors.primaryLight.withValues(alpha: 0.25);
    final foreground = selected ? Colors.white : AppColors.primaryDark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.pillRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          decoration: BoxDecoration(color: background, borderRadius: AppRadius.pillRadius),
          child: Text(label, style: AppTypography.label(foreground)),
        ),
      ),
    );
  }
}
