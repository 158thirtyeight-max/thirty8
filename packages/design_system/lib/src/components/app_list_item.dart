import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// A section header — a label above a group of cards/list items
/// ("Recent Activities", "Recommended Jobs"-style groupings), with an
/// optional trailing action such as "See all".
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: textTheme.titleLarge),
          ?trailing,
        ],
      ),
    );
  }
}

/// A standard row inside a list — leading icon/avatar, title, optional
/// subtitle, optional trailing widget (chevron, value, badge).
class AppListItem extends StatelessWidget {
  const AppListItem({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      leading: leading,
      title: Text(title, style: AppTypography.body(AppColors.textPrimary)),
      subtitle: subtitle != null ? Text(subtitle!, style: AppTypography.bodySmall(AppColors.textSecondary)) : null,
      trailing: trailing ?? (onTap != null ? const Icon(Icons.chevron_right, color: AppColors.textTertiary) : null),
    );
  }
}
