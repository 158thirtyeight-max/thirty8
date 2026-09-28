import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import '../search/city.dart';
import '../search/city_picker_screen.dart';
import 'shipment_quote_screen.dart';

/// 5-step shipment creation: route, package, pickup, delivery, speed — then
/// "Get Quote" hands off to ShipmentQuoteScreen. A single stepped form
/// rather than a PageView, so each step's validation stays simple.
class NewShipmentScreen extends ConsumerStatefulWidget {
  const NewShipmentScreen({super.key});

  @override
  ConsumerState<NewShipmentScreen> createState() => _NewShipmentScreenState();
}

class _NewShipmentScreenState extends ConsumerState<NewShipmentScreen> {
  int _step = 0;
  static const _stepTitles = ['Route', 'Package', 'Pickup', 'Delivery', 'Speed'];

  City? _source;
  City? _destination;

  List<Map<String, dynamic>> _cargoTypes = [];
  Map<String, dynamic>? _cargoType;
  final _weightController = TextEditingController();
  final _lengthController = TextEditingController();
  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _declaredValueController = TextEditingController();

  String _pickupType = 'address';
  final _pickupAddressController = TextEditingController();
  final _pickupContactNameController = TextEditingController();
  final _pickupContactPhoneController = TextEditingController();
  Map<String, dynamic>? _pickupHub;
  List<Map<String, dynamic>> _pickupHubs = [];

  String _deliveryType = 'address';
  final _deliveryAddressController = TextEditingController();
  final _deliveryContactNameController = TextEditingController();
  final _deliveryContactPhoneController = TextEditingController();
  Map<String, dynamic>? _deliveryHub;
  List<Map<String, dynamic>> _deliveryHubs = [];

  String _speed = 'standard';

  @override
  void initState() {
    super.initState();
    _loadCargoTypes();
  }

  @override
  void dispose() {
    _weightController.dispose();
    _lengthController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _descriptionController.dispose();
    _declaredValueController.dispose();
    _pickupAddressController.dispose();
    _pickupContactNameController.dispose();
    _pickupContactPhoneController.dispose();
    _deliveryAddressController.dispose();
    _deliveryContactNameController.dispose();
    _deliveryContactPhoneController.dispose();
    super.dispose();
  }

  Future<void> _loadCargoTypes() async {
    final res = await ref.read(supabaseProvider).from('cargo_types').select().order('name');
    if (!mounted) return;
    setState(() => _cargoTypes = List<Map<String, dynamic>>.from(res as List));
  }

  Future<void> _loadHubs({required bool isPickup}) async {
    final city = isPickup ? _source : _destination;
    if (city == null) return;
    final res = await ref.read(supabaseProvider).from('cargo_hub').select().eq('city_id', city.id).eq('is_active', true);
    if (!mounted) return;
    setState(() {
      if (isPickup) {
        _pickupHubs = List<Map<String, dynamic>>.from(res as List);
      } else {
        _deliveryHubs = List<Map<String, dynamic>>.from(res as List);
      }
    });
  }

  Future<void> _pickCity({required bool isSource}) async {
    final city = await Navigator.of(context).push<City>(
      MaterialPageRoute(builder: (_) => CityPickerScreen(title: isSource ? 'Origin city' : 'Destination city')),
    );
    if (city == null) return;
    setState(() {
      if (isSource) {
        _source = city;
      } else {
        _destination = city;
      }
    });
  }

  bool get _canGoNext {
    switch (_step) {
      case 0:
        return _source != null && _destination != null && _source!.id != _destination!.id;
      case 1:
        return _cargoType != null && double.tryParse(_weightController.text) != null;
      case 2:
        return _pickupType == 'hub' ? _pickupHub != null : _pickupAddressController.text.trim().isNotEmpty;
      case 3:
        return _deliveryType == 'hub' ? _deliveryHub != null : _deliveryAddressController.text.trim().isNotEmpty;
      default:
        return true;
    }
  }

  void _next() {
    if (!_canGoNext) return;
    if (_step == 2 && _pickupType == 'hub' && _pickupHubs.isEmpty) _loadHubs(isPickup: true);
    if (_step == 3 && _deliveryType == 'hub' && _deliveryHubs.isEmpty) _loadHubs(isPickup: false);
    if (_step < _stepTitles.length - 1) {
      setState(() => _step++);
    } else {
      _getQuote();
    }
  }

