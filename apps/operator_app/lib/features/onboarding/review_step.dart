import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'onboarding_providers.dart';

/// "1234567890" -> "••••7890". Never shows the full number on review.
String maskAccountNumber(String? n) {
  if (n == null || n.isEmpty) return '-';
  if (n.length <= 4) return n;
  return '••••${n.substring(n.length - 4)}';
}

String _v(Object? v) {
  final s = v?.toString().trim() ?? '';
  return s.isEmpty ? '-' : s;
}

/// Step 5 — full summary of everything entered, with the completeness
/// percentage and an explicit list of what is still missing.
class ReviewStep extends ConsumerWidget {
  const ReviewStep({
    super.key,
    required this.operatorId,
    required this.operator,
    required this.onBack,
    required this.onEditStep,
    required this.onContinue,
  });

  final String operatorId;
  final Map<String, dynamic> operator;
  final VoidCallback onBack;
  final void Function(int step) onEditStep;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(operatorProfileProvider(operatorId));
    final kyc = ref.watch(operatorKycProvider(operatorId));
    final bank = ref.watch(operatorBankProvider(operatorId));
    final docs = ref.watch(operatorDocumentsProvider(operatorId));
    final mandate = ref.watch(operatorMandateProvider(operatorId));
    final completeness = ref.watch(operatorCompletenessProvider(operatorId));

    final firstError = [profile, kyc, bank, docs, mandate, completeness]
        .map((a) => a.hasError ? a.error : null)
        .firstWhere((e) => e != null, orElse: () => null);
    if (firstError != null) {
      return AppErrorState(
        message: 'Could not load your application summary.',
        onRetry: () {
          ref.invalidate(operatorProfileProvider(operatorId));
          ref.invalidate(operatorKycProvider(operatorId));
          ref.invalidate(operatorBankProvider(operatorId));
          ref.invalidate(operatorDocumentsProvider(operatorId));
          ref.invalidate(operatorMandateProvider(operatorId));
          ref.invalidate(operatorCompletenessProvider(operatorId));
        },
      );
    }
    if ([profile, kyc, bank, docs, mandate, completeness].any((a) => !a.hasValue)) {
      return const Center(child: AppLoadingState());
    }

    final p = profile.requireValue;
    final k = kyc.requireValue;
    final b = bank.requireValue;
    final d = docs.requireValue;
    final m = mandate.value;
    final c = completeness.requireValue;
    final missing = List<String>.from(c['missing'] as List);
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Review your application', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Registration ${c['percent']}% complete', style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                LinearProgressIndicator(value: (c['percent'] as num) / 100),
                if (missing.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  for (final item in missing)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 16, color: theme.colorScheme.error),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(child: Text('Missing: $item', style: TextStyle(color: theme.colorScheme.error))),
                        ],
                      ),
                    ),
                ] else ...[
                  const SizedBox(height: AppSpacing.sm),
                  const Text('Everything required is filled in.'),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _Section(
            title: 'Business information',
            onEdit: () => onEditStep(0),
            rows: {
              'Business name': _v(operator['name']),
              'Legal name': _v(operator['legal_name']),
              'Business type': _v(p['business_type_detail']),
              'Owner / authorized person': _v(p['owner_name']),
              'Mobile': _v(operator['contact_phone']),
              'Email': _v(operator['contact_email']),
              'Address': _v(p['address']),
              'City / District': '${_v(p['city'])} / ${_v(p['district'])}',
              'State / PIN': '${_v(p['state'])} - ${_v(p['pin_code'])}',
            },
          ),
          _Section(
            title: 'KYC & GST',
            onEdit: () => onEditStep(1),
            rows: {
              'PAN': _v(k['pan_number']),
              'GST registered': k['gst_registered'] == null ? '-' : (k['gst_registered'] == true ? 'Yes' : 'No'),
              if (k['gst_registered'] == true) 'GSTIN': _v(k['gstin']),
            },
          ),
          _Section(
            title: 'Bank information',
            onEdit: () => onEditStep(2),
            rows: {
              'Account holder': _v(b['account_holder_name']),
              'Bank / Branch': '${_v(b['bank_name'])} / ${_v(b['branch_name'])}',
              'Account number': maskAccountNumber(b['account_number'] as String?),
              'IFSC': _v(b['ifsc']),
              'MICR': _v(b['micr']),
              'Account type': _v(b['account_type']),
            },
          ),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Documents & mandate', style: theme.textTheme.titleSmall)),
                    TextButton(onPressed: () => onEditStep(1), child: const Text('Edit')),
                  ],
                ),
                if (d.isEmpty && m == null) const Text('No documents uploaded yet.'),
                for (final doc in d)
                  _DocRow(label: _docLabel(doc['doc_type'] as String), file: doc['file_name'] as String?, status: doc['status'] as String),
                if (m != null)
                  _DocRow(label: 'Payment mandate', file: m['file_name'] as String?, status: m['status'] as String)
                else
                  const _DocRow(label: 'Payment mandate', file: null, status: null),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(label: 'Continue to submit', expand: true, onPressed: onContinue),
          AppButton(label: 'Back', variant: AppButtonVariant.ghost, expand: true, onPressed: onBack),
        ],
      ),
    );
  }
}

