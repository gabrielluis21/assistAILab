import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dashboard_provider.dart';
import '../service_orders/service_order_entity.dart';
import '../service_orders/service_orders_provider.dart';
import '../finance/payments_provider.dart';
import '../finance/payment_entity.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metricsAsync = ref.watch(dashboardMetricsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Dashboard',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: () {
              ref.invalidate(dashboardMetricsProvider);
            },
            tooltip: 'Atualizar',
          ),
        ],
      ),
      body: metricsAsync.when(
        data: (metrics) => _buildDashboard(context, ref, metrics),
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
        ),
        error: (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  color: Color(0xFFEF4444), size: 48),
              const SizedBox(height: 16),
              Text('Erro ao carregar: $e',
                  style: const TextStyle(color: Colors.white54)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashboard(
      BuildContext context, WidgetRef ref, DashboardMetrics metrics) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Greeting
          _buildGreeting(),
          const SizedBox(height: 24),

          // Key metrics row
          _buildKeyMetrics(metrics),
          const SizedBox(height: 24),

          // OS status breakdown
          const Text(
            'Ordens de Serviço',
            style: TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildOsBreakdown(metrics),
          const SizedBox(height: 24),

          // Revenue section
          const Text(
            'Financeiro',
            style: TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _buildRevenueSection(metrics),
          const SizedBox(height: 24),

          // Recent activity
          const Text(
            'Pagamentos Pendentes',
            style: TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _PendingPaymentsList(),
          const SizedBox(height: 24),

          // Recent OS
          const Text(
            'Últimas OS',
            style: TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _RecentOrdersList(),
        ],
      ),
    );
  }

  Widget _buildGreeting() {
    final hour = DateTime.now().hour;
    String greeting;
    if (hour < 12) {
      greeting = 'Bom dia! ☀️';
    } else if (hour < 18) {
      greeting = 'Boa tarde! 🌤️';
    } else {
      greeting = 'Boa noite! 🌙';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          greeting,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          _formattedDate(),
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ],
    );
  }

  String _formattedDate() {
    final now = DateTime.now();
    const months = [
      'jan',
      'fev',
      'mar',
      'abr',
      'mai',
      'jun',
      'jul',
      'ago',
      'set',
      'out',
      'nov',
      'dez'
    ];
    const days = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
    return '${days[now.weekday % 7]}, ${now.day} de ${months[now.month - 1]} de ${now.year}';
  }

  Widget _buildKeyMetrics(DashboardMetrics metrics) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 600;
        final cards = [
          _MetricCard(
            label: 'Clientes',
            value: metrics.totalCustomers.toString(),
            icon: Icons.people,
            color: const Color(0xFF38BDF8),
          ),
          _MetricCard(
            label: 'Equipamentos',
            value: metrics.totalEquipments.toString(),
            icon: Icons.devices,
            color: const Color(0xFF8B5CF6),
          ),
          _MetricCard(
            label: 'OS Abertas',
            value: metrics.ordersOpen.toString(),
            icon: Icons.build_circle,
            color: const Color(0xFFF59E0B),
          ),
          _MetricCard(
            label: 'OS Prontas',
            value: metrics.ordersReady.toString(),
            icon: Icons.check_circle,
            color: const Color(0xFF10B981),
          ),
        ];

        if (isWide) {
          return Row(
            children: cards
                .map((c) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: c,
                      ),
                    ))
                .toList(),
          );
        }
        return GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: cards,
        );
      },
    );
  }

  Widget _buildOsBreakdown(DashboardMetrics metrics) {
    final items = [
      _StatusRow('Em aberto', metrics.ordersOpen, const Color(0xFFF59E0B)),
      _StatusRow(
          'Em execução', metrics.ordersInExecution, const Color(0xFF38BDF8)),
      _StatusRow('Prontas', metrics.ordersReady, const Color(0xFF10B981)),
      _StatusRow('Entregues', metrics.ordersDelivered, const Color(0xFF8B5CF6)),
    ];

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        children: items
            .map((item) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: item.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(item.label,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      ),
                      Text(
                        item.count.toString(),
                        style: TextStyle(
                          color: item.color,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 80,
                        child: LinearProgressIndicator(
                          value: metrics.totalOrders > 0
                              ? item.count / metrics.totalOrders
                              : 0,
                          backgroundColor: const Color(0xFF0F172A),
                          color: item.color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildRevenueSection(DashboardMetrics metrics) {
    return Row(
      children: [
        Expanded(
          child: _RevenueCard(
            label: 'Receita Total',
            value: 'R\$ ${metrics.totalRevenue.toStringAsFixed(2)}',
            sub: 'confirmados',
            icon: Icons.attach_money,
            color: const Color(0xFF10B981),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _RevenueCard(
            label: 'Este Mês',
            value: 'R\$ ${metrics.monthRevenue.toStringAsFixed(2)}',
            sub: 'mês atual',
            icon: Icons.calendar_today,
            color: const Color(0xFF38BDF8),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _RevenueCard(
            label: 'A Receber',
            value: 'R\$ ${metrics.pendingRevenue.toStringAsFixed(2)}',
            sub: '${metrics.paymentsToConfirm} pagamentos',
            icon: Icons.hourglass_top,
            color: const Color(0xFFF59E0B),
          ),
        ),
      ],
    );
  }
}

class _StatusRow {
  final String label;
  final int count;
  final Color color;
  const _StatusRow(this.label, this.count, this.color);
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
              Icon(icon, size: 20, color: color),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _RevenueCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;

  const _RevenueCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withOpacity(0.15),
            color.withOpacity(0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(sub,
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      ),
    );
  }
}

// Widget to show pending payments in dashboard
class _PendingPaymentsList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paymentsAsync = ref.watch(paymentsProvider);
    return paymentsAsync.when(
      data: (payments) {
        final pending = payments
            .where((p) => p.status == PaymentStatus.pending)
            .take(5)
            .toList();
        if (pending.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text('Nenhum pagamento pendente ✓',
                  style: TextStyle(color: Colors.white54)),
            ),
          );
        }
        return Column(
          children: pending
              .map((p) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: const Color(0xFFF59E0B).withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.hourglass_empty,
                            color: Color(0xFFF59E0B), size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.method.label,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13)),
                              Text('OS: ${p.serviceOrderId.substring(0, 8)}...',
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11)),
                            ],
                          ),
                        ),
                        Text(
                          'R\$ ${p.amount.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Color(0xFFF59E0B),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.check_circle,
                              color: Color(0xFF10B981), size: 20),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => ref
                              .read(paymentsProvider.notifier)
                              .confirmPayment(p.id),
                          tooltip: 'Confirmar',
                        ),
                      ],
                    ),
                  ))
              .toList(),
        );
      },
      loading: () => const SizedBox(
          height: 60,
          child: Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)))),
      error: (e, _) =>
          Text('Erro: $e', style: const TextStyle(color: Colors.red)),
    );
  }
}

