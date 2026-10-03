import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/operator_providers.dart';
import '../../core/supabase_providers.dart';
import 'tracking_models.dart';

/// Operations → Bus → Manage Bus → GPS Tracking.
/// Prepares a tracker for this bus. A tracker only becomes "Connected" after thirty8 activates it
/// with a provider AND it actually delivers a location — this screen never claims otherwise.
class GpsTrackingScreen extends ConsumerWidget {
  const GpsTrackingScreen({super.key, required this.busId, required this.busRegistration, required this.operatorContext});

  final String busId;
  final String busRegistration;
  final OperatorContext operatorContext;

  Future<void> _openForm(BuildContext context, WidgetRef ref, {GpsDeviceInfo? existing}) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => _GpsDeviceForm(busId: busId, existing: existing)),
    );
    if (saved == true) ref.invalidate(busGpsStatusProvider(busId));
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Disconnect tracker?'),
        content: const Text('This bus will stop using the tracker. Location history is kept. thirty8 will need to activate a tracker again to resume tracking.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(supabaseProvider).rpc('operator_disconnect_gps_device', params: {'p_bus_id': busId});
      ref.invalidate(busGpsStatusProvider(busId));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(gpsErrorMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(busGpsStatusProvider(busId));
    final theme = Theme.of(context);
    final canEdit = operatorContext.isAdmin;
    final dt = DateFormat('d MMM yyyy, h:mm a');

    return Scaffold(
      appBar: AppBar(title: const Text('GPS Tracking')),
      body: async.when(
        loading: () => const Center(child: AppLoadingState()),
        error: (e, _) => Center(child: AppErrorState(message: 'Could not load tracking details.', onRetry: () => ref.invalidate(busGpsStatusProvider(busId)))),
        data: (s) => RefreshIndicator(
          onRefresh: () async => ref.refresh(busGpsStatusProvider(busId).future),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Text(busRegistration, style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              if (!s.configured)
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('GPS Device', style: theme.textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.xs),
                      Row(children: [
                        Text('Status: ', style: theme.textTheme.bodyMedium),
                        const AppBadge(status: 'Not Configured'),
                      ]),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Register the tracker installed in this bus. thirty8 will then connect it to a tracking provider. '
                        'Until then, no live location is shown for this bus.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      AppButton(label: 'Configure Device', icon: Icons.sensors, onPressed: canEdit ? () => _openForm(context, ref) : null),
                      if (!canEdit) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Only the account owner can configure tracking.', style: theme.textTheme.bodySmall)),
                    ],
                  ),
                )
              else ...[
                _DeviceCard(status: s, dt: dt),
                const SizedBox(height: AppSpacing.sm),
                if (s.device != null && !s.device!.isActive)
                  AppCard(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.hourglass_top, size: 18, color: AppColors.warning),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Your tracker is registered and waiting for thirty8 to activate it with the tracking provider. '
                          'Locations are not shown until then.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ]),
                  ),
                if (canEdit) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Row(children: [
                    Expanded(child: AppButton(label: 'Edit', icon: Icons.edit_outlined, variant: AppButtonVariant.outline, onPressed: () => _openForm(context, ref, existing: s.device))),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: AppButton(label: 'Disconnect', icon: Icons.link_off, variant: AppButtonVariant.destructive, onPressed: () => _disconnect(context, ref))),
                  ]),
                ],
              ],
              const SizedBox(height: AppSpacing.md),
              Text(
                'Phone fallback: ${s.allowDriverFallback ? 'On' : 'Off'} — a driver’s phone only stands in for the tracker if thirty8 enables it for this bus.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.status, required this.dt});

  final BusGpsStatus status;
  final DateFormat dt;

  @override
  Widget build(BuildContext context) {
    final d = status.device!;
    final theme = Theme.of(context);
    Widget row(String label, String? value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 130, child: Text(label, style: theme.textTheme.bodySmall)),
            Expanded(child: Text(value == null || value.isEmpty ? '—' : value)),
          ]),
        );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(d.name?.isNotEmpty == true ? d.name! : 'GPS tracker', style: theme.textTheme.titleSmall)),
            AppBadge(status: d.isActive ? (d.connection == 'online' ? 'active' : 'pending') : 'pending_approval'),
          ]),
          const SizedBox(height: AppSpacing.xs),
          row('Connection', status.statusLabel),
          row('Device identifier', d.deviceIdentifier),
          row('IMEI', d.imei),
          row('Serial number', d.serialNo),
          row('SIM / comms ID', d.simRef),
          row('Tracking source', 'GPS tracker'),
          row('Last location', status.lastRecordedAt == null ? 'None received yet' : dt.format(status.lastRecordedAt!)),
          row('Last communication', d.lastCommunicationAt == null ? 'None yet' : dt.format(d.lastCommunicationAt!)),
          if (d.notes?.isNotEmpty == true) row('Notes', d.notes),
        ],
      ),
    );
  }
}

class _GpsDeviceForm extends ConsumerStatefulWidget {
  const _GpsDeviceForm({required this.busId, this.existing});

  final String busId;
  final GpsDeviceInfo? existing;

  @override
  ConsumerState<_GpsDeviceForm> createState() => _GpsDeviceFormState();
}

class _GpsDeviceFormState extends ConsumerState<_GpsDeviceForm> {
  final _key = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _identifier = TextEditingController(text: widget.existing?.deviceIdentifier);
  late final _imei = TextEditingController(text: widget.existing?.imei);
  late final _serial = TextEditingController(text: widget.existing?.serialNo);
  late final _sim = TextEditingController(text: widget.existing?.simRef);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    for (final c in [_name, _identifier, _imei, _serial, _sim, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final client = ref.read(supabaseProvider);
      if (_editing) {
        await client.rpc('operator_update_gps_device', params: {
          'p_bus_id': widget.busId,
          'p_name': _name.text,
          'p_imei': _imei.text,
          'p_serial_no': _serial.text,
          'p_sim_ref': _sim.text,
          'p_notes': _notes.text,
        });
      } else {
        await client.rpc('operator_register_gps_device', params: {
          'p_bus_id': widget.busId,
          'p_device_identifier': _identifier.text.trim(),
          'p_name': _name.text,
          'p_imei': _imei.text,
          'p_serial_no': _serial.text,
          'p_sim_ref': _sim.text,
          'p_notes': _notes.text,
        });
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(gpsErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit GPS device' : 'Configure GPS device')),
      body: SafeArea(
        child: Form(
          key: _key,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              AppTextField(controller: _name, label: 'Device name (optional)'),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(
                controller: _identifier,
                label: 'Device identifier',
                enabled: !_editing,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the identifier printed on the tracker' : null,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(controller: _imei, label: 'IMEI (optional, 15 digits)', keyboardType: TextInputType.number, validator: validateImei),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(controller: _serial, label: 'Serial number (optional)'),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(controller: _sim, label: 'SIM / communication ID (optional)'),
              const SizedBox(height: AppSpacing.sm),
              AppTextField(controller: _notes, label: 'Notes (optional)'),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'You do not enter any provider login here. thirty8 connects the tracker to its provider after you register it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(label: _editing ? 'Save changes' : 'Register tracker', expand: true, loading: _saving, onPressed: _saving ? null : _save),
            ],
          ),
        ),
      ),
    );
  }
}
