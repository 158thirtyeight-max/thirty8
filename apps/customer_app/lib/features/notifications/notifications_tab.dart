import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';

class NotificationsTab extends ConsumerStatefulWidget {
  const NotificationsTab({super.key});

  @override
  ConsumerState<NotificationsTab> createState() => _NotificationsTabState();
}

class _NotificationsTabState extends ConsumerState<NotificationsTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = ref.read(currentUserProvider)?.id;
    if (userId == null) return;
    final res = await ref
        .read(supabaseProvider)
        .from('notifications')
        .select()
        .eq('profile_id', userId)
        .order('created_at', ascending: false)
        .limit(50);
    if (!mounted) return;
    setState(() {
      _items = List<Map<String, dynamic>>.from(res as List);
      _loading = false;
    });
  }

  Future<void> _markRead(String id) async {
    await ref.read(supabaseProvider).from('notifications').update({'is_read': true}).eq('id', id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: _items.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Icon(Icons.notifications_off_outlined, size: 48, color: Colors.grey),
                  SizedBox(height: 12),
                  Center(child: Text('No notifications yet')),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.all(8),
                itemCount: _items.length,
                separatorBuilder: (a, b) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final n = _items[index];
                  final isRead = n['is_read'] as bool? ?? false;
                  return ListTile(
                    leading: Icon(
                      isRead ? Icons.notifications_none : Icons.notifications,
                      color: isRead ? Colors.grey : Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(n['title'] as String? ?? '', style: TextStyle(fontWeight: isRead ? FontWeight.normal : FontWeight.bold)),
                    subtitle: Text(n['body'] as String? ?? ''),
                    trailing: Text(DateFormat('d MMM').format(DateTime.parse(n['created_at'] as String))),
                    onTap: () => _markRead(n['id'] as String),
                  );
                },
              ),
      ),
    );
  }
}
