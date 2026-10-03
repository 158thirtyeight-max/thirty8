import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'fleet_providers.dart';
import 'stage_documents_screen.dart';

/// Live list of a bus's documents (Supabase Realtime). An admin rejecting a
/// document shows up here immediately, without the operator refreshing.
final busDocumentsLiveProvider = StreamProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, busId) {
  return ref.watch(supabaseProvider).from('bus_documents').stream(primaryKey: ['id']).eq('bus_id', busId);
});

/// Rejected documents of a bus with the admin's reason and a shortcut to the
/// documents screen so they can be replaced. Renders nothing when none are rejected.
class RejectedDocumentsBanner extends ConsumerWidget {
  const RejectedDocumentsBanner({super.key, required this.operatorId, required this.bus, this.onChanged});

  final String operatorId;
  final Map<String, dynamic> bus;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busId = bus['id'] as String;
    final rejected = (ref.watch(busDocumentsLiveProvider(busId)).value ?? const <Map<String, dynamic>>[])
        .where((d) => d['status'] == 'rejected')
        .toList();
    if (rejected.isEmpty) return const SizedBox.shrink();

    final labels = {
      for (final r in ref.watch(busDocRequirementsProvider).value ?? const <Map<String, dynamic>>[])
        r['doc_type'] as String: r['label'] as String,
    };
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: error.withValues(alpha: 0.08),
          border: Border.all(color: error.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.error_outline, size: 18, color: error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  rejected.length == 1 ? '1 document was rejected' : '${rejected.length} documents were rejected',
                  style: theme.textTheme.bodyMedium?.copyWith(color: error, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
            for (final d in rejected)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                    text: labels[d['doc_type']] ?? '${d['doc_type']}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (((d['rejection_reason'] as String?) ?? '').isNotEmpty) TextSpan(text: ' — ${d['rejection_reason']}'),
                ]), style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: AppSpacing.xs),
            AppButton(
              label: 'Replace documents',
              size: AppButtonSize.small,
              icon: Icons.upload_file,
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => StageDocumentsScreen(operatorId: operatorId, bus: bus)),
                );
                ref.invalidate(busDocumentsProvider(busId));
                ref.invalidate(busCompletenessProvider(busId));
                onChanged?.call();
              },
            ),
          ],
        ),
      ),
    );
  }
}
