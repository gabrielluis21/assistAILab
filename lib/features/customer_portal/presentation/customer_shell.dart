import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../../auth/application/auth_route_resolver.dart';

class CustomerShell extends ConsumerWidget {
  const CustomerShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      loading: () => const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      ),
      error: (error, stackTrace) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Modular.to.navigate(AuthRouteResolver.loginRoute);
        });

        return const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        );
      },
      data: (user) {
        if (user == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Modular.to.navigate(AuthRouteResolver.loginRoute);
          });

          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        if (!AuthRouteResolver.isCustomer(user)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Modular.to.navigate(
              AuthRouteResolver.routeFor(user),
            );
          });

          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('AssistAILab'),
            actions: [
              IconButton(
                tooltip: 'Sair',
                icon: const Icon(Icons.logout),
                onPressed: () async {
                  await ref.read(authStateProvider.notifier).logout();

                  Modular.to.navigate(
                    AuthRouteResolver.loginRoute,
                  );
                },
              ),
            ],
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.person,
                    size: 64,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Olá, ${user.name}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Área do Cliente',
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Perfil: ${user.role}',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Customer ID: ${user.customerId ?? 'não vinculado'}',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}