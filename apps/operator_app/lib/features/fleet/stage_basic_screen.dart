import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/supabase_providers.dart';
import '../../shared/registration_input_formatter.dart';
import 'bus_catalog.dart';
import 'bus_photo_service.dart';
import 'bus_validators.dart';
import 'fleet_providers.dart';

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
  /// Selected catalog entry, or [customOption] when typing a custom value.
  String? _mfrChoice;
  String? _modelChoice;

  /// Photo object keys already stored in R2, and newly picked local files.
  final _savedKeys = {'exterior': <String>[], 'interior': <String>[]};
  final _picked = {'exterior': <String>[], 'interior': <String>[]};
  String? _photoError;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.bus == null;

  String get _manufacturerValue => _mfrChoice == customOption ? _manufacturer.text : (_mfrChoice ?? '');
  String get _modelValue => _modelChoice == customOption ? _model.text : (_modelChoice ?? '');

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
    _savedKeys['exterior']!.addAll(((b['exterior_photo_keys'] as List?) ?? const []).cast<String>());
    _savedKeys['interior']!.addAll(((b['interior_photo_keys'] as List?) ?? const []).cast<String>());
    final mfr = _manufacturer.text.trim();
    if (mfr.isNotEmpty) {
      _mfrChoice = busCatalog.containsKey(mfr) ? mfr : customOption;
      final mdl = _model.text.trim();
      if (mdl.isNotEmpty) _modelChoice = modelsFor(mfr).contains(mdl) ? mdl : customOption;
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _reg, _manufacturer, _model, _mfgYear, _regYear, _seats, _chassis, _engine]) {
      c.dispose();
    }
    super.dispose();
  }

  int _count(String side) => _savedKeys[side]!.length + _picked[side]!.length;

  Future<void> _pick(String side) async {
    final room = BusPhotoService.maxPerSide - _count(side);
    if (room <= 0) return;
    final picked = await ImagePicker().pickMultiImage(imageQuality: 80, maxWidth: 1600, limit: room >= 2 ? room : null);
    if (picked.isEmpty) return;
    setState(() {
      _picked[side]!.addAll(picked.take(room).map((x) => x.path));
      _photoError = null;
    });
  }

  String? _validatePhotos() {
    for (final side in const ['exterior', 'interior']) {
      if (_count(side) < BusPhotoService.minPerSide) {
        return 'Add at least ${BusPhotoService.minPerSide} $side photos (up to ${BusPhotoService.maxPerSide}).';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final formOk = _formKey.currentState!.validate();
    final photoError = _validatePhotos();
    setState(() => _photoError = photoError);
    if (!formOk || photoError != null) return;
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
          'p_manufacturer': nn(_manufacturerValue),
          'p_model': nn(_modelValue),
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

      final photos = BusPhotoService(db);
      final keys = <String, List<String>>{};
      for (final side in const ['exterior', 'interior']) {
        final uploaded = <String>[];
        for (final path in List.of(_picked[side]!)) {
          uploaded.add(await photos.upload(busId: busId, side: side, localPath: path));
        }
        keys[side] = [..._savedKeys[side]!, ...uploaded];
      }
      await db.from('buses').update({
        'exterior_photo_keys': keys['exterior'],
        'interior_photo_keys': keys['interior'],
      }).eq('id', busId);

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

  Widget _thumb(Widget image, VoidCallback onRemove) => SizedBox(
        width: 96,
        height: 72,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(8), child: image),
            Positioned(
              top: 2,
              right: 2,
              child: InkWell(
                onTap: _saving ? null : onRemove,
                child: const CircleAvatar(radius: 10, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 14, color: Colors.white)),
              ),
            ),
          ],
        ),
      );

  Widget _photoSection(String side, String title) {
    final saved = _savedKeys[side]!;
    final picked = _picked[side]!;
    final count = saved.length + picked.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title photos ($count of ${BusPhotoService.maxPerSide}, min ${BusPhotoService.minPerSide})',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final key in saved)
              _thumb(
                Image.network(BusPhotoService.publicUrl(key), fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined)),
                () => setState(() => saved.remove(key)),
              ),
            for (final path in picked) _thumb(Image.file(File(path), fit: BoxFit.cover), () => setState(() => picked.remove(path))),
            if (count < BusPhotoService.maxPerSide)
              InkWell(
                onTap: _saving ? null : () => _pick(side),
                child: Container(
                  width: 96,
                  height: 72,
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.add_a_photo_outlined),
                ),
              ),
          ],
        ),
      ],
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
                  hint: 'KA 01 AB 1234',
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: const [RegistrationInputFormatter()],
                  helperText: 'Format: state code, RTO number, series, vehicle number (AA 00 AA 0000)',
                  validator: BusValidators.registrationNumber,
                ),
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  key: ValueKey('mfr-$_mfrChoice'),
                  initialValue: _mfrChoice,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Manufacturer'),
                  items: [for (final m in [...manufacturerNames, customOption]) DropdownMenuItem(value: m, child: Text(m))],
                  onChanged: locked
                      ? null
                      : (v) => setState(() {
                            if (v != _mfrChoice) {
                              _modelChoice = null;
                              _model.clear();
                            }
                            _mfrChoice = v;
                          }),
                  validator: (v) => v == null ? 'Select a manufacturer' : null,
                ),
                if (_mfrChoice == customOption) ...[
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _manufacturer,
                    label: 'Manufacturer name',
                    enabled: !locked,
                    textCapitalization: TextCapitalization.words,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the manufacturer name' : null,
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String>(
                  key: ValueKey('model-$_mfrChoice-$_modelChoice'),
                  initialValue: _modelChoice,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: 'Model', helperText: _mfrChoice == null ? 'Select a manufacturer first' : null),
                  items: [
                    for (final m in [if (_mfrChoice != null && _mfrChoice != customOption) ...modelsFor(_mfrChoice!), customOption])
                      DropdownMenuItem(value: m, child: Text(m)),
                  ],
                  onChanged: (locked || _mfrChoice == null) ? null : (v) => setState(() => _modelChoice = v),
                  validator: (v) => v == null ? 'Select a model' : null,
                ),
                if (_modelChoice == customOption) ...[
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _model,
                    label: 'Model name',
                    enabled: !locked,
                    textCapitalization: TextCapitalization.words,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the model name' : null,
                  ),
                ],
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
                _photoSection('exterior', 'Exterior'),
                const SizedBox(height: AppSpacing.md),
                _photoSection('interior', 'Interior'),
                if (_photoError != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(_photoError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
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
