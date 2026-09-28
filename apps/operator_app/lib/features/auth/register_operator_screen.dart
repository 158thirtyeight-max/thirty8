import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';

/// Shown to a logged-in user with no operator_admin/staff role yet. Calls
/// register_operator() which creates the operators row (status='pending')
/// and grants the caller 'operator_admin' for it in a single transaction.
class RegisterOperatorScreen extends ConsumerStatefulWidget {
  const RegisterOperatorScreen({super.key});

  @override
  ConsumerState<RegisterOperatorScreen> createState() => _RegisterOperatorScreenState();
}

class _RegisterOperatorScreenState extends ConsumerState<RegisterOperatorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _legalNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  String _businessType = 'bus';
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _legalNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(supabaseProvider).rpc('register_operator', params: {
        'p_name': _nameController.text.trim(),
        'p_legal_name': _legalNameController.text.trim(),
        'p_business_type': _businessType,
        'p_contact_email': _emailController.text.trim(),
        'p_contact_phone': _phoneController.text.trim(),
      });
      ref.invalidate(operatorContextProvider);
    } catch (e) {
      setState(() => _error = 'Could not register operator. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Register your business')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Tell us about your business — a platform admin will review and approve it before you can start scheduling trips or accepting shipments.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'bus', label: Text('Bus')),
                    ButtonSegment(value: 'cargo', label: Text('Cargo')),
                    ButtonSegment(value: 'both', label: Text('Both')),
                  ],
                  selected: {_businessType},
                  onSelectionChanged: (s) => setState(() => _businessType = s.first),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Business name'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _legalNameController,
                  decoration: const InputDecoration(labelText: 'Legal / registered name'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Contact email'),
                  validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Contact phone'),
                  validator: (v) => (v == null || v.trim().length < 8) ? 'Enter a valid phone number' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _loading ? null : _register,
                  child: _loading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Submit for review'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
