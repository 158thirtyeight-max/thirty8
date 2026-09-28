import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';

/// Shown when the operator exists but is not yet 'approved' (pending review,
/// rejected, or suspended by a platform admin — Admin Panel, not yet built).
class PendingApprovalScreen extends ConsumerWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contextAsync = ref.watch(operatorContextProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.hourglass_top, size: 64, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  contextAsync.value?.status == 'rejected'
                      ? 'Application not approved'
                      : contextAsync.value?.status == 'suspended'
                          ? 'Account suspended'
                          : 'Application under review',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'A Thirty8 platform admin needs to verify your business details before you can start operating. This usually takes 1–2 business days.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                AppButton(
                  label: 'Check again',
                  variant: AppButtonVariant.outline,
                  onPressed: () => ref.invalidate(operatorContextProvider),
                ),
                const SizedBox(height: 8),
                AppButton(
                  label: 'Sign out',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => ref.read(supabaseProvider).auth.signOut(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
