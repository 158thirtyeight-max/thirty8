import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

/// The operator's own notifications (payout profile, earnings, settlement and ticket events written by the backend).
/// Read-only apart from marking them read; the text never contains amounts or bank details by design.
@immutable
class OperatorNotification {
  const OperatorNotification({required this.id, required this.title, required this.body, required this.type, required this.isRead, required this.createdAt});

  final String id;
  final String title;
  final String? body;
  final String? type;
  final bool isRead;
  final DateTime createdAt;

  /// Where this kind of notification belongs, for the icon.
  IconData get icon {
    final t = type ?? '';
    if (t.startsWith('operator_payout') || t.startsWith('operator_settlement')) return Icons.account_balance_outlined;
    if (t.startsWith('operator_payment_profile')) return Icons.verified_user_outlined;
    if (t.startsWith('operator_ticket')) return Icons.confirmation_number_outlined;
    if (t.startsWith('operator_earning')) return Icons.trending_up;
    return Icons.notifications_none;
  }

  factory OperatorNotification.fromJson(Map<String, dynamic> j) => OperatorNotification(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        body: j['body'] as String?,
        type: j['type'] as String?,
        isRead: j['is_read'] == true,
        createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      );
}

final operatorNotificationsProvider = FutureProvider.autoDispose<List<OperatorNotification>>((ref) async {
  final userId = ref.watch(currentUserProvider)?.id;
  if (userId == null) return const [];
  final rows = await ref
      .read(supabaseProvider)
      .from('notifications')
      .select('id, title, body, type, is_read, created_at')
      .eq('profile_id', userId)
      .order('created_at', ascending: false)
      .limit(100);
  return [for (final r in (rows as List)) OperatorNotification.fromJson(Map<String, dynamic>.from(r as Map))];
});

int unreadCount(List<OperatorNotification> items) => items.where((n) => !n.isRead).length;

/// Bell with an unread badge, for an AppBar.
class NotificationsBell extends ConsumerWidget {
  const NotificationsBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(operatorNotificationsProvider).maybeWhen(data: unreadCount, orElse: () => 0);
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NotificationsScreen())),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > 9 ? '9+' : '$unread'),
        child: const Icon(Icons.notifications_none),
      ),
    );
  }
}

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  static final _fmt = DateFormat('d MMM, h:mm a');

  Future<void> _markRead(WidgetRef ref, OperatorNotification n) async {
    if (n.isRead) return;
    try {
      await ref.read(supabaseProvider).from('notifications').update({'is_read': true}).eq('id', n.id);
      ref.invalidate(operatorNotificationsProvider);
    } catch (_) {}
  }

  Future<void> _markAllRead(WidgetRef ref) async {
    final userId = ref.read(currentUserProvider)?.id;
    if (userId == null) return;
    try {
      await ref.read(supabaseProvider).from('notifications').update({'is_read': true}).eq('profile_id', userId).eq('is_read', false);
      ref.invalidate(operatorNotificationsProvider);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(operatorNotificationsProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (async.maybeWhen(data: (l) => unreadCount(l) > 0, orElse: () => false)) TextButton(onPressed: () => _markAllRead(ref), child: const Text('Mark all read')),
        ],
      ),
      body: async.when(
        loading: () => const AppLoadingState(),
        error: (e, _) => AppErrorState(message: 'Could not load notifications.', onRetry: () => ref.invalidate(operatorNotificationsProvider)),
        data: (items) => items.isEmpty
            ? const AppEmptyState(icon: Icons.notifications_none, message: 'No notifications yet. Payout and earnings updates will appear here.')
            : RefreshIndicator(
                onRefresh: () async => ref.refresh(operatorNotificationsProvider.future),
                child: ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, i) {
                    final n = items[i];
                    return AppCard(
                      onTap: () => _markRead(ref, n),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(n.icon, color: n.isRead ? AppColors.textTertiary : AppColors.primary),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(n.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700)),
                            if (n.body != null) Text(n.body!, style: theme.textTheme.bodySmall),
                            const SizedBox(height: 2),
                            Text(_fmt.format(n.createdAt), style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textTertiary, fontSize: 11)),
                          ]),
                        ),
                        if (!n.isRead) const Padding(padding: EdgeInsets.only(left: 6, top: 4), child: CircleAvatar(radius: 4, backgroundColor: AppColors.primary)),
                      ]),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
