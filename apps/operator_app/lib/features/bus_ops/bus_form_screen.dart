import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';

/// Creates a bus plus a default 2+2 seat layout sized to `total_seats` — the
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

  static const _busTypes = ['ac_seater', 'non_ac_seater', 'ac_sleeper', 'non_ac_sleeper', 'ac_seater_sleeper'];

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

      final layout = await supabase
          .from('bus_layouts')
          .insert({'bus_id': bus['id'], 'name': 'Default layout', 'deck_count': 1})
          .select()
          .single();

      const columns = ['A', 'B', 'C', 'D'];
      final seatRows = <Map<String, dynamic>>[];
      var seatsLeft = totalSeats;
      var row = 1;
      while (seatsLeft > 0) {
        final colsThisRow = seatsLeft >= 4 ? 4 : seatsLeft;
        for (var c = 0; c < colsThisRow; c++) {
          seatRows.add({
            'bus_layout_id': layout['id'],
            'seat_code': '$row${columns[c]}',
            'deck': 1,
            'row_no': row,
            'col_no': c + 1,
            'seat_type': 'seater',
          });
        }
        seatsLeft -= colsThisRow;
        row++;
      }
      await supabase.from('seats').insert(seatRows);

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
                  label: 'Total seats',
                  helperText: 'A default 2+2 layout will be generated automatically',
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
                  label: 'Save bus',
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
