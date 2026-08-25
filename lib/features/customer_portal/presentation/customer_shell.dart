import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../../auth/application/auth_route_resolver.dart';
import '../../service_orders/service_order_entity.dart';
import 'customer_dashboard_page.dart';
import 'customer_service_order_detail_page.dart';
import 'customer_service_orders_page.dart';

class CustomerShell extends ConsumerStatefulWidget {
  const CustomerShell({super.key});

  @override
  ConsumerState<CustomerShell> createState() => _CustomerShellState();
}

class _CustomerShellState extends ConsumerState<CustomerShell> {
  int _selectedIndex = 0;
  String? _selectedOrderId;

  void _selectTab(int index) {
    setState(() {
      _selectedIndex = index;
      _selectedOrderId = null;
    });
  }

  void _openOrder(ServiceOrderEntity order) {
    setState(() {
      _selectedOrderId = order.id;
    });
  }

  void _closeOrder() {
    setState(() {
      _selectedOrderId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      loading: () => const _LoadingPage(),
      error: (error, stackTrace) {
        _redirectToLogin();

        return const _LoadingPage();
      },
      data: (user) {
        if (user == null) {
          _redirectToLogin();

          return const _LoadingPage();
        }

        if (!AuthRouteResolver.isCustomer(user)) {
          _redirectToCorrectShell(user);

          return const _LoadingPage();
        }

        final content = _selectedOrderId != null
            ? CustomerServiceOrderDetailPage(
                orderId: _selectedOrderId!,
              )
            : _buildCurrentPage();

        return Scaffold(
          backgroundColor: const Color(0xFF0F172A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF1E293B),
            foregroundColor: Colors.white,
            elevation: 0,
            title: Text(
                _selectedOrderId != null ? 'Detalhes da OS' : 'AssistAILab'),
            leading: _selectedOrderId != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back), onPressed: _closeOrder)
                : null,
            actions: [
              IconButton(
                tooltip: 'Sair',
                icon: const Icon(Icons.logout),
                onPressed: () async {
                  await ref.read(authStateProvider.notifier).logout();

                  if (!mounted) return;

                  Modular.to.navigate(
                    AuthRouteResolver.loginRoute,
                  );
                },
              ),
            ],
          ),
          body: content,
          bottomNavigationBar: _selectedOrderId == null
              ? NavigationBar(
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _selectTab,
                  backgroundColor: const Color(0xFF1E293B),
                  indicatorColor: const Color(0xFF0C4A6E),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: 'Início',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.build_circle_outlined),
                      selectedIcon: Icon(Icons.build_circle),
                      label: 'Minhas OS',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.person_outline),
                      selectedIcon: Icon(Icons.person),
                      label: 'Conta',
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }

  Widget _buildCurrentPage() {
    switch (_selectedIndex) {
      case 0:
        return const CustomerDashboardPage();

      case 1:
        return CustomerServiceOrdersPage(
          onOrderSelected: _openOrder,
        );

      case 2:
        return const _CustomerAccountPage();

      default:
        return const CustomerDashboardPage();
    }
  }

  void _redirectToLogin() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      Modular.to.navigate(
        AuthRouteResolver.loginRoute,
      );
    });
  }

  void _redirectToCorrectShell(dynamic user) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      Modular.to.navigate(
        AuthRouteResolver.routeFor(user),
      );
    });
  }
}

class _CustomerAccountPage extends ConsumerWidget {
  const _CustomerAccountPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    final user = authState.valueOrNull;

    return ColoredBox(
      color: const Color(0xFF0F172A),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Minha conta',
              style: TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            _AccountCard(
              label: 'Nome',
              value: user?.name ?? '-',
            ),
            const SizedBox(height: 12),
            _AccountCard(
              label: 'E-mail',
              value: user?.email ?? '-',
            ),
            const SizedBox(height: 12),
            _AccountCard(
              label: 'Perfil',
              value: user?.role ?? '-',
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF334155),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingPage extends StatelessWidget {
  const _LoadingPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0F172A),
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