// Widget to show recent service orders in dashboard
class _RecentOrdersList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordersAsync = ref.watch(serviceOrdersProvider);
    return ordersAsync.when(
      data: (orders) {
        final recent = orders.take(5).toList();
        if (recent.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text('Nenhuma OS registrada',
                  style: TextStyle(color: Colors.white54)),
            ),
          );
        }
        return Column(
          children: recent.map((o) => _RecentOrderTile(order: o)).toList(),
        );
      },
      loading: () => const SizedBox(
          height: 60,
          child: Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)))),
      error: (e, _) =>
          Text('Erro: $e', style: const TextStyle(color: Colors.red)),
    );
  }
}

class _RecentOrderTile extends StatelessWidget {
  final dynamic order;

  const _RecentOrderTile({required this.order});

  Color _statusColor(ServiceOrderStatusEnum status) {
    switch (status) {
      case ServiceOrderStatusEnum.draft:
        return const Color(0xFF64748B);
      case ServiceOrderStatusEnum.diagnostico:
        return const Color(0xFF38BDF8);
      case ServiceOrderStatusEnum.aguardandoAprovacao:
        return const Color(0xFFF59E0B);
      case ServiceOrderStatusEnum.emExecucao:
        return const Color(0xFF8B5CF6);
      case ServiceOrderStatusEnum.pronto:
        return const Color(0xFF10B981);
      case ServiceOrderStatusEnum.entregue:
        return const Color(0xFF6EE7B7);
      case ServiceOrderStatusEnum.cancelado:
        return const Color(0xFFEF4444);
    }
  }

  String _statusLabel(ServiceOrderStatusEnum status) {
    switch (status) {
      case ServiceOrderStatusEnum.draft:
        return 'Rascunho';
      case ServiceOrderStatusEnum.diagnostico:
        return 'Diagnóstico';
      case ServiceOrderStatusEnum.aguardandoAprovacao:
        return 'Aguard. Aprovação';
      case ServiceOrderStatusEnum.emExecucao:
        return 'Em Execução';
      case ServiceOrderStatusEnum.pronto:
        return 'Pronto';
      case ServiceOrderStatusEnum.entregue:
        return 'Entregue';
      case ServiceOrderStatusEnum.cancelado:
        return 'Cancelado';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(order.status);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  order.problemDescription,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                Text(
                  'ID: ${order.id.substring(0, 8)}...',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withOpacity(0.5)),
            ),
            child: Text(
              _statusLabel(order.status),
              style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
