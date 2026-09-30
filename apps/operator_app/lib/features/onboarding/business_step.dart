import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'constants.dart';
import 'onboarding_providers.dart';
import 'validators.dart';

/// Step 1 — business / operator information.
class BusinessStep extends ConsumerWidget {
  const BusinessStep({
    super.key,
    required this.operatorId,
    required this.operator,
    required this.onSaved,
  });

  final String? operatorId;
  final Map<String, dynamic>? operator;

  /// Called with the operator id after a successful save. [advance] is false
  /// for "Save & continue later".
  final void Function(String operatorId, {required bool advance}) onSaved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (operatorId == null) {
      return _BusinessForm(operatorId: null, operator: null, profile: const {}, onSaved: onSaved);
    }
    final profileAsync = ref.watch(operatorProfileProvider(operatorId!));
    return profileAsync.when(
      data: (profile) =>
          _BusinessForm(operatorId: operatorId, operator: operator, profile: profile, onSaved: onSaved),
      loading: () => const Center(child: AppLoadingState()),
      error: (e, _) => AppErrorState(
        message: 'Could not load your saved details.',
        onRetry: () => ref.invalidate(operatorProfileProvider(operatorId!)),
      ),
    );
  }
}

class _BusinessForm extends ConsumerStatefulWidget {
  const _BusinessForm({
    required this.operatorId,
    required this.operator,
    required this.profile,
    required this.onSaved,
  });

  final String? operatorId;
  final Map<String, dynamic>? operator;
  final Map<String, dynamic> profile;
  final void Function(String operatorId, {required bool advance}) onSaved;

  @override
  ConsumerState<_BusinessForm> createState() => _BusinessFormState();
}

