import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';
import 'app_button.dart';

/// The empty/loading/error placeholder trio every list/detail screen needs.
/// Use these instead of a one-off `Text('No results')` or a bare spinner so
/// every screen's "nothing to show" moment looks the same.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({super.key, required this.message, this.icon = Icons.inbox_outlined, this.action});

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl, horizontal: AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: AppColors.textTertiary),
          const SizedBox(height: AppSpacing.md),
          Text(message, textAlign: TextAlign.center, style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
          if (action != null) ...[const SizedBox(height: AppSpacing.md), action!],
        ],
      ),
    );
  }
}

class AppLoadingState extends StatelessWidget {
  const AppLoadingState({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(message!, style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
          ],
        ],
      ),
    );
  }
}

class AppErrorState extends StatelessWidget {
  const AppErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl, horizontal: AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: AppColors.error),
          const SizedBox(height: AppSpacing.md),
          Text(message, textAlign: TextAlign.center, style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary)),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppButton(label: 'Retry', onPressed: onRetry, variant: AppButtonVariant.outline, size: AppButtonSize.small),
          ],
        ],
      ),
    );
  }
}
