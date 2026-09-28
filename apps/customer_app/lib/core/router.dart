import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/home/home_gate.dart';
import '../features/search/city.dart';
import '../features/search/search_results_screen.dart';

/// Bridges a Stream to Listenable so GoRouter's `refreshListenable` re-runs
/// `redirect` on every auth change (sign in, sign out, token refresh).
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    notifyListeners();
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

GoRouter buildRouter() {
  final auth = Supabase.instance.client.auth;

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: GoRouterRefreshStream(auth.onAuthStateChange),
    redirect: (context, state) {
      final loggedIn = auth.currentSession != null;
      final path = state.matchedLocation;
      final isAuthRoute = path == '/login' || path == '/signup';

      if (!loggedIn && !isAuthRoute) return '/login';
      if (loggedIn && (isAuthRoute || path == '/splash')) return '/home';
      if (!loggedIn && path == '/splash') return '/login';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(path: '/signup', builder: (context, state) => const SignupScreen()),
      GoRoute(path: '/home', builder: (context, state) => const HomeGate()),
      GoRoute(
        path: '/search-results',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return SearchResultsScreen(
            source: extra['source'] as City,
            destination: extra['destination'] as City,
            date: extra['date'] as DateTime,
          );
        },
      ),
    ],
  );
}
