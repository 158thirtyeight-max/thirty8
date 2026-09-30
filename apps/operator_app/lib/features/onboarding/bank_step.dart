import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'onboarding_providers.dart';
import 'requirement_documents.dart';
import 'validators.dart';

const _accountTypes = {
  'savings': 'Savings',
  'current': 'Current',
  'other': 'Other',
};

/// Step 3 — bank & payout information.
class BankStep extends ConsumerWidget {
  const BankStep({
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
  Widget build(BuildContext context, WidgetRef ref) {
    final bankAsync = ref.watch(operatorBankProvider(operatorId));
    return bankAsync.when(
      data: (bank) => _BankForm(
        operatorId: operatorId,
        operator: operator,
        bank: bank,
        onBack: onBack,
        onSaved: onSaved,
      ),
      loading: () => const Center(child: AppLoadingState()),
      error: (e, _) => AppErrorState(
        message: 'Could not load your saved details.',
        onRetry: () => ref.invalidate(operatorBankProvider(operatorId)),
      ),
    );
  }
}

class _BankForm extends ConsumerStatefulWidget {
  const _BankForm({
    required this.operatorId,
    required this.operator,
    required this.bank,
    required this.onBack,
    required this.onSaved,
  });

  final String operatorId;
  final Map<String, dynamic> operator;
  final Map<String, dynamic> bank;
  final VoidCallback onBack;
  final void Function({required bool advance}) onSaved;

  @override
  ConsumerState<_BankForm> createState() => _BankFormState();
}

class _BankFormState extends ConsumerState<_BankForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _holder;
  late final TextEditingController _bank;
  late final TextEditingController _branch;
  late final TextEditingController _bankAddress;
  late final TextEditingController _account;
  late final TextEditingController _confirmAccount;
  late final TextEditingController _ifsc;
  late final TextEditingController _micr;
  String? _accountType;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final b = widget.bank;
    String s(String k) => (b[k] as String?) ?? '';
    _holder = TextEditingController(
      text: s('account_holder_name').isNotEmpty
          ? s('account_holder_name')
          : ((widget.operator['legal_name'] as String?) ?? ''),
    );
    _bank = TextEditingController(text: s('bank_name'));
    _branch = TextEditingController(text: s('branch_name'));
    _bankAddress = TextEditingController(text: s('bank_address'));
    _account = TextEditingController(text: s('account_number'));
    // A previously saved number was already confirmed, so it is prefilled.
    _confirmAccount = TextEditingController(text: s('account_number'));
    _ifsc = TextEditingController(text: s('ifsc'));
    _micr = TextEditingController(text: s('micr'));
    _accountType = _accountTypes.containsKey(b['account_type']) ? b['account_type'] as String : null;
  }

  @override
  void dispose() {
    for (final c in [_holder, _bank, _branch, _bankAddress, _account, _confirmAccount, _ifsc, _micr]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({required bool advance}) async {
    if (advance) {
      if (!_formKey.currentState!.validate()) return;
    } else {
      // Saving for later tolerates blanks, but never malformed values.
      final bad = (_account.text.trim().isNotEmpty ? Validators.accountNumber(_account.text) : null) ??
          (_account.text.trim().isNotEmpty ? Validators.confirmAccountNumber(_confirmAccount.text, _account.text) : null) ??
          (_ifsc.text.trim().isNotEmpty ? Validators.ifsc(_ifsc.text) : null) ??
          Validators.micr(_micr.text);
      if (bad != null) {
        setState(() => _error = bad);
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(onboardingRepositoryProvider);
    try {
      await repo.saveBank(
        operatorId: widget.operatorId,
        holder: _holder.text,
        bankName: _bank.text,
        branch: _branch.text,
        bankAddress: _bankAddress.text,
        accountNumber: _account.text,
        ifsc: _ifsc.text,
        micr: _micr.text,
        accountType: _accountType,
      );
      if (advance) await repo.markStep(widget.operatorId, 4);
      ref.invalidate(operatorBankProvider(widget.operatorId));
      ref.invalidate(operatorCompletenessProvider(widget.operatorId));
      if (mounted) {
        if (!advance) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Progress saved. You can continue later.')));
        }
        widget.onSaved(advance: advance);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save. Please check your details and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving;
    final gst = ref.watch(operatorKycProvider(widget.operatorId)).value?['gst_registered'] as bool?;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Bank & payout', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Settlements are paid to this account. The account holder name should match your legal business name.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _holder,
              label: 'Account holder name',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'Account holder name'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _bank,
              label: 'Bank name',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'Bank name'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _branch,
              label: 'Branch name',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'Branch name'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _bankAddress,
              label: 'Bank address (optional)',
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _account,
              label: 'Account number',
              keyboardType: TextInputType.number,
              maxLength: 18,
              validator: Validators.accountNumber,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _confirmAccount,
              label: 'Confirm account number',
              keyboardType: TextInputType.number,
              maxLength: 18,
              validator: (v) => Validators.confirmAccountNumber(v, _account.text),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _ifsc,
              label: 'IFSC',
              textCapitalization: TextCapitalization.characters,
              maxLength: 11,
              validator: Validators.ifsc,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _micr,
              label: 'MICR (optional)',
              keyboardType: TextInputType.number,
              maxLength: 9,
              validator: Validators.micr,
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _accountType,
              decoration: const InputDecoration(labelText: 'Account type'),
              items: [
                for (final e in _accountTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: busy ? null : (v) => setState(() => _accountType = v),
              validator: (v) => v == null ? 'Select an account type' : null,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Bank documents', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text('PDF, JPG or PNG, up to 10 MB each.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.sm),
            RequirementDocuments(
              operatorId: widget.operatorId,
              businessType: (widget.operator['business_type'] as String?) ?? 'bus',
              gstRegistered: gst,
              step: 'bank',
              onError: (m) => setState(() => _error = m),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
