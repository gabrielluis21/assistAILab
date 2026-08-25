import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../service_orders/service_order_entity.dart';
import '../application/customer_service_orders_provider.dart';
import '../application/customer_quote_decision_provider.dart';

class CustomerServiceOrderDetailPage extends ConsumerWidget {
  const CustomerServiceOrderDetailPage({
    super.key,
    required this.orderId,
  });

  final String orderId;

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) {
    final orderAsync = ref.watch(
      customerServiceOrderByIdProvider(
        orderId,
      ),
    );

    return ColoredBox(
      color: const Color(0xFF0F172A),
      child: SafeArea(
        child: orderAsync.when(
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ),
          error: (error, stackTrace) => const _ErrorState(),
          data: (order) {
            if (order == null) {
              return const _NotFoundState();
            }

            return _OrderDetailContent(
              order: order,
            );
          },
        ),
      ),
    );
  }
}

class _OrderDetailContent extends StatelessWidget {
  const _OrderDetailContent({
    required this.order,
  });

  final ServiceOrderEntity order;

  @override
  Widget build(BuildContext context) {
    final status = _statusInfo(
      order.status,
    );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                'OS #${order.friendlyId ?? '-'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: status.color.withValues(
                  alpha: 0.15,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                status.label,
                style: TextStyle(
                  color: status.color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _DetailCard(
          title: 'Problema relatado',
          icon: Icons.report_problem_outlined,
          child: Text(
            order.problemDescription,
            style: const TextStyle(
              color: Colors.white70,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 14),
        _DetailCard(
          title: 'Diagnóstico',
          icon: Icons.search,
          child: Text(
            _nullableText(
              order.diagnosis,
            ),
            style: const TextStyle(
              color: Colors.white70,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 14),
        _DetailCard(
          title: 'Solução',
          icon: Icons.handyman_outlined,
          child: Text(
            _nullableText(
              order.solution,
            ),
            style: const TextStyle(
              color: Colors.white70,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 14),
        _DetailCard(
          title: 'Valor',
          icon: Icons.payments_outlined,
          child: Text(
            _formatCurrency(
              order.totalAmount,
            ),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 14),
        _DetailCard(
          title: 'Última atualização',
          icon: Icons.schedule,
          child: Text(
            _formatUpdatedAt(
              order.updatedAt,
            ),
            style: const TextStyle(
              color: Colors.white70,
            ),
          ),
        ),
        if (order.status == ServiceOrderStatusEnum.aguardandoAprovacao) ...[
          const SizedBox(height: 24),
          _QuoteDecisionSection(
            order: order,
          ),
        ],
      ],
    );
  }
}

class _QuoteDecisionSection extends ConsumerWidget {
  const _QuoteDecisionSection({
    required this.order,
  });

  final ServiceOrderEntity order;

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) {
    final decisionState = ref.watch(
      customerQuoteDecisionProvider,
    );

    final isLoading = decisionState.isLoading;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(
            alpha: 0.45,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.pending_actions,
                color: Color(0xFFF59E0B),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Sua aprovação é necessária',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Confira as informações e o valor da ordem de serviço antes de responder.',
            style: TextStyle(
              color: Colors.white60,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isLoading
                  ? null
                  : () {
                      _confirmApproval(
                        context,
                        ref,
                        order,
                      );
                    },
              icon: isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(
                      Icons.check_circle_outline,
                    ),
              label: const Text(
                'Aprovar orçamento',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(
                  vertical: 15,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: isLoading
                  ? null
                  : () {
                      _showRejectDialog(
                        context,
                        ref,
                        order,
                      );
                    },
              icon: const Icon(
                Icons.close,
              ),
              label: const Text(
                'Não aprovar',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(
                  color: Colors.redAccent,
                ),
                padding: const EdgeInsets.symmetric(
                  vertical: 15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmApproval(
    BuildContext context,
    WidgetRef ref,
    ServiceOrderEntity order,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(
            'Aprovar orçamento?',
          ),
          content: Text(
            'Você confirma a aprovação da OS '
            '#${order.friendlyId ?? '-'} '
            'no valor de '
            '${_formatCurrency(order.totalAmount)}?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(
                  dialogContext,
                ).pop(false);
              },
              child: const Text(
                'Voltar',
              ),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(
                  dialogContext,
                ).pop(true);
              },
              child: const Text(
                'Confirmar aprovação',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) {
      return;
    }

    try {
      await ref
          .read(
            customerQuoteDecisionProvider.notifier,
          )
          .submit(
            serviceOrderId: order.id,
            decision: CustomerQuoteDecision.approve,
          );

      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Orçamento aprovado com sucesso.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _decisionErrorText(error),
          ),
        ),
      );
    }
  }

  Future<void> _showRejectDialog(
    BuildContext context,
    WidgetRef ref,
    ServiceOrderEntity order,
  ) async {
    var reason = '';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text(
            'Não aprovar orçamento',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Você pode informar o motivo da recusa.',
                ),
                const SizedBox(height: 14),
                TextFormField(
                  maxLength: 1000,
                  maxLines: 4,
                  onChanged: (value) {
                    reason = value;
                  },
                  decoration: const InputDecoration(
                    labelText: 'Motivo (opcional)',
                    hintText: 'Ex.: valor acima do esperado',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(
                  dialogContext,
                ).pop(false);
              },
              child: const Text(
                'Voltar',
              ),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(
                  dialogContext,
                ).pop(true);
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              child: const Text(
                'Confirmar recusa',
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) {
      return;
    }

    final normalizedReason = reason.trim();

    try {
      await ref
          .read(
            customerQuoteDecisionProvider.notifier,
          )
          .submit(
            serviceOrderId: order.id,
            decision: CustomerQuoteDecision.reject,
            reason: normalizedReason.isEmpty ? null : normalizedReason,
          );

      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Resposta enviada com sucesso.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _decisionErrorText(error),
          ),
        ),
      );
    }
  }

  String _decisionErrorText(
    Object error,
  ) {
    if (error is CustomerQuoteDecisionException) {
      return error.message;
    }

    return 'Não foi possível enviar sua resposta. Tente novamente.';
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: const Color(0xFF38BDF8),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Não foi possível carregar esta ordem de serviço.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white70,
          ),
        ),
      ),
    );
  }
}

class _NotFoundState extends StatelessWidget {
  const _NotFoundState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 56,
              color: Colors.white24,
            ),
            SizedBox(height: 16),
            Text(
              'Esta ordem de serviço não está mais disponível.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
              ),
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

String _nullableText(
  String? value,
) {
  if (value == null || value.trim().isEmpty) {
    return 'Ainda não informado.';
  }

  return value.trim();
}

String _formatCurrency(
  double value,
) {
  return 'R\$ ${value.toStringAsFixed(2).replaceAll('.', ',')}';
}

String _formatUpdatedAt(
  String value,
) {
  final parsed = DateTime.tryParse(value);

  if (parsed == null) {
    return value;
  }

  final local = parsed.toLocal();

  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  final year = local.year.toString();

  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');

  return '$day/$month/$year às $hour:$minute';
}
