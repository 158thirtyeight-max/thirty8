import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_radius.dart';
import '../app_spacing.dart';
import '../app_typography.dart';

/// Compact wizard progress bar: one segment per step plus a
/// "Step n of N · Title" caption. Completed steps can be tapped to go back.
class AppStepIndicator extends StatelessWidget {
  const AppStepIndicator({super.key, required this.titles, required this.current, this.onStepTap});

  final List<String> titles;
  final int current;
  final ValueChanged<int>? onStepTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final track = isDark ? AppColors.borderDark : AppColors.border;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (var i = 0; i < titles.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onStepTap != null && i < current ? () => onStepTap!(i) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: i <= current ? primary : track,
                        borderRadius: AppRadius.pillRadius,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        Text(
          'Step ${current + 1} of ${titles.length} · ${titles[current]}',
          style: AppTypography.caption(isDark ? AppColors.textSecondaryDark : AppColors.textSecondary),
        ),
      ],
    );
  }
}
