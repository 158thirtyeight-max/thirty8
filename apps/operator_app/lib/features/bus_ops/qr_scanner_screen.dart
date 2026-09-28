import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/supabase_providers.dart';

class QrScannerScreen extends ConsumerStatefulWidget {
  const QrScannerScreen({super.key});

  @override
  ConsumerState<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends ConsumerState<QrScannerScreen> {
  bool _busy = false;
  String? _lastMessage;
  bool _lastSuccess = false;

  Future<void> _handleScan(BarcodeCapture capture) async {
    if (_busy) return;
    if (capture.barcodes.isEmpty) return;
    final code = capture.barcodes.first.rawValue;
    if (code == null) return;

    setState(() => _busy = true);
    try {
      final result = await ref.read(supabaseProvider).rpc('verify_ticket_qr', params: {'p_qr_payload': code});
      setState(() {
        _lastSuccess = true;
        _lastMessage = 'Boarded: ${result['passenger_name']} · Seat ${result['seat_code']}';
      });
    } catch (e) {
      setState(() {
        _lastSuccess = false;
        _lastMessage = e.toString().replaceFirst('AuthException: ', '').replaceFirst('PostgrestException(message: ', '');
      });
    } finally {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan boarding ticket')),
      body: Stack(
        children: [
          MobileScanner(onDetect: _handleScan),
          if (_lastMessage != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 32,
              child: Card(
                color: _lastSuccess ? Colors.green.shade600 : Colors.red.shade600,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_lastMessage!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
