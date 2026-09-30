import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';

String _title(OperatorContext? c) {
  if (c?.status == 'rejected') return 'Application not approved';
  if (c?.status == 'suspended') return 'Account suspended';
  return c?.applicationStatus == 'under_review' ? 'Application under review' : 'Application submitted';
}

String _message(OperatorContext? c) {
  if (c?.status == 'rejected') return 'Your application was not approved. Contact support if you believe this is a mistake.';
  if (c?.status == 'suspended') return 'Your operator account is suspended. Contact support for details.';
  return 'A Thirty8 admin is verifying your business details, KYC, bank information and documents. This usually takes 1–2 business days. We will ask for changes here if anything is unclear.';
}

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
                  _title(contextAsync.value),
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(_message(contextAsync.value), textAlign: TextAlign.center),
                if ((contextAsync.value?.reviewReason ?? '').isNotEmpty &&
                    (contextAsync.value?.status == 'rejected' || contextAsync.value?.status == 'suspended')) ...[
                  const SizedBox(height: 16),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Reason', style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(contextAsync.value!.reviewReason!),
                      ],
                    ),
                  ),
                ],
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
