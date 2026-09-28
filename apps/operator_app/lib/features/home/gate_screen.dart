import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/profile_providers.dart';
import '../auth/complete_profile_screen.dart';
import '../auth/pending_approval_screen.dart';
import '../auth/register_operator_screen.dart';
import 'home_shell.dart';

/// Single post-login gate: first forces a stop at CompleteProfileScreen if
/// phone/name is missing (the gap left by Google sign-in), then resolves the
/// user's operator context — register (no operator yet), pending (not
/// approved yet), or the home shell. Kept out of go_router's redirect logic
/// since this state is async and go_router redirects must be synchronous.
class GateScreen extends ConsumerWidget {
  const GateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCompleteAsync = ref.watch(profileIsCompleteProvider);

    return isCompleteAsync.when(
      data: (isComplete) {
        if (!isComplete) return const CompleteProfileScreen();
        return const _OperatorGate();
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) => const _OperatorGate(),
    );
  }
}

class _OperatorGate extends ConsumerWidget {
  const _OperatorGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contextAsync = ref.watch(operatorContextProvider);

    return contextAsync.when(
      data: (operatorContext) {
        if (operatorContext == null) return const RegisterOperatorScreen();
        if (!operatorContext.isApproved) return const PendingApprovalScreen();
        return HomeShell(context: operatorContext);
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) => Scaffold(body: Center(child: Text('Something went wrong: $e'))),
    );
  }
}