class _BusinessFormState extends ConsumerState<_BusinessForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _legalName;
  late final TextEditingController _owner;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _contactAddress;
  late final TextEditingController _city;
  late final TextEditingController _district;
  late final TextEditingController _pin;

  late String _businessType;
  String? _entityType;
  String? _state;
  bool _sameAddress = false;
  String? _logoPath; // already-uploaded storage path
  String? _pickedLogoLocalPath; // chosen this session, uploaded on save
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final op = widget.operator ?? const <String, dynamic>{};
    final p = widget.profile;
    String s(Map<String, dynamic> m, String k) => (m[k] as String?) ?? '';

    _name = TextEditingController(text: s(op, 'name'));
    _legalName = TextEditingController(text: s(op, 'legal_name'));
    _phone = TextEditingController(text: s(op, 'contact_phone'));
    _email = TextEditingController(text: s(op, 'contact_email'));
    _owner = TextEditingController(text: s(p, 'owner_name'));
    _address = TextEditingController(text: s(p, 'address'));
    _contactAddress = TextEditingController(text: s(p, 'contact_address'));
    _city = TextEditingController(text: s(p, 'city'));
    _district = TextEditingController(text: s(p, 'district'));
    _pin = TextEditingController(text: s(p, 'pin_code'));
    _businessType = (op['business_type'] as String?) ?? 'bus';
    _entityType = businessEntityTypes.contains(p['business_type_detail']) ? p['business_type_detail'] as String : null;
    _state = indianStatesAndUts.contains(p['state']) ? p['state'] as String : null;
    _logoPath = p['logo_path'] as String?;
    _sameAddress = _contactAddress.text.isNotEmpty && _contactAddress.text == _address.text;
  }

  @override
  void dispose() {
    for (final c in [_name, _legalName, _owner, _phone, _email, _address, _contactAddress, _city, _district, _pin]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickLogo() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1024);
    if (picked != null) setState(() => _pickedLogoLocalPath = picked.path);
  }

  Future<void> _save({required bool advance}) async {
    // "Save & continue later" saves whatever is there; only the minimum needed
    // to create the operator is required. Advancing requires a valid form.
    if (advance) {
      if (!_formKey.currentState!.validate()) return;
    } else if (widget.operatorId == null && (_name.text.trim().isEmpty || _legalName.text.trim().isEmpty)) {
      setState(() => _error = 'Enter your business name and legal name before saving.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(onboardingRepositoryProvider);
    try {
      var logoPath = _logoPath;
      final contactAddress = _sameAddress ? _address.text.trim() : _contactAddress.text.trim();
      String? id = widget.operatorId;

      Map<String, dynamic> profile() => {
            'owner_name': _nullIfEmpty(_owner.text),
            'business_type_detail': _entityType,
            'address': _nullIfEmpty(_address.text),
            'contact_address': _nullIfEmpty(contactAddress),
            'city': _nullIfEmpty(_city.text),
            'district': _nullIfEmpty(_district.text),
            'state': _state,
            'pin_code': _nullIfEmpty(_pin.text),
            'logo_path': logoPath,
          };

      id = await repo.saveBusiness(
        operatorId: id,
        name: _name.text.trim(),
        legalName: _legalName.text.trim(),
        businessType: _businessType,
        email: _email.text.trim(),
        phone: Validators.normalizeMobile(_phone.text),
        profile: profile(),
      );

      if (_pickedLogoLocalPath != null) {
        logoPath = await repo.uploadLogo(operatorId: id, filePath: _pickedLogoLocalPath!);
        await repo.saveBusiness(
          operatorId: id,
          name: _name.text.trim(),
          legalName: _legalName.text.trim(),
          businessType: _businessType,
          email: _email.text.trim(),
          phone: Validators.normalizeMobile(_phone.text),
          profile: profile(),
        );
        _pickedLogoLocalPath = null;
        _logoPath = logoPath;
      }

      ref.invalidate(operatorProfileProvider(id));
      if (mounted) {
        if (!advance) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Progress saved. You can continue later.')),
          );
        }
        widget.onSaved(id, advance: advance);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save. Please check your details and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _nullIfEmpty(String v) => v.trim().isEmpty ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final busy = _saving;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Business information', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Tell us about your business. You can save and finish later; bus details come after approval.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'bus', label: Text('Bus')),
                ButtonSegment(value: 'cargo', label: Text('Cargo')),
                ButtonSegment(value: 'both', label: Text('Both')),
              ],
              selected: {_businessType},
              onSelectionChanged: busy ? null : (s) => setState(() => _businessType = s.first),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _name,
              label: 'Business / operator name',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'Business name'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _legalName,
              label: 'Legal business name',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'Legal business name'),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _entityType,
              decoration: const InputDecoration(labelText: 'Business type'),
              items: [for (final t in businessEntityTypes) DropdownMenuItem(value: t, child: Text(t))],
              onChanged: busy ? null : (v) => setState(() => _entityType = v),
              validator: (v) => v == null ? 'Select a business type' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _owner,
              label: 'Owner / authorized person name',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'Owner name'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _phone,
              label: 'Mobile number',
              keyboardType: TextInputType.phone,
              validator: Validators.mobile,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _email,
              label: 'Email address',
              keyboardType: TextInputType.emailAddress,
              validator: Validators.email,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _address,
              label: 'Business address',
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              validator: (v) => Validators.required(v, 'Business address'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Contact address is the same'),
              value: _sameAddress,
              onChanged: busy ? null : (v) => setState(() => _sameAddress = v ?? false),
            ),
            if (!_sameAddress) ...[
              AppTextField(
                controller: _contactAddress,
                label: 'Contact address (optional)',
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            AppTextField(
              controller: _city,
              label: 'City',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'City'),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _district,
              label: 'District',
              textCapitalization: TextCapitalization.words,
              validator: (v) => Validators.required(v, 'District'),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _state,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'State / UT'),
              items: [for (final s in indianStatesAndUts) DropdownMenuItem(value: s, child: Text(s))],
              onChanged: busy ? null : (v) => setState(() => _state = v),
              validator: (v) => v == null ? 'Select a state / UT' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _pin,
              label: 'PIN code',
              keyboardType: TextInputType.number,
              maxLength: 6,
              validator: Validators.pinCode,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _pickedLogoLocalPath != null
                        ? 'New logo selected'
                        : (_logoPath != null ? 'Logo uploaded' : 'Business logo (optional)'),
                  ),
                ),
                AppButton(
                  label: (_logoPath != null || _pickedLogoLocalPath != null) ? 'Change logo' : 'Add logo',
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.outline,
                  icon: Icons.image_outlined,
                  onPressed: busy ? null : _pickLogo,
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: AppSpacing.lg),
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
          ],
        ),
      ),
    );
  }
}
