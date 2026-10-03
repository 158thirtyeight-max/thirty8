import 'package:design_system/design_system.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../shared/document_upload_tile.dart';
import 'mandate_pdf.dart';
import 'onboarding_providers.dart';
import 'validators.dart';

/// Step 4 — payment mandate: generate the form pre-filled with
/// the operator's details, sign & stamp it offline, upload the scan, and
/// track its verification status.
class MandateStep extends ConsumerStatefulWidget {
  const MandateStep({
    super.key,
    required this.operatorId,
    required this.operator,
    required this.onBack,
    required this.onSaved,
  });

  final String operatorId;
  final Map<String, dynamic> operator;
  final VoidCallback onBack;
  final void Function({required bool advance}) onSaved;

  @override
  ConsumerState<MandateStep> createState() => _MandateStepState();
}

class _MandateStepState extends ConsumerState<MandateStep> {
  bool _uploading = false;
  bool _generating = false;
  bool _saving = false;
  String? _error;

  Future<MandateFormData> _formData() async {
    final profile = await ref.read(operatorProfileProvider(widget.operatorId).future);
    final bank = await ref.read(operatorBankProvider(widget.operatorId).future);
    final op = widget.operator;
    String s(Map<String, dynamic> m, String k) => (m[k] as String?) ?? '';
    final address = [s(profile, 'address'), s(profile, 'city'), s(profile, 'district'), s(profile, 'state'), s(profile, 'pin_code')]
        .where((p) => p.isNotEmpty)
        .join(', ');
    return MandateFormData(
      legalName: s(op, 'legal_name'),
      businessName: s(op, 'name'),
      ownerName: s(profile, 'owner_name'),
      address: address,
      accountHolder: s(bank, 'account_holder_name'),
      bankName: s(bank, 'bank_name'),
      branchName: s(bank, 'branch_name'),
      accountNumber: s(bank, 'account_number'),
      ifsc: s(bank, 'ifsc'),
      accountType: s(bank, 'account_type'),
    );
  }

  Future<void> _generate({required bool share}) async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final bytes = await buildMandatePdf(await _formData());
      if (share) {
        await Printing.sharePdf(bytes: bytes, filename: 'thirty8-payment-mandate.pdf');
      } else {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'thirty8-payment-mandate.pdf');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not generate the mandate form.');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  PlatformFile? _picked;
  String? _pickedProblem;

  Future<void> _pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedDocumentExtensions,
    );
    if (file == null) return;
    final size = (await file.length()) ?? 0;
    setState(() {
      _picked = file;
      _pickedProblem = validateDocumentFile(fileName: file.name, sizeBytes: size);
      _error = null;
    });
  }

  Future<void> _upload(Map<String, dynamic>? existing) async {
    final file = _picked;
    if (file == null || _pickedProblem != null) return;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      await ref.read(onboardingRepositoryProvider).uploadMandate(
            operatorId: widget.operatorId,
            file: file,
            templateVersion: mandateTemplateVersion,
            existingPath: existing?['file_path'] as String?,
          );
      ref.invalidate(operatorMandateProvider(widget.operatorId));
      ref.invalidate(operatorCompletenessProvider(widget.operatorId));
      if (mounted) setState(() => _picked = null);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save({required bool advance}) async {
    final mandate = ref.read(operatorMandateProvider(widget.operatorId)).value;
    final requirements = await ref.read(operatorDocRequirementsProvider.future);
    final required = requirements.any((r) => r['doc_type'] == 'payment_mandate' && r['required'] == true);
    if (advance && required && (mandate == null || mandate['status'] == 'rejected')) {
      setState(() => _error = 'Upload the signed and stamped mandate to continue.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (advance) await ref.read(onboardingRepositoryProvider).markStep(widget.operatorId, 5);
      if (mounted) {
        if (!advance) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Progress saved. You can continue later.')));
        }
        widget.onSaved(advance: advance);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mandateAsync = ref.watch(operatorMandateProvider(widget.operatorId));
    final bankAsync = ref.watch(operatorBankProvider(widget.operatorId));
    final bankReady = (bankAsync.value?['account_number'] as String?) != null;
    final theme = Theme.of(context);
    final mandate = mandateAsync.value;
    final busy = _saving || _uploading;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Payment mandate', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'The mandate authorizes Thirty8 to pay your settlements to the bank account you entered.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How it works', style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  '1. View or download the pre-filled form.\n'
                  '2. Print and fill in the date and place.\n'
                  '3. Sign it and add your business stamp.\n'
                  '4. Scan or photograph it clearly and upload it below.\n'
                  '5. We verify it during review.',
                ),
                const SizedBox(height: AppSpacing.sm),
                if (!bankReady) ...[
                  const SizedBox(height: AppSpacing.sm),
                  const Text('Complete your bank details first so the form can be pre-filled.'),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    AppButton(
                      label: 'View / print form',
                      icon: Icons.picture_as_pdf_outlined,
                      size: AppButtonSize.small,
                      variant: AppButtonVariant.outline,
                      loading: _generating,
                      onPressed: (_generating || !bankReady) ? null : () => _generate(share: false),
                    ),
                    AppButton(
                      label: 'Download / share',
                      icon: Icons.download_outlined,
                      size: AppButtonSize.small,
                      variant: AppButtonVariant.outline,
                      onPressed: (_generating || !bankReady) ? null : () => _generate(share: true),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (mandateAsync.isLoading && mandate == null)
            const AppLoadingState()
          else
            DocumentUploadTile(
              label: 'Signed & stamped mandate',
              required: true,
              fileName: mandate?['file_name'] as String?,
              status: mandate?['status'] as String?,
              rejectionReason: mandate?['rejection_reason'] as String?,
              busy: _uploading,
              onPick: _pick,
            ),
          if (_picked != null) ...[
            const SizedBox(height: AppSpacing.sm),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.description_outlined, size: 18),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(child: Text(_picked!.name, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Icon(
                        _pickedProblem == null ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: _pickedProblem == null ? Colors.green : theme.colorScheme.error,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          _pickedProblem ?? 'File approved - ready to upload',
                          style: TextStyle(color: _pickedProblem == null ? Colors.green.shade700 : theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppButton(
                    label: 'Upload this file',
                    icon: Icons.cloud_upload_outlined,
                    size: AppButtonSize.small,
                    loading: _uploading,
                    onPressed: (_pickedProblem != null || busy) ? null : () => _upload(mandate),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: AppSpacing.md),
          AppButton(
            label: 'Save & continue',
            expand: true,
            loading: _saving,
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
    );
  }
}
