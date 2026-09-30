import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/supabase_providers.dart';
import 'bus_validators.dart';
import 'fleet_providers.dart';

const _busPhotosBucket = 'bus-photos';

/// Stage A — basic bus information. Creating goes through the create_bus RPC
/// (approved operators only, enforced server-side); editing updates the row
/// while the bus is a draft, has changes requested, or is a legacy bus.
class StageBasicScreen extends ConsumerStatefulWidget {
  const StageBasicScreen({super.key, required this.operatorId, this.bus});

  final String operatorId;

  /// Null when adding a new bus.
  final Map<String, dynamic>? bus;

  @override
  ConsumerState<StageBasicScreen> createState() => _StageBasicScreenState();
}

class _StageBasicScreenState extends ConsumerState<StageBasicScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _reg;
  late final TextEditingController _manufacturer;
  late final TextEditingController _model;
  late final TextEditingController _mfgYear;
  late final TextEditingController _regYear;
  late final TextEditingController _seats;
  late final TextEditingController _chassis;
  late final TextEditingController _engine;
  bool _ac = true;
  String _seating = 'seater';
  String? _exteriorPath;
  String? _interiorPath;
  String? _pickedExterior;
  String? _pickedInterior;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.bus == null;

  /// Core vehicle details are locked once a bus is in review/approved.
  bool get _locked {
    final b = widget.bus;
    if (b == null) return false;
    final lifecycle = b['lifecycle_status'] as String?;
    return !(b['is_legacy'] == true || lifecycle == 'draft' || lifecycle == 'changes_requested');
  }

  @override
  void initState() {
    super.initState();
    final b = widget.bus ?? const <String, dynamic>{};
    String s(String k) => (b[k] as String?) ?? '';
    _name = TextEditingController(text: s('name'));
    _reg = TextEditingController(text: s('registration_number'));
    _manufacturer = TextEditingController(text: s('manufacturer'));
    _model = TextEditingController(text: s('model'));
    _mfgYear = TextEditingController(text: b['manufacturing_year']?.toString() ?? '');
    _regYear = TextEditingController(text: b['registration_year']?.toString() ?? '');
    _seats = TextEditingController(text: b['total_seats']?.toString() ?? '40');
    _chassis = TextEditingController(text: s('chassis_number'));
    _engine = TextEditingController(text: s('engine_number'));
    final type = b['bus_type'] as String?;
    if (type != null) {
      final p = parseBusType(type);
      _ac = p.ac;
      _seating = p.seating;
    }
    _exteriorPath = b['exterior_photo_path'] as String?;
    _interiorPath = b['interior_photo_path'] as String?;
  }

  @override
  void dispose() {
    for (final c in [_name, _reg, _manufacturer, _model, _mfgYear, _regYear, _seats, _chassis, _engine]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(bool exterior) async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1600);
    if (picked == null) return;
    setState(() => exterior ? _pickedExterior = picked.path : _pickedInterior = picked.path);
  }

  Future<String> _upload(String busId, String kind, String localPath) async {
    final ext = localPath.split('.').last.toLowerCase();
    final path = '${widget.operatorId}/$busId/${kind}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await ref.read(supabaseProvider).storage.from(_busPhotosBucket).upload(path, File(localPath));
    return path;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final db = ref.read(supabaseProvider);
    try {
      final busType = composeBusType(ac: _ac, seating: _seating);
      final reg = BusValidators.normalizeRegistration(_reg.text);
      String? nn(String v) => v.trim().isEmpty ? null : v.trim();

      String busId;
      if (_isNew) {
        final created = await db.rpc('create_bus', params: {
          'p_operator_id': widget.operatorId,
          'p_name': _name.text.trim(),
          'p_registration_number': reg,
          'p_bus_type': busType,
          'p_total_seats': int.parse(_seats.text.trim()),
          'p_manufacturer': nn(_manufacturer.text),
          'p_model': nn(_model.text),
          'p_manufacturing_year': int.tryParse(_mfgYear.text.trim()),
          'p_registration_year': int.tryParse(_regYear.text.trim()),
          'p_chassis_number': nn(_chassis.text),
          'p_engine_number': nn(_engine.text),
        });
        busId = (created as Map)['id'] as String;
      } else {
        busId = widget.bus!['id'] as String;
        if (!_locked) {
          await db.from('buses').update({
            'name': nn(_name.text),
            'registration_number': reg,
            'bus_type': busType,
            'total_seats': int.parse(_seats.text.trim()),
            'manufacturer': nn(_manufacturer.text),
            'model': nn(_model.text),
            'manufacturing_year': int.tryParse(_mfgYear.text.trim()),
            'registration_year': int.tryParse(_regYear.text.trim()),
            'chassis_number': nn(_chassis.text)?.toUpperCase(),
            'engine_number': nn(_engine.text)?.toUpperCase(),
          }).eq('id', busId);
        }
      }

      final photoPatch = <String, dynamic>{};
      if (_pickedExterior != null) photoPatch['exterior_photo_path'] = await _upload(busId, 'exterior', _pickedExterior!);
      if (_pickedInterior != null) photoPatch['interior_photo_path'] = await _upload(busId, 'interior', _pickedInterior!);
      if (photoPatch.isNotEmpty) await db.from('buses').update(photoPatch).eq('id', busId);

      ref.invalidate(busesProvider(widget.operatorId));
      ref.invalidate(busProvider(busId));
      if (mounted) Navigator.of(context).pop(busId);
    } catch (e) {
      final msg = e.toString();
      setState(() => _error = msg.contains('duplicate') || msg.contains('unique')
          ? 'A bus with this registration number already exists.'
          : msg.contains('approved operator')
              ? 'Only approved operators can add buses.'
              : 'Could not save the bus. Please check the details and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _photoTile(String label, String? savedPath, String? picked, VoidCallback onPick) {
    final db = ref.read(supabaseProvider);
    Widget preview;
    if (picked != null) {
      preview = Image.file(File(picked), fit: BoxFit.cover);
    } else if (savedPath != null) {
      preview = Image.network(db.storage.from(_busPhotosBucket).getPublicUrl(savedPath), fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined));
    } else {
      preview = const Icon(Icons.add_a_photo_outlined);
    }
    return Expanded(
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: InkWell(
              onTap: _saving ? null : onPick,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Center(child: preview)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locked = _locked;
    final mfgYear = int.tryParse(_mfgYear.text.trim());
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'Add new bus' : 'Basic information')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (locked)
                  const Padding(
                    padding: EdgeInsets.only(bottom: AppSpacing.md),
                    child: Text('Core vehicle details are locked while the bus is under review or approved. You can still update photos.'),
                  ),
                AppTextField(
                  controller: _name,
                  label: 'Bus name',
                  enabled: !locked,
                  textCapitalization: TextCapitalization.words,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Bus name is required' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _reg,
                  label: 'Registration number',
                  enabled: !locked,
                  textCapitalization: TextCapitalization.characters,
                  validator: BusValidators.registrationNumber,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(controller: _manufacturer, label: 'Manufacturer', enabled: !locked, textCapitalization: TextCapitalization.words,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Manufacturer is required' : null),
                const SizedBox(height: AppSpacing.md),
                AppTextField(controller: _model, label: 'Model', enabled: !locked, textCapitalization: TextCapitalization.words,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Model is required' : null),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: AppTextField(
                        controller: _mfgYear,
                        label: 'Manufacturing year',
                        enabled: !locked,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        onChanged: (_) => setState(() {}),
                        validator: (v) => BusValidators.year(v, label: 'Manufacturing year'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: AppTextField(
                        controller: _regYear,
                        label: 'Registration year',
                        enabled: !locked,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        validator: (v) => BusValidators.year(v, label: 'Registration year', notBefore: mfgYear),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('AC / Non-AC', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: true, label: Text('AC')), ButtonSegment(value: false, label: Text('Non-AC'))],
                  selected: {_ac},
                  onSelectionChanged: locked ? null : (s) => setState(() => _ac = s.first),
                ),
                const SizedBox(height: AppSpacing.md),
                Text('Seating', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'seater', label: Text('Seater')),
                    ButtonSegment(value: 'sleeper', label: Text('Sleeper')),
                    ButtonSegment(value: 'semi_sleeper', label: Text('Semi-sleeper')),
                  ],
                  selected: {_seating},
                  onSelectionChanged: locked ? null : (s) => setState(() => _seating = s.first),
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _seats,
                  label: 'Total seating capacity',
                  enabled: !locked,
                  keyboardType: TextInputType.number,
                  helperText: 'Must match the bookable seats in your seat layout',
                  validator: BusValidators.seats,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(controller: _chassis, label: 'Chassis number (optional)', enabled: !locked, textCapitalization: TextCapitalization.characters),
                const SizedBox(height: AppSpacing.md),
                AppTextField(controller: _engine, label: 'Engine number (optional)', enabled: !locked, textCapitalization: TextCapitalization.characters),
                const SizedBox(height: AppSpacing.lg),
                Text('Photographs', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    _photoTile('Exterior', _exteriorPath, _pickedExterior, () => _pick(true)),
                    const SizedBox(width: AppSpacing.md),
                    _photoTile('Interior', _interiorPath, _pickedInterior, () => _pick(false)),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: _isNew ? 'Create bus & continue' : 'Save',
                  expand: true,
                  loading: _saving,
                  onPressed: _saving ? null : _save,
                ),
                AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  expand: true,
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
