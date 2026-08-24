import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_modular/flutter_modular.dart';
import '../../features/auth/application/auth_provider.dart';

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
            if (user == null) {
              Modular.to.navigate('/login');
            } else {
              Modular.to.navigate('/home');
            }
          });
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)));
        },
        loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFF38BDF8))),
        error: (e, _) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Modular.to.navigate('/login');
          });
          return Center(
            child: Text('Erro: $e', style: const TextStyle(color: Colors.red)),
          );
        },
      ),
    );
  }
}
