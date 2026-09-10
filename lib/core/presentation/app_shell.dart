import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/application/auth_provider.dart';
import '../../features/auth/application/auth_route_resolver.dart';
import '../../features/auth/domain/entities/session_state.dart';
import '../../features/dashboard/dashboard_page.dart';
import '../../features/service_orders/service_orders_page.dart';
import '../../features/customers/customers_page.dart';
import '../../features/equipment/equipments_page.dart';
import '../../features/parts/parts_page.dart';
import '../../features/finance/finance_page.dart';
import '../sync/sync_providers.dart';
import '../sync/sync_state.dart';
import '../sync/sync_trigger.dart';

// Selected navigation index provider
final _navIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const _pages = <Widget>[
    DashboardPage(),
    ServiceOrdersPage(),
    CustomersPage(),
    EquipmentsPage(),
    PartsPage(),
    FinancePage(),
  ];

  static const _destinations = [
    NavigationRailDestination(
      icon: Icon(Icons.dashboard_outlined),
      selectedIcon: Icon(Icons.dashboard),
      label: Text('Dashboard'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.build_circle_outlined),
      selectedIcon: Icon(Icons.build_circle),
      label: Text('Ordens de Serviço'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.people_outline),
      selectedIcon: Icon(Icons.people),
      label: Text('Clientes'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.devices_outlined),
      selectedIcon: Icon(Icons.devices),
      label: Text('Equipamentos'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.inventory_2_outlined),
      selectedIcon: Icon(Icons.inventory_2),
      label: Text('Peças/Estoque'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.account_balance_wallet_outlined),
      selectedIcon: Icon(Icons.account_balance_wallet),
      label: Text('Financeiro'),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authStateProvider);
    if (session is! AuthenticatedSession) {
      if (session is SessionUnauthenticated || session is SessionFailure) {
        _navigateAfterBuild(AuthRouteResolver.loginRoute);
      }
      return const _SessionTransitionPage();
    }
    if (AuthRouteResolver.isCustomer(session.user)) {
      _navigateAfterBuild(AuthRouteResolver.customerRoute);
      return const _SessionTransitionPage();
    }

    final selectedIndex = ref.watch(_navIndexProvider);
    final isWide = MediaQuery.of(context).size.width >= 800;
    final isOfflineLimited = session is AuthenticatedOfflineLimited;

    if (isWide) {
      // Desktop / Tablet: Navigation Rail
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: Row(
          children: [
            _buildNavigationRail(
              context,
              ref,
              selectedIndex,
              isOfflineLimited,
            ),
            const VerticalDivider(color: Color(0xFF1E293B), width: 1),
            Expanded(
              child: _pageFor(
                selectedIndex,
                isOfflineLimited: isOfflineLimited,
              ),
            ),
          ],
        ),
      );
    }

    // Mobile: Bottom Navigation Bar (only first 5 items)
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: _pageFor(
        selectedIndex < 5 ? selectedIndex : 0,
        isOfflineLimited: isOfflineLimited,
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF1E293B),
        indicatorColor: const Color(0xFF0284C7).withValues(alpha: 0.2),
        selectedIndex: selectedIndex < 5 ? selectedIndex : 0,
        onDestinationSelected: (i) =>
            ref.read(_navIndexProvider.notifier).state = i,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.dashboard, color: Color(0xFF38BDF8)),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.build_circle_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.build_circle, color: Color(0xFF38BDF8)),
            label: 'OS',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline, color: Colors.white54),
            selectedIcon: Icon(Icons.people, color: Color(0xFF38BDF8)),
            label: 'Clientes',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_outlined, color: Colors.white54),
            selectedIcon: Icon(Icons.devices, color: Color(0xFF38BDF8)),
            label: 'Equip.',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined,
                color: Colors.white54),
            selectedIcon:
                Icon(Icons.account_balance_wallet, color: Color(0xFF38BDF8)),
            label: 'Finance',
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationRail(
    BuildContext context,
    WidgetRef ref,
    int selectedIndex,
    bool isOfflineLimited,
  ) {
    return NavigationRail(
      backgroundColor: const Color(0xFF1E293B),
      selectedIndex: selectedIndex,
      onDestinationSelected: (i) {
        if (isOfflineLimited && i == 5) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Comandos financeiros exigem autoridade online atual.',
              ),
            ),
          );
          return;
        }
        ref.read(_navIndexProvider.notifier).state = i;
      },
      selectedIconTheme: const IconThemeData(color: Color(0xFF38BDF8)),
      unselectedIconTheme: const IconThemeData(color: Colors.white38),
      selectedLabelTextStyle: const TextStyle(
          color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
      unselectedLabelTextStyle: const TextStyle(color: Colors.white38),
      extended: true,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7),
                borderRadius: BorderRadius.circular(8),
              ),
              child:
                  const Icon(Icons.construction, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            const Text(
              'AssistAILab',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
      trailing: Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Divider(color: Color(0xFF334155)),
                const SizedBox(height: 8),
                _SyncStatusIndicator(),
                const SizedBox(height: 8),
                IconButton(
                  tooltip: 'Sair',
                  icon: const Icon(Icons.logout, color: Colors.white70),
                  onPressed: () async {
                    await ref.read(authStateProvider.notifier).logout();
                    Modular.to.navigate(AuthRouteResolver.loginRoute);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      destinations: _destinations,
    );
  }

  Widget _pageFor(
    int index, {
    required bool isOfflineLimited,
  }) {
    if (isOfflineLimited && index == 5) {
      return const _OfflineFinancialBoundary();
    }
    return _pages[index];
  }

  static void _navigateAfterBuild(String route) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Modular.to.path != route) {
        Modular.to.navigate(route);
      }
    });
  }
}

class _SessionTransitionPage extends StatelessWidget {
  const _SessionTransitionPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0F172A),
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class _OfflineFinancialBoundary extends StatelessWidget {
  const _OfflineFinancialBoundary();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'O financeiro fica indisponível durante uma sessão offline limitada. '
          'Reconecte e valide sua autoridade para continuar.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }
}

/// Dynamic sync status indicator shown at bottom of nav rail
class _SyncStatusIndicator extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncStateProvider);

    Color dotColor = const Color(0xFF10B981); // Emerald / synced
    String label = 'Sincronizado';
    Widget icon = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: dotColor,
        shape: BoxShape.circle,
      ),
    );

    if (syncState.isSyncing) {
      dotColor = const Color(0xFF38BDF8); // Sky blue
      label = 'Sincronizando...';
      icon = const SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(0xFF38BDF8),
        ),
      );
    } else if (syncState.status == SyncStatus.error) {
      dotColor = const Color(0xFFEF4444); // Red
      label = syncState.hasPendingMutations
          ? 'Erro (${syncState.pendingOutboxCount} pendentes)'
          : 'Erro de Sync';
      icon = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
        ),
      );
    } else if (syncState.hasPendingMutations) {
      dotColor = const Color(0xFFF59E0B); // Amber
      label = '${syncState.pendingOutboxCount} pendente(s)';
      icon = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
        ),
      );
    }

    final tooltip = syncState.lastError != null
        ? 'Erro: ${syncState.lastError}\nClique para sincronizar agora'
        : 'Clique para sincronizar agora';

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          ref.read(syncSchedulerProvider).requestSync(SyncTrigger.manual);
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: dotColor.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: dotColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
