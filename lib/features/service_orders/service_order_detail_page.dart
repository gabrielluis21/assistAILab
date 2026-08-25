import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'service_order_entity.dart';
import 'service_order_item_entity.dart';
import 'service_order_details_provider.dart';
import '../parts/parts_provider.dart';

import '../auth/application/auth_provider.dart';
import 'printing/service_order_pdf_preview_page.dart';

class ServiceOrderDetailPage extends ConsumerStatefulWidget {
  final ServiceOrderEntity order;
  const ServiceOrderDetailPage({super.key, required this.order});

  @override
  ConsumerState<ServiceOrderDetailPage> createState() =>
      _ServiceOrderDetailPageState();
}

class _ServiceOrderDetailPageState
    extends ConsumerState<ServiceOrderDetailPage> {
  late TextEditingController _diagnosisController;
  late TextEditingController _solutionController;

  @override
  void initState() {
    super.initState();
    _diagnosisController =
        TextEditingController(text: widget.order.diagnosis ?? '');
    _solutionController =
        TextEditingController(text: widget.order.solution ?? '');
  }

  @override
  void dispose() {
    _diagnosisController.dispose();
    _solutionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(
      authStateProvider,
    );

    final currentUser = authState.valueOrNull;

    final role = currentUser?.role.trim().toUpperCase();

    final canPrint = role == 'ADMIN' || role == 'TECHNICIAN';

    final itemsAsync = ref.watch(serviceOrderItemsProvider(widget.order.id));
    final partsAsync = ref.watch(partsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(
          'Detalhes da OS #${widget.order.friendlyId ?? '—'}',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        actions: [
          if (canPrint)
            IconButton(
              tooltip: 'Visualizar / Imprimir OS',
              icon: const Icon(
                Icons.print_outlined,
                color: Colors.white,
              ),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => ServiceOrderPdfPreviewPage(
                      order: widget.order,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status & Summary Card
            Card(
              color: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFF334155)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Status: ${widget.order.status.toDbString()}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                        Text(
                          'Total: R\$ ${widget.order.totalAmount.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4ADE80),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('Descrição do Problema:',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(widget.order.problemDescription,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Technical Diagnosis & Solution Section
            Card(
              color: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFF334155)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.assignment,
                            color: Color(0xFF38BDF8), size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Laudo Técnico & Solução',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _diagnosisController,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Diagnóstico Técnico'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _solutionController,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Solução Aplicada'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Items (Parts & Services) Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.build, color: Color(0xFF38BDF8), size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Peças & Mão de Obra',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7)),
                  icon: const Icon(Icons.add, color: Colors.white, size: 18),
                  label: const Text('Adicionar Item',
                      style: TextStyle(color: Colors.white)),
                  onPressed: () =>
                      _showAddItemDialog(context, partsAsync.value ?? []),
                ),
              ],
            ),
            const SizedBox(height: 12),

            itemsAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: Color(0xFF38BDF8))),
              error: (err, _) => Text('Erro ao carregar itens: $err',
                  style: const TextStyle(color: Colors.redAccent)),
              data: (items) {
                if (items.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: const Center(
                      child: Text(
                        'Nenhuma peça ou serviço adicionado a esta OS ainda.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  );
                }

                return Column(
                  children: items
                      .map((item) =>
                          _ItemTile(item: item, orderId: widget.order.id))
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
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
    );
  }

  void _showAddItemDialog(BuildContext context, List<dynamic> availableParts) {
    final descController = TextEditingController();
    final qtyController = TextEditingController(text: '1');
    final priceController = TextEditingController(text: '0.00');
    String? selectedPartId;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              'Adicionar Peça / Serviço',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (availableParts.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      value: selectedPartId,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Selecionar do Estoque'),
                      items: availableParts.map<DropdownMenuItem<String>>((p) {
                        return DropdownMenuItem<String>(
                          value: p.id as String,
                          child: Text('${p.name} (R\$ ${p.price})',
                              style: const TextStyle(color: Colors.white)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        final found = availableParts
                            .firstWhere((p) => p.id == val, orElse: () => null);
                        if (found != null) {
                          setState(() {
                            selectedPartId = val;
                            descController.text = found.name;
                            priceController.text =
                                found.price.toStringAsFixed(2);
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    controller: descController,
                    style: const TextStyle(color: Colors.white),
                    decoration:
                        _inputDecoration('Descrição (Peça ou Serviço) *'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: qtyController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Qtd *'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: priceController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Valor Unit. (R\$) *'),
                        ),
                      ),
                    ],
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
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7)),
                onPressed: () async {
                  if (descController.text.trim().isEmpty) return;
                  final qty = int.tryParse(qtyController.text.trim()) ?? 1;
                  final price = double.tryParse(
                          priceController.text.trim().replaceAll(',', '.')) ??
                      0.0;

                  await ref
                      .read(serviceOrderItemsProvider(widget.order.id).notifier)
                      .addItem(
                        serviceOrderId: widget.order.id,
                        partId: selectedPartId,
                        description: descController.text.trim(),
                        quantity: qty,
                        unitPrice: price,
                      );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Adicionar',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ItemTile extends ConsumerWidget {
  final ServiceOrderItemEntity item;
  final String orderId;
  const _ItemTile({required this.item, required this.orderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      child: ListTile(
        title: Text(item.description,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text(
          '${item.quantity}x  R\$ ${item.unitPrice.toStringAsFixed(2)}',
          style: const TextStyle(color: Colors.white70),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'R\$ ${item.totalPrice.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: Color(0xFF4ADE80),
                  fontWeight: FontWeight.bold,
                  fontSize: 15),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.redAccent, size: 20),
              onPressed: () {
                ref
                    .read(serviceOrderItemsProvider(orderId).notifier)
                    .deleteItem(item.id, orderId);
              },
            ),
          ],
        ),
      ),
    );
  }
}
