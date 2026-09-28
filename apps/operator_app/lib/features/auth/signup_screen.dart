import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';
import 'otp_verification_screen.dart';

/// Email/password signup for operator staff. `data: {'app': 'operator'}`
/// is metadata only — it does NOT grant any role (see
/// private.handle_new_user()). The operator_admin role is granted by
/// register_operator() on the next screen, or by an existing operator_admin
/// inviting this user as staff (not yet built). full_name/phone are read by
/// the same trigger to populate the profile row.
///
/// Email confirmation is OTP-based, not link-based: after signUp() the user
/// is sent to OtpVerificationScreen to enter the 6-digit code from their
/// inbox (requires the "Confirm signup" email template in the Supabase
/// dashboard to be customized to show {{ .Token }}).
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final email = _emailController.text.trim();
    try {
      final res = await ref.read(supabaseProvider).auth.signUp(
            email: email,
            password: _passwordController.text,
            data: {
              'app': 'operator',
              'full_name': _nameController.text.trim(),
              'phone': _phoneController.text.trim(),
            },
          );
      if (!mounted) return;
      if (res.session == null) {
        // Email confirmation required — collect the OTP instead of a link.
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => OtpVerificationScreen(email: email)));
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 24),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Your full name'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                  validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                  validator: (v) => (v == null || v.trim().length < 8) ? 'Enter a valid phone number' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                  validator: (v) => (v == null || v.length < 6) ? 'Password must be at least 6 characters' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                AppButton(
                  label: 'Sign up',
                  onPressed: _loading ? null : _signup,
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
