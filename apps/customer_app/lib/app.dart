import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/router.dart';
import 'core/theme.dart';

class ThirtyEightApp extends StatefulWidget {
  const ThirtyEightApp({super.key});

  @override
  State<ThirtyEightApp> createState() => _ThirtyEightAppState();
}

class _ThirtyEightAppState extends State<ThirtyEightApp> {
  late final GoRouter _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Thirty8',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: _router,
    );
  }
}
