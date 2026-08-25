import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_provider.dart';
import '../../features/auth/application/auth_route_resolver.dart';

class AuthGuardPage extends ConsumerWidget {
  const AuthGuardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: authState.when(
        data: (user) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Modular.to.navigate(
              AuthRouteResolver.routeFor(user),
            );
          });

          return const Center(
            child: CircularProgressIndicator(
              color: Color(0xFF38BDF8),
            ),
          );
        },
        error: (e, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Modular.to.navigate('/login');
          });
          return Center(
            child: Text('Erro: $e', style: const TextStyle(color: Colors.red)),
          );
        },
        loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFF38BDF8))),
      ),
    );
  }
}
