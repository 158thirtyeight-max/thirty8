import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile_providers.dart';
import '../auth/complete_profile_screen.dart';
import 'home_shell.dart';

/// Sits behind the '/home' route: forces a stop at CompleteProfileScreen
/// until full_name + phone are on file (the gap left by Google sign-in),
/// then shows the real app. Kept out of go_router's redirect logic since
/// that check is async and go_router redirects must be synchronous.
class HomeGate extends ConsumerWidget {
  const HomeGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCompleteAsync = ref.watch(profileIsCompleteProvider);

    return isCompleteAsync.when(
      data: (isComplete) => isComplete ? const HomeShell() : const CompleteProfileScreen(),
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) => const HomeShell(),
    );
  }
}
