import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/dashboard/dashboard_page.dart';
import '../../features/service_orders/service_orders_page.dart';
import '../../features/customers/customers_page.dart';
import '../../features/equipment/equipments_page.dart';
import '../../features/parts/parts_page.dart';
import '../../features/finance/finance_page.dart';

// Selected navigation index provider
final _navIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static final _pages = <Widget>[
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
    final selectedIndex = ref.watch(_navIndexProvider);
    final isWide = MediaQuery.of(context).size.width >= 800;

    if (isWide) {
      // Desktop / Tablet: Navigation Rail
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: Row(
          children: [
            _buildNavigationRail(context, ref, selectedIndex),
            const VerticalDivider(color: Color(0xFF1E293B), width: 1),
            Expanded(child: _pages[selectedIndex]),
          ],
        ),
      );
    }

    // Mobile: Bottom Navigation Bar (only first 5 items)
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: _pages[selectedIndex < 5 ? selectedIndex : 0],
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF1E293B),
        indicatorColor: const Color(0xFF0284C7).withOpacity(0.2),
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
            selectedIcon:
                Icon(Icons.build_circle, color: Color(0xFF38BDF8)),
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
            selectedIcon: Icon(Icons.account_balance_wallet,
                color: Color(0xFF38BDF8)),
            label: 'Finance',
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationRail(
      BuildContext context, WidgetRef ref, int selectedIndex) {
    return NavigationRail(
      backgroundColor: const Color(0xFF1E293B),
      selectedIndex: selectedIndex,
      onDestinationSelected: (i) =>
          ref.read(_navIndexProvider.notifier).state = i,
      selectedIconTheme:
          const IconThemeData(color: Color(0xFF38BDF8)),
      unselectedIconTheme:
          const IconThemeData(color: Colors.white38),
      selectedLabelTextStyle: const TextStyle(
          color: Color(0xFF38BDF8), fontWeight: FontWeight.bold),
      unselectedLabelTextStyle:
          const TextStyle(color: Colors.white38),
      extended: true,
      leading: Padding(
        padding:
            const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.construction,
                  color: Colors.white, size: 22),
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
              ],
            ),
          ),
        ),
      ),
      destinations: _destinations,
    );
  }
}

/// Simple sync status indicator shown at bottom of nav rail
class _SyncStatusIndicator extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFF10B981),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Local Service',
            style: TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
