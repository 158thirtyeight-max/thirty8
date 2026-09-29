import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'booking_confirmation_screen.dart';
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
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();

  Timer? _timer;
  Duration _remaining = Duration.zero;
  bool _expired = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _nameControllers = List.generate(widget.selectedSeats.length, (_) => TextEditingController());
    _ageControllers = List.generate(widget.selectedSeats.length, (_) => TextEditingController());
    _genders = List.generate(widget.selectedSeats.length, (_) => 'male');

    _remaining = widget.expiresAt.difference(DateTime.now());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final remaining = widget.expiresAt.difference(DateTime.now());
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
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
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
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PaymentScreen(
            orderReference: booking['order_reference'] as String,
            amountCents: booking['amount_cents'] as int,
            description: 'Booking ${booking['booking_reference']}',
            onSuccess: (_) => BookingConfirmationScreen(bookingReference: booking['booking_reference'] as String),
          ),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_expired ? 'Your seat hold expired.' : 'Could not create the booking. Please try again.')),
      );
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
