import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'onboarding_providers.dart';
import 'requirement_documents.dart';
import 'validators.dart';

/// Step 2 — KYC & tax. GST is only requested (and only mandatory) when the
/// operator says they are GST registered; the list of required documents comes
/// from the admin-configurable document_requirements table.
class KycStep extends ConsumerWidget {
  const KycStep({
    super.key,
    required this.operatorId,
    required this.businessType,
    required this.onBack,
    required this.onSaved,
  });

  final String operatorId;
  final String businessType;
  final VoidCallback onBack;
  final void Function({required bool advance}) onSaved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kycAsync = ref.watch(operatorKycProvider(operatorId));
    return kycAsync.when(
      data: (kyc) => _KycForm(
        operatorId: operatorId,
        businessType: businessType,
        kyc: kyc,
        onBack: onBack,
        onSaved: onSaved,
      ),
      loading: () => const Center(child: AppLoadingState()),
      error: (e, _) => AppErrorState(
        message: 'Could not load your saved details.',
        onRetry: () => ref.invalidate(operatorKycProvider(operatorId)),
      ),
    );
  }
}

class _KycForm extends ConsumerStatefulWidget {
  const _KycForm({
    required this.operatorId,
    required this.businessType,
    required this.kyc,
    required this.onBack,
    required this.onSaved,
  });

  final String operatorId;
  final String businessType;
  final Map<String, dynamic> kyc;
  final VoidCallback onBack;
  final void Function({required bool advance}) onSaved;

  @override
  ConsumerState<_KycForm> createState() => _KycFormState();
}

class _KycFormState extends ConsumerState<_KycForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _pan;
  late final TextEditingController _gstin;
  bool? _gstRegistered;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pan = TextEditingController(text: (widget.kyc['pan_number'] as String?) ?? '');
    _gstin = TextEditingController(text: (widget.kyc['gstin'] as String?) ?? '');
    _gstRegistered = widget.kyc['gst_registered'] as bool?;
  }

  @override
  void dispose() {
    _pan.dispose();
    _gstin.dispose();
    super.dispose();
  }

  Future<bool> _persist() async {
    try {
      await ref.read(onboardingRepositoryProvider).saveKyc(
            operatorId: widget.operatorId,
            pan: _pan.text,
            gstRegistered: _gstRegistered,
            gstin: _gstin.text,
          );
      ref.invalidate(operatorKycProvider(widget.operatorId));
      ref.invalidate(operatorCompletenessProvider(widget.operatorId));
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save. Please check your details and try again.');
      return false;
    }
  }

  Future<void> _save({required bool advance}) async {
    if (advance && !_formKey.currentState!.validate()) return;
    if (advance && _gstRegistered == null) {
      setState(() => _error = 'Please tell us whether you are GST registered.');
      return;
    }
    // Saving for later tolerates half-filled fields, but never bad formats.
    if (!advance) {
      final bad = (_pan.text.trim().isNotEmpty ? Validators.pan(_pan.text) : null) ??
          (_gstRegistered == true && _gstin.text.trim().isNotEmpty
              ? Validators.gstin(_gstin.text, pan: _pan.text)
              : null);
      if (bad != null) {
        setState(() => _error = bad);
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await _persist();
    if (ok) {
      final repo = ref.read(onboardingRepositoryProvider);
      if (advance) await repo.markStep(widget.operatorId, 3);
      if (mounted) {
        if (!advance) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Progress saved. You can continue later.')));
        }
        widget.onSaved(advance: advance);
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final completeness = ref.watch(operatorCompletenessProvider(widget.operatorId)).value;
    final busy = _saving;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('KYC & tax', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'GST is only required if your business is GST registered.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _pan,
              label: 'PAN number',
              textCapitalization: TextCapitalization.characters,
              maxLength: 10,
              validator: Validators.pan,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('Is your business GST registered?', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            SegmentedButton<bool>(
              emptySelectionAllowed: true,
              segments: const [
                ButtonSegment(value: true, label: Text('Yes')),
                ButtonSegment(value: false, label: Text('No')),
              ],
              selected: {?_gstRegistered},
              onSelectionChanged: busy ? null : (s) => setState(() => _gstRegistered = s.isEmpty ? null : s.first),
            ),
            if (_gstRegistered == true) ...[
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _gstin,
                label: 'GSTIN',
                textCapitalization: TextCapitalization.characters,
                maxLength: 15,
                validator: (v) => Validators.gstin(v, pan: _pan.text),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text('Documents', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text('PDF, JPG or PNG, up to 10 MB each.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
            RequirementDocuments(
              operatorId: widget.operatorId,
              businessType: widget.businessType,
              gstRegistered: _gstRegistered,
              step: 'kyc',
              onError: (m) => setState(() => _error = m),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (completeness != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                'Registration ${completeness['percent']}% complete',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: 'Save & continue',
              expand: true,
              loading: busy,
              onPressed: busy ? null : () => _save(advance: true),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Save & continue later',
              variant: AppButtonVariant.ghost,
              expand: true,
              onPressed: busy ? null : () => _save(advance: false),
            ),
            AppButton(
              label: 'Back',
              variant: AppButtonVariant.ghost,
              expand: true,
              onPressed: busy ? null : widget.onBack,
            ),
          ],
        ),
      ),
    );
  }
}
