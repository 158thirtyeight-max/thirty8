import 'package:design_system/design_system.dart';
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
              const Icon(Icons.check_circle, size: 64, color: AppColors.success),
              const SizedBox(height: 12),
              Text(shipmentReference, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text('Your shipment has been confirmed and is awaiting pickup.'),
              const SizedBox(height: 24),
              AppButton(
                label: 'Track shipment',
                expand: true,
                onPressed: () async {
                  final supabase = ref.read(supabaseProvider);
                  final shipment = await supabase.from('cargo_shipments').select('id').eq('shipment_reference', shipmentReference).single();
                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => ShipmentDetailScreen(shipmentId: shipment['id'] as String)),
                  );
                },
              ),
              const SizedBox(height: 12),
              AppButton(
                label: 'Back to home',
                variant: AppButtonVariant.outline,
                expand: true,
                onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
