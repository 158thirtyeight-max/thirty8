import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../onboarding/onboarding_providers.dart';

String _pretty(String s) {
  final t = s.replaceAll('_', ' ');
  return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
}

/// Keeps only the last four characters visible.
String maskAccountNumber(String? number) {
  if (number == null || number.isEmpty) return '—';
  final digits = number.trim();
  if (digits.length <= 4) return digits;
  return '${'•' * (digits.length - 4)}${digits.substring(digits.length - 4)}';
}

/// Read-only list of the operator's business documents and review status.
class BusinessDocumentsScreen extends ConsumerWidget {
  const BusinessDocumentsScreen({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final docs = ref.watch(operatorDocumentsProvider(context.operatorId));
    return Scaffold(
      appBar: AppBar(title: const Text('Business documents')),
      body: docs.when(
        loading: () => const Center(child: AppLoadingState()),
        error: (e, _) => Center(
          child: AppErrorState(
            message: 'Could not load documents.',
            onRetry: () => ref.invalidate(operatorDocumentsProvider(context.operatorId)),
          ),
        ),
        data: (rows) => rows.isEmpty
            ? const Center(child: AppEmptyState(message: 'No documents on file yet.', icon: Icons.description_outlined))
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  for (final d in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: AppCard(
                        padding: EdgeInsets.zero,
                        child: AppListItem(
                          leading: const Icon(Icons.description_outlined),
                          title: _pretty(d['doc_type'] as String),
                          subtitle: (d['status'] == 'rejected' && d['rejection_reason'] != null)
                              ? 'Rejected: ${d['rejection_reason']}'
                              : (d['file_name'] as String? ?? ''),
                          trailing: AppBadge(status: d['status'] as String),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Read-only payout account. The account number is masked; changes go
/// through the review workflow, not this screen.
class PayoutDetailsScreen extends ConsumerWidget {
  const PayoutDetailsScreen({super.key, required this.context});

  final OperatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final bank = ref.watch(operatorBankProvider(context.operatorId));
    final theme = Theme.of(buildContext);
    Widget row(String label, String? value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 130, child: Text(label, style: theme.textTheme.bodySmall)),
              Expanded(child: Text(value == null || value.isEmpty ? '—' : value)),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Payout details')),
      body: bank.when(
        loading: () => const Center(child: AppLoadingState()),
        error: (e, _) => Center(
          child: AppErrorState(
            message: 'Could not load payout details.',
            onRetry: () => ref.invalidate(operatorBankProvider(context.operatorId)),
          ),
        ),
        data: (b) => b.isEmpty
            ? const Center(child: AppEmptyState(message: 'No payout account on file yet.', icon: Icons.account_balance_outlined))
            : ListView(
                padding: const EdgeInsets.all(AppSpacing.md),
                children: [
                  AppCard(
                    child: Column(
                      children: [
                        row('Account holder', b['account_holder_name'] as String?),
                        row('Bank', b['bank_name'] as String?),
                        row('Branch', b['branch_name'] as String?),
                        row('Account number', maskAccountNumber(b['account_number'] as String?)),
                        row('IFSC', b['ifsc'] as String?),
                        row('Account type', (b['account_type'] as String?) == null ? null : _pretty(b['account_type'] as String)),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Settlements are paid to this account. Payout history is in the Earnings tab.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }
}
