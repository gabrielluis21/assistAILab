import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../service_orders/service_order_entity.dart';
import '../application/customer_service_orders_provider.dart';

class CustomerServiceOrdersPage extends ConsumerWidget {
  const CustomerServiceOrdersPage({
    super.key,
    this.onOrderSelected,
  });

  final ValueChanged<ServiceOrderEntity>? onOrderSelected;

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) {
    final ordersAsync = ref.watch(
      customerServiceOrdersProvider,
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await ref
                .read(
                  customerServiceOrdersProvider.notifier,
                )
                .refreshSilently();
          },
          child: ordersAsync.when(
            loading: () => const _LoadingState(),
            error: (error, stackTrace) => _ErrorState(
              onRetry: () {
                ref
                    .read(
                      customerServiceOrdersProvider.notifier,
                    )
                    .refresh();
              },
            ),
            data: (orders) {
              if (orders.isEmpty) {
                return const _EmptyState();
              }

              return ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                itemCount: orders.length + 1,
                separatorBuilder: (context, index) {
                  if (index == 0) {
                    return const SizedBox(
                      height: 18,
                    );
                  }

                  return const SizedBox(
                    height: 12,
                  );
                },
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Minhas Ordens de Serviço',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Acompanhe seus atendimentos e reparos.',
                          style: TextStyle(
                            color: Colors.white60,
                          ),
                        ),
                      ],
                    );
                  }

                  final order = orders[index - 1];

                  return _ServiceOrderCard(
                    order: order,
                    onTap: () {
                      onOrderSelected?.call(order);
                    },
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ServiceOrderCard extends StatelessWidget {
  const _ServiceOrderCard({
    required this.order,
    required this.onTap,
  });

  final ServiceOrderEntity order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final statusInfo = _statusInfo(order.status);

    return Material(
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFF334155),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'OS #${order.friendlyId ?? '-'}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: statusInfo.color.withValues(
                        alpha: 0.15,
                      ),
                      borderRadius: BorderRadius.circular(
                        20,
                      ),
                    ),
                    child: Text(
                      statusInfo.label,
                      style: TextStyle(
                        color: statusInfo.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                order.problemDescription,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(
                    Icons.payments_outlined,
                    size: 18,
                    color: Colors.white38,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _formatCurrency(
                      order.totalAmount,
                    ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.white38,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: const [
        SizedBox(height: 120),
        Icon(
          Icons.build_circle_outlined,
          size: 64,
          color: Colors.white24,
        ),
        SizedBox(height: 20),
        Text(
          'Nenhuma ordem de serviço',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 8),
        Text(
          'Quando houver um atendimento vinculado à sua conta, ele aparecerá aqui.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white54,
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.onRetry,
  });

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 56,
              color: Colors.redAccent,
            ),
            const SizedBox(height: 16),
            const Text(
              'Não foi possível carregar suas ordens de serviço.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Tentar novamente'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusInfo {
  const _StatusInfo(
    this.label,
    this.color,
  );

  final String label;
  final Color color;
}

_StatusInfo _statusInfo(
  ServiceOrderStatusEnum status,
) {
  switch (status) {
    case ServiceOrderStatusEnum.draft:
      return const _StatusInfo(
        'Rascunho',
        Colors.blueGrey,
      );

    case ServiceOrderStatusEnum.diagnostico:
      return const _StatusInfo(
        'Em diagnóstico',
        Colors.blue,
      );

    case ServiceOrderStatusEnum.aguardandoAprovacao:
      return const _StatusInfo(
        'Aguardando aprovação',
        Colors.orange,
      );

    case ServiceOrderStatusEnum.emExecucao:
      return const _StatusInfo(
        'Em execução',
        Colors.indigo,
      );

    case ServiceOrderStatusEnum.pronto:
      return const _StatusInfo(
        'Pronto',
        Colors.green,
      );

    case ServiceOrderStatusEnum.entregue:
      return const _StatusInfo(
        'Entregue',
        Colors.teal,
      );

    case ServiceOrderStatusEnum.cancelado:
      return const _StatusInfo(
        'Cancelado',
        Colors.red,
      );
  }
}

String _formatCurrency(
  double value,
) {
  return 'R\$ ${value.toStringAsFixed(2).replaceAll('.', ',')}';
}
