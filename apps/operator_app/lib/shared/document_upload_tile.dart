import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

/// One uploadable document row: label, required marker, verification status,
/// current file name, and an Upload / Replace action. Purely presentational —
/// the caller supplies [onPick] (and [onRemove] for optional documents).
class DocumentUploadTile extends StatelessWidget {
  const DocumentUploadTile({
    super.key,
    required this.label,
    required this.required,
    required this.onPick,
    this.fileName,
    this.status,
    this.rejectionReason,
    this.onRemove,
    this.busy = false,
    this.enabled = true,
  });

  final String label;
  final bool required;
  final String? fileName;

  /// pending | verified | rejected, or null when nothing is uploaded yet.
  final String? status;
  final String? rejectionReason;
  final VoidCallback onPick;
  final VoidCallback? onRemove;
  final bool busy;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final uploaded = fileName != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(required ? '$label *' : '$label (optional)', style: textTheme.titleSmall),
                ),
                if (status != null) AppBadge(status: status!),
              ],
            ),
            if (uploaded) ...[
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  const Icon(Icons.description_outlined, size: 18),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(child: Text(fileName!, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ],
            if (status == 'rejected' && rejectionReason != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Rejected: $rejectionReason',
                style: textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                AppButton(
                  label: uploaded ? 'Replace' : 'Upload',
                  icon: Icons.upload_file,
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.outline,
                  loading: busy,
                  onPressed: (busy || !enabled) ? null : onPick,
                ),
                if (uploaded && onRemove != null && enabled) ...[
                  const SizedBox(width: AppSpacing.sm),
                  AppButton(
                    label: 'Remove',
                    size: AppButtonSize.small,
                    variant: AppButtonVariant.ghost,
                    onPressed: busy ? null : onRemove,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
