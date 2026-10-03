import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/operator_providers.dart';
import '../../core/services/operator_services.dart';
import '../bus_ops/bus_module_screen.dart';
import '../cargo_ops/cargo_ops_tab.dart';

/// Central working area. Shows ONLY the services the operator selected in
/// Profile → My Services, and only lets approved/active ones be opened.
class OperationsScreen extends ConsumerWidget {
  const OperationsScreen({super.key, required this.context, required this.onChooseServices});

  final OperatorContext context;

  /// Switches the shell to Profile (My Services).
  final VoidCallback onChooseServices;

  void _open(BuildContext buildContext, ServiceDefinition def) {
    final Widget screen = switch (def.type) {
      ServiceType.bus => BusModuleScreen(context: context),
      ServiceType.cargo => CargoOpsTab(context: context),
      ServiceType.shopping => const SizedBox.shrink(),
    };
    Navigator.of(buildContext).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final servicesAsync = ref.watch(operatorServicesProvider(context.operatorId));

    return Scaffold(
      appBar: AppBar(title: const Text('Operations')),
      body: servicesAsync.when(
        loading: () => const Center(child: AppLoadingState()),
        error: (e, _) => Center(
          child: AppErrorState(
            message: 'Could not load your services.',
            onRetry: () => ref.invalidate(operatorServicesProvider(context.operatorId)),
          ),
        ),
        data: (services) {
          final visible = visibleServices(services);
          if (visible.isEmpty) {
            return Center(
              child: AppEmptyState(
                icon: Icons.business_center_outlined,
                message: 'No services selected yet.',
                action: AppButton(label: 'Choose Services', onPressed: onChooseServices),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => ref.refresh(operatorServicesProvider(context.operatorId).future),
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                for (final def in visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: ServiceCard(
                      definition: def,
                      service: services[def.type]!,
                      onOpen: () => _open(buildContext, def),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Reusable service tile used by Operations (and mirrored in My Services).
class ServiceCard extends StatelessWidget {
  const ServiceCard({super.key, required this.definition, required this.service, required this.onOpen});

  final ServiceDefinition definition;
  final OperatorService service;
  final VoidCallback onOpen;

  String? get _blockedMessage => switch (service.state) {
        ServiceState.setupRequired => 'Finish your business setup to start using ${definition.name}.',
        ServiceState.pendingApproval => '${definition.name} is awaiting approval. You will be able to operate once it is approved.',
        ServiceState.suspended => service.suspensionReason?.isNotEmpty == true
            ? '${definition.name} is suspended: ${service.suspensionReason}'
            : '${definition.name} is suspended. Contact support.',
        ServiceState.selected => '${definition.name} setup is in progress.',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocked = _blockedMessage;
    final operational = service.state.isOperational;
    return AppCard(
      onTap: operational ? onOpen : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(definition.icon, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(definition.name, style: theme.textTheme.titleMedium)),
              AppBadge(status: service.state.key),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(definition.description, style: theme.textTheme.bodySmall),
          if (blocked != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(blocked, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning)),
          ],
          if (operational) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: AppButton(label: 'Open ${definition.name}', size: AppButtonSize.small, onPressed: onOpen),
            ),
          ],
        ],
      ),
    );
  }
}
