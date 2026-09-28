import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/supabase_providers.dart';
import 'new_shipment_screen.dart';
import 'shipment_detail_screen.dart';

class CargoTab extends ConsumerStatefulWidget {
  const CargoTab({super.key});

  @override
  ConsumerState<CargoTab> createState() => _CargoTabState();
}

class _CargoTabState extends ConsumerState<CargoTab> {
  List<Map<String, dynamic>> _shipments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = ref.read(currentUserProvider)?.id;
    if (userId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final res = await ref
          .read(supabaseProvider)
          .from('cargo_shipments')
          .select()
          .eq('sender_user_id', userId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _shipments = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoadingState();

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AppButton(
              label: 'Send a package',
              icon: Icons.add,
              expand: true,
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewShipmentScreen()));
                _load();
              },
            ),
            const SizedBox(height: 24),
            AppSectionHeader(title: 'My shipments'),
            if (_shipments.isEmpty)
              const AppEmptyState(message: 'No shipments yet', icon: Icons.local_shipping_outlined)
            else
              ..._shipments.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: AppCard(
                      padding: EdgeInsets.zero,
                      child: AppListItem(
                        title: s['shipment_reference'] as String? ?? '',
                        subtitle: DateFormat('d MMM yyyy').format(DateTime.parse(s['created_at'] as String)),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('₹${((s['total_fare_cents'] as int? ?? 0) / 100).toStringAsFixed(0)}'),
                            const SizedBox(height: AppSpacing.xs),
                            AppBadge(status: s['status'] as String? ?? ''),
                          ],
                        ),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ShipmentDetailScreen(shipmentId: s['id'] as String)),
                          );
                          _load();
                        },
                      ),
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}