String _docLabel(String type) => switch (type) {
      'pan_card' => 'PAN card',
      'gst_certificate' => 'GST certificate',
      'id_proof' => 'Identity / address proof',
      'other_registration' => 'Other registration document',
      'cancelled_cheque' => 'Cancelled cheque',
      'bank_additional' => 'Additional bank document',
      _ => type.replaceAll('_', ' '),
    };

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows, required this.onEdit});
  final String title;
  final Map<String, String> rows;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                TextButton(onPressed: onEdit, child: const Text('Edit')),
              ],
            ),
            for (final e in rows.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 130, child: Text(e.key, style: theme.textTheme.bodySmall)),
                    Expanded(child: Text(e.value)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DocRow extends StatelessWidget {
  const _DocRow({required this.label, required this.file, required this.status});
  final String label;
  final String? file;
  final String? status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(file == null ? label : '$label — $file', overflow: TextOverflow.ellipsis)),
          if (status != null) AppBadge(status: status!) else const Text('Not uploaded'),
        ],
      ),
    );
  }
}

/// Step 6 — declaration + submit. The button is disabled until the server-side
/// completeness check reports 100%; the RPC re-checks it regardless.
class SubmitStep extends ConsumerStatefulWidget {
  const SubmitStep({super.key, required this.operatorId, required this.onBack});

  final String operatorId;
  final VoidCallback onBack;

  @override
  ConsumerState<SubmitStep> createState() => _SubmitStepState();
}

class _SubmitStepState extends ConsumerState<SubmitStep> {
  bool _agreed = false;
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc('submit_operator_application', params: {
        'p_operator_id': widget.operatorId,
      });
      ref.invalidate(operatorContextProvider);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().contains('incomplete')
            ? 'Some required information is still missing. Go back to review.'
            : 'Could not submit. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final completeness = ref.watch(operatorCompletenessProvider(widget.operatorId));
    final theme = Theme.of(context);
    final c = completeness.value;
    final complete = c != null && c['complete'] == true;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Submit application', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Once submitted, an admin will review your business, KYC, bank details and documents. '
            'You will not be able to edit them while the review is in progress, unless changes are requested. '
            'You can add and configure your buses after approval.',
          ),
          const SizedBox(height: AppSpacing.md),
          if (completeness.isLoading && c == null)
            const AppLoadingState()
          else if (!complete) ...[
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Registration ${c?['percent'] ?? 0}% complete', style: theme.textTheme.titleSmall),
                  for (final m in List<String>.from((c?['missing'] as List?) ?? const []))
                    Text('Missing: $m', style: TextStyle(color: theme.colorScheme.error)),
                ],
              ),
            ),
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _agreed,
            onChanged: _submitting ? null : (v) => setState(() => _agreed = v ?? false),
            title: const Text('I confirm the information and documents provided are accurate and belong to my business.'),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Submit for approval',
            expand: true,
            loading: _submitting,
            onPressed: (!complete || !_agreed || _submitting) ? null : _submit,
          ),
          AppButton(
            label: 'Back',
            variant: AppButtonVariant.ghost,
            expand: true,
            onPressed: _submitting ? null : widget.onBack,
          ),
        ],
      ),
    );
  }
}
