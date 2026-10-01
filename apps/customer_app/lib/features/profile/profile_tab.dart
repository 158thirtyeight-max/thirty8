import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

class ProfileTab extends ConsumerWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 24),
          AppCard(
            child: AppListItem(
              leading: CircleAvatar(child: Text((user?.email ?? '?').substring(0, 1).toUpperCase())),
              title: user?.email ?? user?.phone ?? 'Signed in',
              subtitle: 'Customer account',
            ),
          ),
          const SizedBox(height: 24),
          AppListItem(
            leading: const Icon(Icons.people_outline),
            title: 'Saved passengers',
            onTap: () {},
          ),
          AppListItem(
            leading: const Icon(Icons.notifications_outlined),
            title: 'Notification preferences',
            onTap: () {},
          ),
          AppListItem(
            leading: const Icon(Icons.support_agent_outlined),
            title: 'Support',
            onTap: () {},
          ),
          const SizedBox(height: 24),
          AppButton(
            label: 'Log out',
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
            icon: Icons.logout,
            variant: AppButtonVariant.outline,
          ),
        ],
      ),
    );
  }
}
