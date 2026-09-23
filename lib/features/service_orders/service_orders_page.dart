import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/money/money_minor.dart';
import 'service_orders_provider.dart';
import 'service_order_entity.dart';
import 'service_order_detail_page.dart';
import '../auth/application/auth_provider.dart';
import '../customers/customer_entity.dart';
import '../customers/customers_provider.dart';
import '../equipment/equipment_entity.dart';
import '../equipment/equipments_provider.dart';

class ServiceOrdersPage extends ConsumerWidget {
  const ServiceOrdersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordersAsync = ref.watch(serviceOrdersProvider);
    final customersAsync = ref.watch(customersProvider);
    final equipmentsAsync = ref.watch(equipmentsProvider);
    final canCreate = canCreateServiceOrder(ref.watch(currentUserProvider));

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.build_circle, color: Color(0xFF38BDF8)),
            SizedBox(width: 10),
            Text(
              'Ordens de Serviço',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync, color: Color(0xFF38BDF8)),
            onPressed: () => ref.read(serviceOrdersProvider.notifier).refresh(),
            tooltip: 'Sincronizar',
          ),
        ],
      ),
      body: ordersAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
        ),
        error: (err, _) => Center(
          child: Text('Erro: $err',
              style: const TextStyle(color: Colors.redAccent)),
        ),
        data: (orders) {
          if (orders.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.assignment_outlined,
                      size: 64, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  const Text(
                    'Nenhuma ordem de serviço',
                    style: TextStyle(fontSize: 16, color: Colors.white54),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            itemBuilder: (context, index) =>
                _ServiceOrderCard(order: orders[index]),
          );
        },
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              key: const Key('create_service_order_fab'),
              backgroundColor: const Color(0xFF0284C7),
              onPressed: () => _showCreateOrderDialog(
                context,
                ref,
                customersAsync.value ?? [],
                equipmentsAsync.value ?? [],
              ),
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text(
                'Nova OS',
                style:
                    TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            )
          : null,
    );
  }

  void _showCreateOrderDialog(
    BuildContext context,
    WidgetRef ref,
    List<CustomerEntity> customers,
    List<EquipmentEntity> equipments,
  ) {
    final descController = TextEditingController();
    String? selectedCustomerId =
        customers.isNotEmpty ? customers.first.id : null;
    final initialEquipments = equipments
        .where((equipment) => equipment.customerId == selectedCustomerId)
        .toList(growable: false);
    String? selectedEquipmentId =
        initialEquipments.isNotEmpty ? initialEquipments.first.id : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          final filteredEquipments = selectedCustomerId != null
              ? equipments
                  .where((e) => e.customerId == selectedCustomerId)
                  .toList()
              : equipments;

          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              'Nova Ordem de Serviço',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (customers.isNotEmpty)
                    DropdownButtonFormField<String>(
                      value: selectedCustomerId,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Cliente *',
                        labelStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(Icons.person,
                            color: Color(0xFF38BDF8), size: 20),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFF334155)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFF38BDF8)),
                        ),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                      ),
                      items: customers.map<DropdownMenuItem<String>>((c) {
                        return DropdownMenuItem<String>(
                          value: c.id,
                          child: Text(c.name,
                              style: const TextStyle(color: Colors.white)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setState(() {
                          selectedCustomerId = val;
                          final newFiltered = equipments
                              .where((e) => e.customerId == val)
                              .toList();
                          selectedEquipmentId = newFiltered.isNotEmpty
                              ? newFiltered.first.id
                              : null;
                        });
                      },
                    ),
                  const SizedBox(height: 12),
                  if (filteredEquipments.isNotEmpty)
                    DropdownButtonFormField<String>(
                      value: selectedEquipmentId,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Equipamento *',
                        labelStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(Icons.devices,
                            color: Color(0xFF38BDF8), size: 20),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFF334155)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFF38BDF8)),
                        ),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                      ),
                      items:
                          filteredEquipments.map<DropdownMenuItem<String>>((e) {
                        return DropdownMenuItem<String>(
                          value: e.id,
                          child: Text('${e.brand} ${e.model}',
                              style: const TextStyle(color: Colors.white)),
                        );
                      }).toList(),
                      onChanged: (val) =>
                          setState(() => selectedEquipmentId = val),
                    )
                  else
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        'Nenhum equipamento cadastrado para este cliente. Cadastre na aba Equipamentos.',
                        style: TextStyle(color: Colors.amber, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: descController,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: 'Descrição do Problema *',
                      labelStyle: const TextStyle(color: Colors.white54),
                      prefixIcon: const Icon(Icons.description,
                          color: Color(0xFF38BDF8), size: 20),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar',
                    style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                key: const Key('create_service_order_submit'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7)),
                onPressed:
                    selectedCustomerId == null || selectedEquipmentId == null
                        ? null
                        : () async {
                            final description = descController.text.trim();
                            if (description.isEmpty) return;
                            await ref
                                .read(serviceOrdersProvider.notifier)
                                .createOrder(
                                  customerId: selectedCustomerId!,
                                  equipmentId: selectedEquipmentId!,
                                  problemDescription: description,
                                );
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                child: const Text('Criar OS',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ServiceOrderCard extends ConsumerWidget {
  final ServiceOrderEntity order;
  const _ServiceOrderCard({required this.order});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = allowedTransitionsFor(order.status);

    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _statusBorderColor(order.status)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      'OS #${order.friendlyId ?? '—'}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF38BDF8),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.open_in_new,
                          color: Color(0xFF38BDF8), size: 18),
                      tooltip: 'Abrir Detalhes / Peças',
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (ctx) =>
                                ServiceOrderDetailPage(order: order),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                _StatusBadge(status: order.status),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              order.problemDescription,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            if (order.totalAmount.minorUnits > 0) ...[
              const SizedBox(height: 8),
              Text(
                'Total: ${formatMoneyMinor(order.totalAmount)}',
                style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF4ADE80),
                    fontWeight: FontWeight.w600),
              ),
            ],
            if (allowed.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(color: Color(0xFF334155)),
              const SizedBox(height: 4),
              const Text('Avançar para:',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: allowed
                    .map((next) => ActionChip(
                          backgroundColor: const Color(0xFF0F172A),
                          side: const BorderSide(color: Color(0xFF334155)),
                          label: Text(
                            next.toDbString().replaceAll('_', ' '),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white70),
                          ),
                          onPressed: () async {
                            final ok = await ref
                                .read(serviceOrdersProvider.notifier)
                                .updateStatus(order.id, next);
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content:
                                        Text('Transição de status inválida')),
                              );
                            }
                          },
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _statusBorderColor(ServiceOrderStatusEnum status) {
    switch (status) {
      case ServiceOrderStatusEnum.draft:
        return const Color(0xFF334155);
      case ServiceOrderStatusEnum.diagnostico:
        return const Color(0xFFF59E0B);
      case ServiceOrderStatusEnum.aguardandoAprovacao:
        return const Color(0xFF818CF8);
      case ServiceOrderStatusEnum.aguardandoReaprovacao:
        return const Color(0xFFA78BFA);
      case ServiceOrderStatusEnum.emExecucao:
        return const Color(0xFF3B82F6);
      case ServiceOrderStatusEnum.pronto:
        return const Color(0xFF22C55E);
      case ServiceOrderStatusEnum.entregue:
        return const Color(0xFF4ADE80);
      case ServiceOrderStatusEnum.cancelado:
        return const Color(0xFFEF4444);
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final ServiceOrderStatusEnum status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (status) {
      ServiceOrderStatusEnum.draft => (
          Colors.grey.shade800,
          Colors.white,
          'DRAFT',
        ),
      ServiceOrderStatusEnum.diagnostico => (
          const Color(0xFFFEF3C7),
          const Color(0xFFD97706),
          'DIAGNÓSTICO'
        ),
      ServiceOrderStatusEnum.aguardandoAprovacao => (
          const Color(0xFFEDE9FE),
          const Color(0xFF7C3AED),
          'AG. APROVAÇÃO'
        ),
      ServiceOrderStatusEnum.aguardandoReaprovacao => (
          const Color(0xFFF3E8FF),
          const Color(0xFF7E22CE),
          'AG. REAPROVAÇÃO'
        ),
      ServiceOrderStatusEnum.emExecucao => (
          const Color(0xFFDBEAFE),
          const Color(0xFF2563EB),
          'EM EXECUÇÃO'
        ),
      ServiceOrderStatusEnum.pronto => (
          const Color(0xFFDCFCE7),
          const Color(0xFF16A34A),
          'PRONTO'
        ),
      ServiceOrderStatusEnum.entregue => (
          const Color(0xFFBBF7D0),
          const Color(0xFF15803D),
          'ENTREGUE'
        ),
      ServiceOrderStatusEnum.cancelado => (
          const Color(0xFFFEE2E2),
          const Color(0xFFDC2626),
          'CANCELADO'
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style:
              TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg)),
    );
  }
}
