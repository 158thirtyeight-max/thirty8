import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile_providers.dart';
import '../../core/supabase_providers.dart';

/// Google sign-in never gives us a phone number, and may not always give a
/// name either — this screen is the gate's forced stop (see
/// core/router.dart / GateScreen) until both are on file, since email +
/// phone + name are required contact details for the operator record.
class CompleteProfileScreen extends ConsumerStatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  ConsumerState<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends ConsumerState<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _loading = false;
  bool _prefilled = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _prefill(Map<String, dynamic>? profile) {
    if (_prefilled || profile == null) return;
    _prefilled = true;
    _nameController.text = (profile['full_name'] as String?) ?? '';
    _phoneController.text = (profile['phone'] as String?) ?? '';
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = ref.read(currentUserProvider);
      await ref.read(supabaseProvider).from('profiles').update({
        'full_name': _nameController.text.trim(),
        'phone': _phoneController.text.trim(),
      }).eq('id', user!.id);
      ref.invalidate(myProfileProvider);
      ref.invalidate(profileIsCompleteProvider);
      // Gate redirect (see GateScreen) takes over once the profile is complete.
    } catch (e) {
      setState(() => _error = 'Could not save your details. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(myProfileProvider);
    profileAsync.whenData(_prefill);

    return Scaffold(
      appBar: AppBar(title: const Text('Complete your profile'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "We need your name and phone number before you can register or manage a business.",
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                  validator: (v) => (v == null || v.trim().length < 8) ? 'Enter a valid phone number' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                AppButton(
                  label: 'Continue',
                  onPressed: _loading ? null : _save,
                  loading: _loading,
                  expand: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
