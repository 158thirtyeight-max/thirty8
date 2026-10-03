import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'seat_layout/seat_layout_wizard_screen.dart';

/// Creates a bus, then opens the seat layout wizard — the
/// generate_trip_seats trigger on bus_trips needs an active bus_layout with
/// seats to exist before any trip can be created for this bus.
class BusFormScreen extends ConsumerStatefulWidget {
  const BusFormScreen({super.key, required this.operatorId});

  final String operatorId;

  @override
  ConsumerState<BusFormScreen> createState() => _BusFormScreenState();
}

class _BusFormScreenState extends ConsumerState<BusFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _regController = TextEditingController();
  final _seatsController = TextEditingController(text: '36');
  String _busType = 'ac_seater';
  bool _loading = false;
  String? _error;

  static const _busTypes = ['ac_seater', 'non_ac_seater', 'ac_sleeper', 'non_ac_sleeper', 'ac_semi_sleeper', 'non_ac_semi_sleeper'];

  @override
  void dispose() {
    _regController.dispose();
    _seatsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final totalSeats = int.parse(_seatsController.text.trim());
      final supabase = ref.read(supabaseProvider);

      final bus = await supabase
          .from('buses')
          .insert({
            'operator_id': widget.operatorId,
            'registration_number': _regController.text.trim().toUpperCase(),
            'bus_type': _busType,
            'total_seats': totalSeats,
          })
          .select()
          .single();

      // Seat layout is configured in the guided wizard; the bus exists first
      // so the wizard can save drafts against it.
      if (!mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => SeatLayoutWizardScreen(busId: bus['id'] as String, initialCapacity: totalSeats)),
      );

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Could not save bus: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add bus')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(
                  controller: _regController,
                  textCapitalization: TextCapitalization.characters,
                  label: 'Registration number',
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _busType,
                  decoration: const InputDecoration(labelText: 'Bus type'),
                  items: _busTypes.map((t) => DropdownMenuItem(value: t, child: Text(t.replaceAll('_', ' ')))).toList(),
                  onChanged: (v) => setState(() => _busType = v!),
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: _seatsController,
                  keyboardType: TextInputType.number,
                  label: 'Total capacity',
                  helperText: 'Next, you will set up the seat layout step by step',
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    if (n == null || n < 1 || n > 80) return 'Enter a number between 1 and 80';
                    return null;
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 24),
                AppButton(
                  label: 'Save & set up seats',
                  onPressed: _loading ? null : _save,
                  loading: _loading,
                  expand: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
