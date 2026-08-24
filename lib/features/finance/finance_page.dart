import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'payment_entity.dart';
import 'payments_provider.dart';

class FinancePage extends ConsumerWidget {
  const FinancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paymentsAsync = ref.watch(paymentsProvider);
    final summaryAsync = ref.watch(financeSummaryProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Financeiro',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: () => ref.read(paymentsProvider.notifier).refresh(),
            tooltip: 'Atualizar',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0284C7),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Novo Pagamento'),
        onPressed: () => _showCreateDialog(context, ref),
      ),
      body: Column(
        children: [
          // Summary cards
          summaryAsync.when(
            data: (summary) => _buildSummarySection(summary),
            loading: () => const SizedBox(
              height: 120,
              child: Center(
                  child: CircularProgressIndicator(color: Color(0xFF38BDF8))),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Erro ao carregar resumo: $e',
                  style: const TextStyle(color: Colors.red)),
            ),
          ),

          // Payments list
          Expanded(
            child: paymentsAsync.when(
              data: (payments) => payments.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: payments.length,
                      itemBuilder: (context, i) =>
                          _PaymentCard(payment: payments[i]),
                    ),
              loading: () => const Center(
                child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
              ),
              error: (e, _) => Center(
                child:
                    Text('Erro: $e', style: const TextStyle(color: Colors.red)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummarySection(FinanceSummary summary) {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _SummaryCard(
                  label: 'Receita Total',
                  value: 'R\$ ${summary.totalRevenue.toStringAsFixed(2)}',
                  icon: Icons.trending_up,
                  color: const Color(0xFF10B981),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryCard(
                  label: 'Este Mês',
                  value: 'R\$ ${summary.monthRevenue.toStringAsFixed(2)}',
                  icon: Icons.calendar_month,
                  color: const Color(0xFF38BDF8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryCard(
                  label: 'Pendente',
                  value: 'R\$ ${summary.pendingAmount.toStringAsFixed(2)}',
                  icon: Icons.hourglass_empty,
                  color: const Color(0xFFF59E0B),
                ),
              ),
            ],
          ),
          if (summary.revenueByMethod.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildMethodBreakdown(summary.revenueByMethod),
          ],
        ],
      ),
    );
  }

  Widget _buildMethodBreakdown(Map<PaymentMethod, double> byMethod) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Receita por Método',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: byMethod.entries.map((entry) {
              return Chip(
                backgroundColor: const Color(0xFF0F172A),
                label: Text(
                  '${entry.key.label}: R\$ ${entry.value.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined,
              size: 64, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 16),
          Text(
            'Nenhum pagamento registrado',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Registre o primeiro pagamento usando o botão +',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => _CreatePaymentDialog(ref: ref),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryCard({
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
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentCard extends ConsumerWidget {
  final PaymentEntity payment;

  const _PaymentCard({required this.payment});

  Color get _statusColor {
    switch (payment.status) {
      case PaymentStatus.confirmed:
        return const Color(0xFF10B981);
      case PaymentStatus.pending:
        return const Color(0xFFF59E0B);
      case PaymentStatus.cancelled:
        return const Color(0xFFEF4444);
      case PaymentStatus.refunded:
        return const Color(0xFF8B5CF6);
    }
  }

  IconData get _methodIcon {
    switch (payment.method) {
      case PaymentMethod.pix:
        return Icons.qr_code;
      case PaymentMethod.cartaoCredito:
        return Icons.credit_card;
      case PaymentMethod.cartaoDebito:
        return Icons.credit_card_outlined;
      case PaymentMethod.dinheiro:
        return Icons.payments;
      case PaymentMethod.transferencia:
        return Icons.swap_horiz;
      case PaymentMethod.boleto:
        return Icons.receipt;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(_methodIcon, color: _statusColor, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        payment.method.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        'OS: ${payment.serviceOrderId.substring(0, 8)}...',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'R\$ ${payment.amount.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: _statusColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _statusColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        payment.status.label,
                        style: TextStyle(color: _statusColor, fontSize: 10),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (payment.notes != null && payment.notes!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                payment.notes!,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
            if (payment.status == PaymentStatus.pending) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF10B981),
                        side: const BorderSide(color: Color(0xFF10B981)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text('Confirmar',
                          style: TextStyle(fontSize: 12)),
                      onPressed: () => ref
                          .read(paymentsProvider.notifier)
                          .confirmPayment(payment.id),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFEF4444),
                        side: const BorderSide(color: Color(0xFFEF4444)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('Cancelar',
                          style: TextStyle(fontSize: 12)),
                      onPressed: () => ref
                          .read(paymentsProvider.notifier)
                          .cancelPayment(payment.id),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CreatePaymentDialog extends ConsumerStatefulWidget {
  final WidgetRef ref;

  const _CreatePaymentDialog({required this.ref});

  @override
  ConsumerState<_CreatePaymentDialog> createState() =>
      _CreatePaymentDialogState();
}

class _CreatePaymentDialogState extends ConsumerState<_CreatePaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _soIdCtrl = TextEditingController();
  final _customerIdCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  PaymentMethod _method = PaymentMethod.pix;
  bool _saving = false;

  @override
  void dispose() {
    _soIdCtrl.dispose();
    _customerIdCtrl.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(paymentsProvider.notifier).createPayment(
            serviceOrderId: _soIdCtrl.text.trim(),
            customerId: _customerIdCtrl.text.trim(),
            amount: double.parse(_amountCtrl.text.trim()),
            method: _method,
            notes:
                _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 480,
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Registrar Pagamento',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              _field(_soIdCtrl, 'ID da Ordem de Serviço', required: true),
              const SizedBox(height: 12),
              _field(_customerIdCtrl, 'ID do Cliente', required: true),
              const SizedBox(height: 12),
              _field(
                _amountCtrl,
                'Valor (R\$)',
                required: true,
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Campo obrigatório';
                  if (double.tryParse(v) == null) return 'Valor inválido';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PaymentMethod>(
                value: _method,
                dropdownColor: const Color(0xFF0F172A),
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Método de Pagamento',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF334155)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF334155)),
                  ),
                ),
                items: PaymentMethod.values
                    .map((m) => DropdownMenuItem(
                          value: m,
                          child: Text(m.label),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _method = v!),
              ),
              const SizedBox(height: 12),
              _field(_notesCtrl, 'Observações (opcional)'),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar',
                        style: TextStyle(color: Colors.white54)),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Salvar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    bool required = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: ctrl,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white60),
        filled: true,
        fillColor: const Color(0xFF0F172A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
      ),
      validator: validator ??
          (v) {
            if (required && (v == null || v.isEmpty))
              return 'Campo obrigatório';
            return null;
          },
    );
  }
}
