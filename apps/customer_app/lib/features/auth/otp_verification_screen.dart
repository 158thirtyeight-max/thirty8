import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';

/// Enter the 6-digit code emailed by Supabase to confirm the account —
/// no need to leave the app for a link. Requires the "Confirm signup"
/// template in the Supabase dashboard to print {{ .Token }}.
class OtpVerificationScreen extends ConsumerStatefulWidget {
  const OtpVerificationScreen({super.key, required this.email});

  final String email;

  @override
  ConsumerState<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen> {
  final _codeController = TextEditingController();
  bool _verifying = false;
  bool _resending = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'Enter the 6-digit code');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(supabaseProvider).auth.verifyOTP(
            type: OtpType.signup,
            email: widget.email,
            token: code,
          );
      // Router redirect (see core/router.dart) takes over once the session exists.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not verify that code. Please try again.');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _resending = true;
      _error = null;
      _info = null;
    });
    try {
      await ref.read(supabaseProvider).auth.resend(type: OtpType.signup, email: widget.email);
      setState(() => _info = 'A new code has been sent to ${widget.email}');
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not resend the code. Please try again.');
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your email')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.lg),
              const Icon(Icons.mark_email_read_outlined, size: 64, color: AppColors.primary),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Enter the 6-digit code we sent to ${widget.email}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                hint: '000000',
                maxLength: 6,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(letterSpacing: 8),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_error!, style: AppTypography.body(AppColors.error)),
              ],
              if (_info != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_info!, style: AppTypography.body(AppColors.primary)),
              ],
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: 'Verify',
                onPressed: _verifying ? null : _verify,
                loading: _verifying,
                expand: true,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: _resending ? null : _resend,
                child: Text(_resending ? 'Sending…' : "Didn't get a code? Resend"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
