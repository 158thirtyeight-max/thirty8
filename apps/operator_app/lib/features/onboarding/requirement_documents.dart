import 'package:design_system/design_system.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/document_upload_tile.dart';
import 'onboarding_providers.dart';
import 'validators.dart';

/// Lists the admin-configured document requirements for one onboarding step
/// (`kyc` or `bank`) that apply to this operator, with upload / replace /
/// remove. Owns its own upload state; reports problems through [onError].
class RequirementDocuments extends ConsumerStatefulWidget {
  const RequirementDocuments({
    super.key,
    required this.operatorId,
    required this.businessType,
    required this.gstRegistered,
    required this.step,
    required this.onError,
  });

  final String operatorId;
  final String businessType;
  final bool? gstRegistered;
  final String step;
  final void Function(String? message) onError;

  @override
  ConsumerState<RequirementDocuments> createState() => _RequirementDocumentsState();
}

class _RequirementDocumentsState extends ConsumerState<RequirementDocuments> {
  String? _busyKey;

  void _refresh() {
    ref.invalidate(operatorDocumentsProvider(widget.operatorId));
    ref.invalidate(operatorCompletenessProvider(widget.operatorId));
  }

  Future<void> _pick(String docType, {Map<String, dynamic>? existing}) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedDocumentExtensions,
    );
    if (file == null) return;

    setState(() => _busyKey = existing?['id'] as String? ?? docType);
    widget.onError(null);
    try {
      await ref.read(onboardingRepositoryProvider).uploadDocument(
            operatorId: widget.operatorId,
            docType: docType,
            file: file,
            existingDocId: existing?['id'] as String?,
            existingPath: existing?['file_path'] as String?,
          );
      _refresh();
    } catch (e) {
      widget.onError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _remove(Map<String, dynamic> doc) async {
    setState(() => _busyKey = doc['id'] as String);
    try {
      await ref
          .read(onboardingRepositoryProvider)
          .deleteDocument(docId: doc['id'] as String, path: doc['file_path'] as String);
      _refresh();
    } catch (e) {
      widget.onError('Could not remove the document.');
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reqsAsync = ref.watch(operatorDocRequirementsProvider);
    final docs = ref.watch(operatorDocumentsProvider(widget.operatorId)).value ??
        const <Map<String, dynamic>>[];

    if (reqsAsync.hasError) {
      return const Text('Could not load the document list. Please try again later.');
    }
    final requirements = (reqsAsync.value ?? const <Map<String, dynamic>>[])
        .where((r) => ((r['step'] as String?) ?? 'kyc') == widget.step)
        .where((r) => requirementApplies(
              (r['condition'] as Map?)?.cast<String, dynamic>(),
              businessType: widget.businessType,
              gstRegistered: widget.gstRegistered,
            ))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final r in requirements) ..._tilesFor(r, docs),
        if (reqsAsync.isLoading) const Padding(padding: EdgeInsets.all(AppSpacing.md), child: AppLoadingState()),
      ],
    );
  }

  List<Widget> _tilesFor(Map<String, dynamic> req, List<Map<String, dynamic>> docs) {
    final type = req['doc_type'] as String;
    final label = req['label'] as String;
    final required = req['required'] as bool;
    final mine = docs.where((d) => d['doc_type'] == type).toList();

    if (type == 'other_registration') {
      return [
        for (final d in mine)
          DocumentUploadTile(
            label: label,
            required: false,
            fileName: d['file_name'] as String?,
            status: d['status'] as String?,
            rejectionReason: d['rejection_reason'] as String?,
            busy: _busyKey == d['id'],
            onPick: () => _pick(type, existing: d),
            onRemove: () => _remove(d),
          ),
        DocumentUploadTile(
          label: label,
          required: false,
          busy: _busyKey == type,
          onPick: () => _pick(type),
        ),
      ];
    }

    final d = mine.isEmpty ? null : mine.first;
    return [
      DocumentUploadTile(
        label: label,
        required: required,
        fileName: d?['file_name'] as String?,
        status: d?['status'] as String?,
        rejectionReason: d?['rejection_reason'] as String?,
        busy: _busyKey == (d?['id'] ?? type),
        onPick: () => _pick(type, existing: d),
        onRemove: (!required && d != null) ? () => _remove(d) : null,
      ),
    ];
  }
}
