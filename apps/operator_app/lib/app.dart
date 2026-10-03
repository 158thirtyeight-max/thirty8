import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'core/router.dart';
import 'core/theme.dart';

class ThirtyEightPlusApp extends StatefulWidget {
  const ThirtyEightPlusApp({super.key});

  @override
  State<ThirtyEightPlusApp> createState() => _ThirtyEightPlusAppState();
}

class _ThirtyEightPlusAppState extends State<ThirtyEightPlusApp> {
  late final GoRouter _router = buildRouter();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Thirty8 Plus',
      locale: const Locale('en', 'IN'),
      supportedLocales: const [Locale('en', 'IN')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: _router,
    );
  }
}
