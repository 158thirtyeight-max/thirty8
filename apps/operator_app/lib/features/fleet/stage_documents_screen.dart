import 'package:design_system/design_system.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../onboarding/validators.dart';
import 'bus_validators.dart';
import 'fleet_providers.dart';

/// Stage B — vehicle documents. The list comes from the admin-configured
/// requirements that apply to this bus type; each document carries number,
/// issue/expiry dates, the file and its verification status. Renewing a
/// document resets it to pending (server-side).
class StageDocumentsScreen extends ConsumerWidget {
  const StageDocumentsScreen({super.key, required this.operatorId, required this.bus});

  final String operatorId;
  final Map<String, dynamic> bus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busId = bus['id'] as String;
    final reqsAsync = ref.watch(busDocRequirementsProvider);
    final docsAsync = ref.watch(busDocumentsProvider(busId));

    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle documents')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (reqsAsync.hasError || docsAsync.hasError) {
            return AppErrorState(
              message: 'Could not load documents.',
              onRetry: () {
                ref.invalidate(busDocRequirementsProvider);
                ref.invalidate(busDocumentsProvider(busId));
              },
            );
          }
          if (!reqsAsync.hasValue || !docsAsync.hasValue) return const AppLoadingState();

          final busType = bus['bus_type'] as String;
          final reqs = reqsAsync.requireValue
              .where((r) => busRequirementApplies((r['condition'] as Map?)?.cast<String, dynamic>(), busType))
              .toList();
          final docs = docsAsync.requireValue;

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Text('PDF, JPG or PNG, up to 10 MB each. Expiry dates are tracked; an expired document counts as missing.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AppSpacing.md),
              for (final r in reqs)
                _DocCard(
                  operatorId: operatorId,
                  busId: busId,
                  requirement: r,
                  docs: docs.where((d) => d['doc_type'] == r['doc_type']).toList(),
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _DocCard extends ConsumerWidget {
  const _DocCard({required this.operatorId, required this.busId, required this.requirement, required this.docs});

  final String operatorId;
  final String busId;
  final Map<String, dynamic> requirement;
  final List<Map<String, dynamic>> docs;

  Future<void> _open(BuildContext context, WidgetRef ref, Map<String, dynamic>? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DocSheet(
        operatorId: operatorId,
        busId: busId,
        requirement: requirement,
        existing: existing,
      ),
    );
    if (saved == true) {
      ref.invalidate(busDocumentsProvider(busId));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = requirement['label'] as String;
    final required = requirement['required'] == true;
    final multiple = requirement['doc_type'] == 'other_transport';
    final theme = Theme.of(context);

    Widget row(Map<String, dynamic> d) {
      final expiry = d['expiry_date'] == null ? null : DateTime.parse(d['expiry_date'] as String);
      final state = docExpiryState(expiry);
      final expiryText = switch (state) {
        DocExpiryState.expired => 'Expired',
        DocExpiryState.expiringSoon => 'Expiring soon',
        _ => null,
      };
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(d['file_name'] as String? ?? 'Uploaded', overflow: TextOverflow.ellipsis)),
                AppBadge(status: d['status'] as String),
              ],
            ),
            if ((d['doc_number'] as String?) != null) Text('No. ${d['doc_number']}', style: theme.textTheme.bodySmall),
            if (d['issue_date'] != null || d['expiry_date'] != null)
              Text('${d['issue_date'] ?? '—'} → ${d['expiry_date'] ?? '—'}', style: theme.textTheme.bodySmall),
            if (expiryText != null)
              Text(expiryText, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            if (d['status'] == 'rejected' && d['rejection_reason'] != null)
              Text('Rejected: ${d['rejection_reason']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: () => _open(context, ref, d), child: const Text('Renew / edit')),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(required ? '$label *' : '$label (optional)', style: theme.textTheme.titleSmall),
            if (docs.isEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              const Text('Not uploaded'),
            ],
            for (final d in docs) row(d),
            if (docs.isEmpty || multiple)
              Align(
                alignment: Alignment.centerLeft,
                child: AppButton(
                  label: 'Upload',
                  icon: Icons.upload_file,
                  size: AppButtonSize.small,
                  variant: AppButtonVariant.outline,
                  onPressed: () => _open(context, ref, null),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DocSheet extends ConsumerStatefulWidget {
  const _DocSheet({required this.operatorId, required this.busId, required this.requirement, required this.existing});

  final String operatorId;
  final String busId;
  final Map<String, dynamic> requirement;
  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_DocSheet> createState() => _DocSheetState();
}

class _DocSheetState extends ConsumerState<_DocSheet> {
  late final TextEditingController _number;
  DateTime? _issue;
  DateTime? _expiry;
  PlatformFile? _file;
  bool _saving = false;
  String? _error;

  bool get _hasExpiry => widget.requirement['has_expiry'] == true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _number = TextEditingController(text: (e?['doc_number'] as String?) ?? '');
    if (e?['issue_date'] != null) _issue = DateTime.parse(e!['issue_date'] as String);
    if (e?['expiry_date'] != null) _expiry = DateTime.parse(e!['expiry_date'] as String);
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool issue) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: (issue ? _issue : _expiry) ?? now,
      firstDate: DateTime(1990),
      lastDate: DateTime(now.year + 30),
    );
    if (picked != null) setState(() => issue ? _issue = picked : _expiry = picked);
  }

  Future<void> _pickFile() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: allowedDocumentExtensions);
    if (f != null) setState(() => _file = f);
  }

  Future<void> _save() async {
    final dateError = validateDocDates(issue: _issue, expiry: _expiry, expiryRequired: _hasExpiry);
    if (dateError != null) {
      setState(() => _error = dateError);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(fleetRepositoryProvider).saveBusDocument(
            operatorId: widget.operatorId,
            busId: widget.busId,
            docType: widget.requirement['doc_type'] as String,
            docNumber: _number.text,
            issueDate: _issue,
            expiryDate: _expiry,
            file: _file,
            existing: widget.existing,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd MMM yyyy');
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.requirement['label'] as String, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            AppTextField(controller: _number, label: 'Document number (if applicable)', textCapitalization: TextCapitalization.characters),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => _pickDate(true),
                    child: Text(_issue == null ? 'Issue date' : 'Issued ${fmt.format(_issue!)}'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => _pickDate(false),
                    child: Text(_expiry == null ? (_hasExpiry ? 'Expiry date *' : 'Expiry date') : 'Expires ${fmt.format(_expiry!)}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: _file != null ? _file!.name : (widget.existing != null ? 'Replace file (optional)' : 'Choose file'),
              icon: Icons.attach_file,
              variant: AppButtonVariant.outline,
              onPressed: _saving ? null : _pickFile,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: AppSpacing.md),
            AppButton(label: 'Save', expand: true, loading: _saving, onPressed: _saving ? null : _save),
            AppButton(label: 'Cancel', variant: AppButtonVariant.ghost, expand: true, onPressed: _saving ? null : () => Navigator.of(context).pop(false)),
          ],
        ),
      ),
    );
  }
}
