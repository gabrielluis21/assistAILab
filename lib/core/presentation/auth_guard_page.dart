import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_provider.dart';
import '../../features/auth/application/auth_route_resolver.dart';
import '../../features/auth/domain/entities/session_state.dart';

class AuthGuardPage extends ConsumerWidget {
  const AuthGuardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authStateProvider);

    final route = switch (session) {
      AuthenticatedSession(:final user) => AuthRouteResolver.routeFor(user),
      SessionUnauthenticated() ||
      SessionFailure() =>
        AuthRouteResolver.loginRoute,
      _ => null,
    };
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Modular.to.path != route) {
          Modular.to.navigate(route);
        }
      });
    }

    return const Scaffold(
      backgroundColor: Color(0xFF0F172A),
      body: Center(
        child: CircularProgressIndicator(
          color: Color(0xFF38BDF8),
        ),
      ),
    );
  }
}
