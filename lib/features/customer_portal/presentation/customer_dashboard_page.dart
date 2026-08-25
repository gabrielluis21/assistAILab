import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../../service_orders/service_order_entity.dart';
import '../application/customer_service_orders_provider.dart';

class CustomerDashboardPage extends ConsumerWidget {
  const CustomerDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authStateProvider);
    final ordersAsync =
        ref.watch(customerServiceOrdersProvider);

    final user = auth.valueOrNull;

    final firstName = user?.name.trim().isNotEmpty == true
        ? user!.name.trim().split(RegExp(r'\s+')).first
        : 'Cliente';

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ordersAsync.when(
            loading: () => const Center(
              child: CircularProgressIndicator(),
            ),
            error: (error, stackTrace) => Center(
              child: Text(
                'Não foi possível carregar seus atendimentos.',
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: Colors.white70),
              ),
            ),
            data: (orders) {
              final active = orders.where((order) {
                return order.status !=
                        ServiceOrderStatusEnum.entregue &&
                    order.status !=
                        ServiceOrderStatusEnum.cancelado;
              }).length;

              final awaitingApproval = orders
                  .where(
                    (order) =>
                        order.status ==
                        ServiceOrderStatusEnum
                            .aguardandoAprovacao,
                  )
                  .length;

              final ready = orders
                  .where(
                    (order) =>
                        order.status ==
                        ServiceOrderStatusEnum.pronto,
                  )
                  .length;

              return ListView(
                children: [
                  Text(
                    'Olá, $firstName 👋',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Acompanhe seus atendimentos',
                    style: TextStyle(
                      color: Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _SummaryCard(
                    title: 'Em andamento',
                    value: active,
                    icon: Icons.build_circle_outlined,
                  ),
                  const SizedBox(height: 12),
                  _SummaryCard(
                    title: 'Aguardando aprovação',
                    value: awaitingApproval,
                    icon: Icons.pending_actions,
                  ),
                  const SizedBox(height: 12),
                  _SummaryCard(
                    title: 'Prontos para retirada',
                    value: ready,
                    icon: Icons.check_circle_outline,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final int value;
  final IconData icon;

  const _SummaryCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF334155),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: const Color(0xFF38BDF8),
            size: 30,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 15,
              ),
            ),
          ),
          Text(
            '$value',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}