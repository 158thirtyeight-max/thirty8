import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'booking_confirmation_screen.dart';
import 'booking_errors.dart';
import 'passenger_documents.dart';
import 'payment_screen.dart';

class PassengerDetailsScreen extends ConsumerStatefulWidget {
  const PassengerDetailsScreen({
    super.key,
    required this.holdToken,
    required this.expiresAt,
    required this.selectedSeats,
    required this.boardingPoint,
    required this.droppingPoint,
  });

  final String holdToken;
  final DateTime expiresAt;
  final List<Map<String, dynamic>> selectedSeats;
  final Map<String, dynamic> boardingPoint;
  final Map<String, dynamic> droppingPoint;

  @override
  ConsumerState<PassengerDetailsScreen> createState() => _PassengerDetailsScreenState();
}

class _PassengerDetailsScreenState extends ConsumerState<PassengerDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final List<TextEditingController> _nameControllers;
  late final List<TextEditingController> _ageControllers;
  late final List<String> _genders;
  late final List<DocType?> _docTypes;
  late final List<TextEditingController> _docNumbers;
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  Timer? _timer;
  late DateTime _expiresAt = widget.expiresAt;
  Duration _remaining = Duration.zero;
  bool _expired = false;
  bool _submitting = false;
  bool _renewed = false;
  bool _renewing = false;

  @override
  void initState() {
    super.initState();
    _nameControllers = List.generate(widget.selectedSeats.length, (_) => TextEditingController());
    _ageControllers = List.generate(widget.selectedSeats.length, (_) => TextEditingController());
    _genders = List.generate(widget.selectedSeats.length, (_) => 'male');
    _docTypes = List.generate(widget.selectedSeats.length, (_) => null);
    _docNumbers = List.generate(widget.selectedSeats.length, (_) => TextEditingController());

    _remaining = _expiresAt.difference(DateTime.now());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final remaining = _expiresAt.difference(DateTime.now());
    if (remaining.isNegative) {
      _timer?.cancel();
      setState(() {
        _remaining = Duration.zero;
        _expired = true;
      });
      return;
    }
    setState(() => _remaining = remaining);
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _nameControllers) {
      c.dispose();
    }
    for (final c in _ageControllers) {
      c.dispose();
    }
    for (final c in _docNumbers) {
      c.dispose();
    }
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  /// One extension per hold (the server enforces the limit): more time to fill in details.
  Future<void> _extend() async {
    setState(() => _renewing = true);
    try {
      final res = await ref.read(supabaseProvider).rpc('renew_seat_hold', params: {'p_hold_token': widget.holdToken, 'p_ttl_seconds': 300});
      if (!mounted) return;
      setState(() {
        _expiresAt = DateTime.parse((res as Map<String, dynamic>)['expires_at'] as String);
        _renewed = true;
        _expired = false;
      });
      if (!(_timer?.isActive ?? false)) _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (e) {
      if (mounted) {
        setState(() => _renewed = true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(renewHoldErrorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _renewing = false);
    }
  }

  Future<void> _submit() async {
    if (_expired) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    try {
      final passengers = List.generate(
        widget.selectedSeats.length,
        (i) => {
          'full_name': _nameControllers[i].text.trim(),
          'age': int.parse(_ageControllers[i].text.trim()),
          'gender': _genders[i],
          'phone': _phoneController.text.trim(),
          ...documentFields(_docTypes[i]!, _docNumbers[i].text),
        },
      );

      final result = await ref.read(supabaseProvider).rpc('create_booking', params: {
        'p_hold_token': widget.holdToken,
        'p_contact_email': _emailController.text.trim(),
        'p_contact_phone': _phoneController.text.trim(),
        'p_passengers': passengers,
        'p_boarding_point_id': widget.boardingPoint['id'],
        'p_dropping_point_id': widget.droppingPoint['id'],
      });

      if (!mounted) return;
      final booking = result as Map<String, dynamic>;

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PaymentScreen(
            orderReference: booking['order_reference'] as String,
            amountCents: booking['amount_cents'] as int,
            description: 'Booking ${booking['booking_reference']}',
            contactEmail: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
            contactPhone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
            onSuccess: (_) => BookingConfirmationScreen(bookingReference: booking['booking_reference'] as String),
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      final message = bookingErrorMessage(e, holdExpired: _expired);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _remaining.inMinutes;
    final seconds = _remaining.inSeconds % 60;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Passenger details'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                _expired ? 'Expired' : '$minutes:${seconds.toString().padLeft(2, '0')}',
                style: TextStyle(
                  color: _remaining.inSeconds < 60 ? Theme.of(context).colorScheme.error : null,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!_expired && !_renewed && _remaining.inSeconds < 90)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: AppButton(
                    label: 'Need more time? Extend by 5 minutes',
                    variant: AppButtonVariant.outline,
                    loading: _renewing,
                    onPressed: _renewing ? null : _extend,
                  ),
                ),
              if (_expired)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer, borderRadius: AppRadius.mdRadius),
                  child: const Text('Your seat hold expired. Go back and select seats again.'),
                ),
              for (int i = 0; i < widget.selectedSeats.length; i++) ...[
                AppSectionHeader(title: 'Seat ${widget.selectedSeats[i]['seat_code']}'),
                AppTextField(
                  controller: _nameControllers[i],
                  label: 'Full name',
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: AppTextField(
                        controller: _ageControllers[i],
                        keyboardType: TextInputType.number,
                        label: 'Age',
                        validator: (v) => (v == null || int.tryParse(v) == null) ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _genders[i],
                        decoration: const InputDecoration(labelText: 'Gender'),
                        items: const [
                          DropdownMenuItem(value: 'male', child: Text('Male')),
                          DropdownMenuItem(value: 'female', child: Text('Female')),
                          DropdownMenuItem(value: 'other', child: Text('Other')),
                        ],
                        onChanged: (v) => setState(() => _genders[i] = v ?? 'male'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<DocType>(
                  initialValue: _docTypes[i],
                  decoration: const InputDecoration(labelText: 'ID type (required for boarding)'),
                  items: [for (final t in bookableDocTypes) DropdownMenuItem<DocType>(value: t, child: Text(t.label))],
                  validator: (v) => v == null ? 'Choose an ID type' : null,
                  onChanged: (v) => setState(() => _docTypes[i] = v),
                ),
                const SizedBox(height: 8),
                AppTextField(
                  controller: _docNumbers[i],
                  label: _docTypes[i] == null ? 'ID number' : '${_docTypes[i]!.label} number',
                  validator: (v) => validatePassengerId(_docTypes[i], v ?? ''),
                ),
                const SizedBox(height: 4),
                Text(
                  'Only the ID type and number are needed — no photo or scan. The operator sees just the type and the last 4 characters.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
              ],
              const AppSectionHeader(title: 'Contact details'),
              AppTextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                label: 'Email',
                validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
              ),
              const SizedBox(height: 8),
              AppTextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                label: 'Phone',
                validator: (v) => (v == null || v.trim().length < 10) ? 'Enter a valid phone number' : null,
              ),
              const SizedBox(height: 24),
              AppButton(
                label: 'Proceed to payment',
                loading: _submitting,
                onPressed: (_expired || _submitting) ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
