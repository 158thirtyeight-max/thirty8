import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'shipment_detail_screen.dart';

class ShipmentConfirmationScreen extends ConsumerWidget {
  const ShipmentConfirmationScreen({super.key, required this.shipmentReference});

  final String shipmentReference;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shipment confirmed'), automaticallyImplyLeading: false),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, size: 64, color: Colors.green.shade600),
              const SizedBox(height: 12),
              Text(shipmentReference, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('Your shipment has been confirmed and is awaiting pickup.'),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () async {
                  final supabase = ref.read(supabaseProvider);
                  final shipment = await supabase.from('cargo_shipments').select('id').eq('shipment_reference', shipmentReference).single();
                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => ShipmentDetailScreen(shipmentId: shipment['id'] as String)),
                  );
                },
                child: const Text('Track shipment'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
                child: const Text('Back to home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
