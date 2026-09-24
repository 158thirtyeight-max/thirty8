import 'package:flutter/material.dart';

/// Cargo shipment flow (5-step create, quote, pay, track) — Phase 8.
class CargoTab extends StatelessWidget {
  const CargoTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const _ComingSoon(
      icon: Icons.local_shipping_outlined,
      title: 'Send a package',
      subtitle: 'Cargo shipping between islands is coming soon.',
    );
  }
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(subtitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