  void _getQuote() {
    final shipment = <String, dynamic>{
      'source_city_id': _source!.id,
      'destination_city_id': _destination!.id,
      'cargo_type_id': _cargoType!['id'],
      'weight_kg': double.parse(_weightController.text),
      if (_lengthController.text.isNotEmpty) 'length_cm': double.tryParse(_lengthController.text),
      if (_widthController.text.isNotEmpty) 'width_cm': double.tryParse(_widthController.text),
      if (_heightController.text.isNotEmpty) 'height_cm': double.tryParse(_heightController.text),
      if (_descriptionController.text.isNotEmpty) 'description': _descriptionController.text.trim(),
      if (_declaredValueController.text.isNotEmpty) 'declared_value_cents': (double.tryParse(_declaredValueController.text) ?? 0) * 100,
      'pickup_type': _pickupType,
      if (_pickupType == 'address') 'pickup_address': _pickupAddressController.text.trim() else 'pickup_hub_id': _pickupHub!['id'],
      'pickup_contact_name': _pickupContactNameController.text.trim(),
      'pickup_contact_phone': _pickupContactPhoneController.text.trim(),
      'delivery_type': _deliveryType,
      if (_deliveryType == 'address') 'delivery_address': _deliveryAddressController.text.trim() else 'delivery_hub_id': _deliveryHub!['id'],
      'delivery_contact_name': _deliveryContactNameController.text.trim(),
      'delivery_contact_phone': _deliveryContactPhoneController.text.trim(),
      'shipping_speed': _speed,
    };

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShipmentQuoteScreen(
          sourceCityId: _source!.id,
          destinationCityId: _destination!.id,
          cargoTypeId: _cargoType!['id'] as String,
          weightKg: double.parse(_weightController.text),
          shipment: shipment,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Send a package — ${_stepTitles[_step]}')),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(value: (_step + 1) / _stepTitles.length),
            Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: _buildStep())),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (_step > 0)
                      Expanded(child: AppButton(label: 'Back', variant: AppButtonVariant.outline, onPressed: () => setState(() => _step--))),
                    if (_step > 0) const SizedBox(width: 12),
                    Expanded(
                      child: AppButton(
                        label: _step == _stepTitles.length - 1 ? 'Get quote' : 'Next',
                        onPressed: _canGoNext ? _next : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppCard(
              padding: EdgeInsets.zero,
              child: AppListItem(
                leading: const Icon(Icons.trip_origin),
                title: _source?.name ?? 'Origin city',
                onTap: () => _pickCity(isSource: true),
              ),
            ),
            const SizedBox(height: 8),
            AppCard(
              padding: EdgeInsets.zero,
              child: AppListItem(
                leading: const Icon(Icons.location_on),
                title: _destination?.name ?? 'Destination city',
                onTap: () => _pickCity(isSource: false),
              ),
            ),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<Map<String, dynamic>>(
              initialValue: _cargoType,
              decoration: const InputDecoration(labelText: 'Cargo type'),
              items: _cargoTypes
                  .map((t) => DropdownMenuItem(value: t, child: Text(t['name'] as String)))
                  .toList(),
              onChanged: (v) => setState(() => _cargoType = v),
            ),
            const SizedBox(height: 12),
            AppTextField(
              controller: _weightController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              label: 'Weight (kg)',
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: AppTextField(controller: _lengthController, label: 'L (cm)', keyboardType: TextInputType.number)),
                const SizedBox(width: 8),
                Expanded(child: AppTextField(controller: _widthController, label: 'W (cm)', keyboardType: TextInputType.number)),
                const SizedBox(width: 8),
                Expanded(child: AppTextField(controller: _heightController, label: 'H (cm)', keyboardType: TextInputType.number)),
              ],
            ),
            const SizedBox(height: 12),
            AppTextField(controller: _descriptionController, label: 'Description (optional)'),
            const SizedBox(height: 12),
            AppTextField(
              controller: _declaredValueController,
              keyboardType: TextInputType.number,
              label: 'Declared value ₹ (optional)',
            ),
          ],
        );
      case 2:
        return _buildPointStep(
          isPickup: true,
          type: _pickupType,
          onTypeChanged: (v) => setState(() => _pickupType = v),
          addressController: _pickupAddressController,
          nameController: _pickupContactNameController,
          phoneController: _pickupContactPhoneController,
          hubs: _pickupHubs,
          selectedHub: _pickupHub,
          onHubChanged: (h) => setState(() => _pickupHub = h),
        );
      case 3:
        return _buildPointStep(
          isPickup: false,
          type: _deliveryType,
          onTypeChanged: (v) => setState(() => _deliveryType = v),
          addressController: _deliveryAddressController,
          nameController: _deliveryContactNameController,
          phoneController: _deliveryContactPhoneController,
          hubs: _deliveryHubs,
          selectedHub: _deliveryHub,
          onHubChanged: (h) => setState(() => _deliveryHub = h),
        );
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioListTile<String>(
              value: 'standard',
              groupValue: _speed,
              title: const Text('Standard (2-5 days)'),
              onChanged: (v) => setState(() => _speed = v!),
            ),
            RadioListTile<String>(
              value: 'express',
              groupValue: _speed,
              title: const Text('Express (1-2 days)'),
              onChanged: (v) => setState(() => _speed = v!),
            ),
            RadioListTile<String>(
              value: 'same_day',
              groupValue: _speed,
              title: const Text('Same-day (where available)'),
              onChanged: (v) => setState(() => _speed = v!),
            ),
          ],
        );
    }
  }

  Widget _buildPointStep({
    required bool isPickup,
    required String type,
    required ValueChanged<String> onTypeChanged,
    required TextEditingController addressController,
    required TextEditingController nameController,
    required TextEditingController phoneController,
    required List<Map<String, dynamic>> hubs,
    required Map<String, dynamic>? selectedHub,
    required ValueChanged<Map<String, dynamic>?> onHubChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'address', label: Text('Address')),
            ButtonSegment(value: 'hub', label: Text('Hub drop-off')),
          ],
          selected: {type},
          onSelectionChanged: (s) {
            onTypeChanged(s.first);
            if (s.first == 'hub') _loadHubs(isPickup: isPickup);
          },
        ),
        const SizedBox(height: 16),
        if (type == 'address')
          AppTextField(controller: addressController, maxLines: 2, label: 'Address', onChanged: (_) => setState(() {}))
        else if (hubs.isEmpty)
          const AppEmptyState(message: 'No hubs available in this city yet.', icon: Icons.warehouse_outlined)
        else
          DropdownButtonFormField<Map<String, dynamic>>(
            initialValue: selectedHub,
            decoration: const InputDecoration(labelText: 'Hub'),
            items: hubs.map((h) => DropdownMenuItem(value: h, child: Text(h['name'] as String))).toList(),
            onChanged: onHubChanged,
          ),
        const SizedBox(height: 12),
        AppTextField(controller: nameController, label: 'Contact name'),
        const SizedBox(height: 12),
        AppTextField(controller: phoneController, keyboardType: TextInputType.phone, label: 'Contact phone'),
      ],
    );
  }
}
