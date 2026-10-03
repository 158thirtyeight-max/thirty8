import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/operator_providers.dart';
import '../../core/services/operator_services.dart';
import '../../core/supabase_providers.dart';
import '../onboarding/onboarding_flow_screen.dart';
import 'business_info_screens.dart';
import 'my_services_section.dart';

final operatorInsuranceProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('operator_insurance').select().eq('operator_id', operatorId).order('created_at', ascending: false);
});

class ProfileTab extends ConsumerWidget {
  const ProfileTab({super.key, required this.context});

  final OperatorContext context;

  Future<void> _addInsurance(BuildContext buildContext, WidgetRef ref) async {
    final providerController = TextEditingController();
    final policyController = TextEditingController();
    DateTime validFrom = DateTime.now();
    DateTime validUntil = DateTime.now().add(const Duration(days: 365));

    final proceed = await showDialog<bool>(
      context: buildContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Add insurance policy'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextField(controller: providerController, label: 'Insurance provider'),
                const SizedBox(height: 8),
                AppTextField(controller: policyController, label: 'Policy number'),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Valid from'),
                  subtitle: Text('${validFrom.year}-${validFrom.month}-${validFrom.day}'),
                  onTap: () async {
                    final picked = await showDatePicker(context: dialogContext, initialDate: validFrom, firstDate: DateTime(2020), lastDate: DateTime(2100));
                    if (picked != null) setDialogState(() => validFrom = picked);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Valid until'),
                  subtitle: Text('${validUntil.year}-${validUntil.month}-${validUntil.day}'),
                  onTap: () async {
                    final picked = await showDatePicker(context: dialogContext, initialDate: validUntil, firstDate: DateTime(2020), lastDate: DateTime(2100));
                    if (picked != null) setDialogState(() => validUntil = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Next: upload document')),
          ],
        ),
      ),
    );
    if (proceed != true || providerController.text.trim().isEmpty || policyController.text.trim().isEmpty) return;

    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80);
    String? documentUrl;
    if (picked != null) {
      final path = '${context.operatorId}/insurance_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await ref.read(supabaseProvider).storage.from('insurance-documents').upload(path, File(picked.path));
      documentUrl = path;
    }

    try {
      await ref.read(supabaseProvider).from('operator_insurance').insert({
        'operator_id': context.operatorId,
        'insurance_provider': providerController.text.trim(),
        'policy_number': policyController.text.trim(),
        'valid_from': validFrom.toIso8601String().split('T').first,
        'valid_until': validUntil.toIso8601String().split('T').first,
        'document_url': documentUrl,
        'status': 'pending',
      });
      ref.invalidate(operatorInsuranceProvider(context.operatorId));
    } catch (e) {
      if (buildContext.mounted) {
        ScaffoldMessenger.of(buildContext).showSnackBar(SnackBar(content: Text('Could not save policy: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final op = context.operator;
    final insuranceAsync = ref.watch(operatorInsuranceProvider(context.operatorId));
    final theme = Theme.of(buildContext);

    Widget sectionTitle(String text, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text(text, style: theme.textTheme.titleMedium), ?trailing],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(child: Text(op['name'] as String, style: theme.textTheme.titleLarge)),
                    AppBadge(status: context.applicationStatus),
                  ],
                ),
                if ((op['legal_name'] as String?)?.isNotEmpty ?? false)
                  Text(op['legal_name'] as String, style: theme.textTheme.bodySmall),
                const SizedBox(height: AppSpacing.sm),
                Text('Business type: ${businessTypeLabel(context.businessType)}'),
                Text('Phone: ${op['contact_phone'] ?? '—'}'),
                Text('Email: ${op['contact_email'] ?? '—'}'),
                Text('Your role: ${roleLabel(context.role)}'),
                if (context.isAdmin && context.isApplicationEditable) ...[
                  const SizedBox(height: AppSpacing.sm),
                  AppButton(
                    label: 'Edit Profile',
                    icon: Icons.edit_outlined,
                    size: AppButtonSize.small,
                    variant: AppButtonVariant.outline,
                    onPressed: () => Navigator.of(buildContext).push(
                      MaterialPageRoute<void>(builder: (_) => OnboardingFlowScreen(operatorContext: context)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          sectionTitle('My Services'),
          MyServicesSection(context: context),
          sectionTitle(
            'Insurance policies',
            trailing: IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => _addInsurance(buildContext, ref)),
          ),
          insuranceAsync.when(
            data: (policies) => policies.isEmpty
                ? const Padding(padding: EdgeInsets.all(8), child: Text('No insurance policies on file yet'))
                : Column(
                    children: policies
                        .map((p) => Padding(
                              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                              child: AppCard(
                                padding: EdgeInsets.zero,
                                child: AppListItem(
                                  leading: const Icon(Icons.shield_outlined),
                                  title: '${p['insurance_provider']} · ${p['policy_number']}',
                                  subtitle: '${p['valid_from']} → ${p['valid_until']}',
                                  trailing: AppBadge(status: p['status'] as String),
                                ),
                              ),
                            ))
                        .toList(),
                  ),
            loading: () => const Padding(padding: EdgeInsets.all(16), child: AppLoadingState()),
            error: (e, st) => AppErrorState(
              message: 'Could not load insurance policies.',
              onRetry: () => ref.invalidate(operatorInsuranceProvider(context.operatorId)),
            ),
          ),
          sectionTitle('Business'),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                AppListItem(
                  leading: const Icon(Icons.description_outlined),
                  title: 'Business documents',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(buildContext).push(
                    MaterialPageRoute<void>(builder: (_) => BusinessDocumentsScreen(context: context)),
                  ),
                ),
                AppListItem(
                  leading: const Icon(Icons.account_balance_outlined),
                  title: 'Payout details',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(buildContext).push(
                    MaterialPageRoute<void>(builder: (_) => PayoutDetailsScreen(context: context)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppButton(
            label: 'Sign out',
            variant: AppButtonVariant.outline,
            onPressed: () => ref.read(supabaseProvider).auth.signOut(),
          ),
        ],
      ),
    );
  }
}
