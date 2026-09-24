import 'package:flutter/material.dart';

/// Shown only for the instant it takes the router's redirect logic to
/// resolve the current auth state (see core/router.dart).
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
