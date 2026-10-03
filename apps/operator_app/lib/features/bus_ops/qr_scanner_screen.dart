import 'package:design_system/design_system.dart';
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
      final result = await ref.read(supabaseProvider).rpc('verify_ticket_qr', params: {'p_qr_payload': code}) as Map;
      // A rejected scan (already used, not confirmed, ...) comes back as ok:false and is kept in the audit trail.
      final ok = result['ok'] == true;
      setState(() {
        _lastSuccess = ok;
        _lastMessage = ok
            ? 'Boarded: ${result['passenger_name']} · Seat ${result['seat_code']}'
            : (result['message'] as String? ?? 'This ticket cannot be used for boarding.');
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
                color: _lastSuccess ? AppColors.success : AppColors.error,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_lastMessage!, style: AppTypography.body(Colors.white).copyWith(fontWeight: FontWeight.w600)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
