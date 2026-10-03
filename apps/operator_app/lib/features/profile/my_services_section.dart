import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/services/operator_services.dart';
import '../onboarding/onboarding_flow_screen.dart';

/// Profile → My Services. Selecting a service never implies approval: the
/// state badge shows what the backend decided (setup required, pending
/// approval, active, ...). Disabling keeps all records and warns about open work.
class MyServicesSection extends ConsumerStatefulWidget {
  const MyServicesSection({super.key, required this.context});

  final OperatorContext context;

  @override
  ConsumerState<MyServicesSection> createState() => _MyServicesSectionState();
}

class _MyServicesSectionState extends ConsumerState<MyServicesSection> {
  ServiceType? _busy;

  OperatorContext get _ctx => widget.context;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  String _errorMessage(Object e) {
    final text = e.toString();
    if (text.contains('service_suspended')) return 'This service was suspended by thirty8 and cannot be re-enabled.';
    if (text.contains('service_unavailable')) return 'This service is not available yet.';
    if (text.contains('Only the operator admin')) return 'Only the account owner can change services.';
    return 'Could not update the service. Please try again.';
  }

  Future<void> _toggle(ServiceDefinition def, bool enable) async {
    setState(() => _busy = def.type);
    try {
      var result = await setOperatorService(ref, _ctx, def.type, enable);
      if (result.needsConfirmation) {
        if (!mounted) return;
        final confirmed = await _confirmDisable(def, result.impact!);
        if (confirmed != true) return;
        result = await setOperatorService(ref, _ctx, def.type, false, confirm: true);
      }
      if (result.ok) {
        _snack(enable
            ? '${def.name}: ${result.state?.label ?? 'updated'}'
            : '${def.name} disabled. Your records and earnings history are kept.');
      }
    } catch (e) {
      _snack(_errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<bool?> _confirmDisable(ServiceDefinition def, Map<String, dynamic> impact) {
    final lines = describeDisableImpact(impact);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Disable ${def.name}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('You still have open work for this service:'),
            const SizedBox(height: 8),
            for (final l in lines) Text('• $l'),
            const SizedBox(height: 12),
            const Text(
              'Disabling does not cancel any booking or delete any record. You will not be able to add new '
              'vehicles or trips until you enable it again.',
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep enabled')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Disable anyway')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final servicesAsync = ref.watch(operatorServicesProvider(_ctx.operatorId));
    return servicesAsync.when(
      loading: () => const Padding(padding: EdgeInsets.all(16), child: AppLoadingState()),
      error: (e, _) => AppErrorState(
        message: 'Could not load your services.',
        onRetry: () => ref.invalidate(operatorServicesProvider(_ctx.operatorId)),
      ),
      data: (services) => Column(
        children: [
          for (final def in serviceDefinitions)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _ServiceTile(
                definition: def,
                service: services[def.type],
                canEdit: _ctx.isAdmin,
                busy: _busy == def.type,
                onToggle: (v) => _toggle(def, v),
                onSetup: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => OnboardingFlowScreen(operatorContext: _ctx)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.definition,
    required this.service,
    required this.canEdit,
    required this.busy,
    required this.onToggle,
    required this.onSetup,
  });

  final ServiceDefinition definition;
  final OperatorService? service;
  final bool canEdit;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = service?.state ?? ServiceState.notSelected;
    final selected = state.isSelected;
    final adminSuspended = service?.suspendedByAdmin ?? false;
    final toggleEnabled = definition.available && canEdit && !busy && !adminSuspended;

    String? note;
    if (!definition.available) {
      note = 'Coming soon';
    } else if (adminSuspended) {
      note = service?.suspensionReason?.isNotEmpty == true
          ? 'Suspended by thirty8: ${service!.suspensionReason}'
          : 'Suspended by thirty8. Contact support.';
    } else if (state == ServiceState.pendingApproval) {
      note = 'Waiting for approval. You can start operating once it is approved.';
    } else if (state == ServiceState.setupRequired) {
      note = 'Finish your business setup to start operating.';
    } else if (!canEdit) {
      note = 'Only the account owner can change services.';
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(definition.icon, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(definition.name, style: theme.textTheme.titleMedium)),
              if (definition.available) AppBadge(status: state.key) else const AppBadge(status: 'coming soon'),
              const SizedBox(width: AppSpacing.sm),
              busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : Switch(value: selected, onChanged: toggleEnabled ? onToggle : null),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(definition.description, style: theme.textTheme.bodySmall),
          if (note != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(note, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
          ],
          if (state == ServiceState.setupRequired && canEdit) ...[
            const SizedBox(height: AppSpacing.sm),
            AppButton(label: 'Complete setup', size: AppButtonSize.small, variant: AppButtonVariant.outline, onPressed: onSetup),
          ],
        ],
      ),
    );
  }
}
