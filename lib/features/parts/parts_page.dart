import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'parts_provider.dart';
import 'part_entity.dart';

class PartsPage extends ConsumerWidget {
  const PartsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final partsAsync = ref.watch(partsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.inventory_2, color: Color(0xFF38BDF8)),
            SizedBox(width: 10),
            Text(
              'Peças & Estoque',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
            onPressed: () => ref.read(partsProvider.notifier).refresh(),
          ),
        ],
      ),
      body: partsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
        ),
        error: (err, _) => Center(
          child: Text('Erro: $err', style: const TextStyle(color: Colors.redAccent)),
        ),
        data: (parts) {
          if (parts.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inventory, size: 64, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  const Text(
                    'Nenhuma peça cadastrada no estoque',
                    style: TextStyle(fontSize: 16, color: Colors.white54),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: parts.length,
            itemBuilder: (context, index) {
              final part = parts[index];
              return _PartCard(part: part);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0284C7),
        onPressed: () => _showCreatePartDialog(context, ref),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'Nova Peça',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _showCreatePartDialog(BuildContext context, WidgetRef ref) {
    final nameController = TextEditingController();
    final skuController = TextEditingController();
    final priceController = TextEditingController();
    final costController = TextEditingController();
    final stockController = TextEditingController(text: '1');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Nova Peça / Componente',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTextField(nameController, 'Nome do Item *', Icons.label),
              const SizedBox(height: 12),
              _buildTextField(skuController, 'SKU / Código *', Icons.qr_code_scanner),
              const SizedBox(height: 12),
              _buildTextField(priceController, 'Preço de Venda (R\$) *', Icons.attach_money, keyboardType: TextInputType.number),
              const SizedBox(height: 12),
              _buildTextField(costController, 'Preço de Custo (R\$)', Icons.money_off, keyboardType: TextInputType.number),
              const SizedBox(height: 12),
              _buildTextField(stockController, 'Qtd em Estoque *', Icons.warehouse, keyboardType: TextInputType.number),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
            onPressed: () async {
              if (nameController.text.trim().isEmpty ||
                  skuController.text.trim().isEmpty ||
                  priceController.text.trim().isEmpty) {
                return;
              }
              final price = double.tryParse(priceController.text.trim().replaceAll(',', '.')) ?? 0.0;
              final cost = double.tryParse(costController.text.trim().replaceAll(',', '.')) ?? 0.0;
              final stock = int.tryParse(stockController.text.trim()) ?? 0;

              await ref.read(partsProvider.notifier).createPart(
                    name: nameController.text.trim(),
                    sku: skuController.text.trim(),
                    price: price,
                    costPrice: cost,
                    stockQuantity: stock,
                  );
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Salvar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        prefixIcon: Icon(icon, color: const Color(0xFF38BDF8), size: 20),
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
    );
  }
}

class _PartCard extends ConsumerWidget {
  final PartEntity part;
  const _PartCard({required this.part});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLowStock = part.stockQuantity <= 2;

    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isLowStock ? Colors.amber.shade700 : const Color(0xFF334155),
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0284C7).withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.build, color: Color(0xFF38BDF8)),
        ),
        title: Text(
          part.name,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SKU: ${part.sku}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
            Row(
              children: [
                Text(
                  'Preço: R\$ ${part.price.toStringAsFixed(2)}',
                  style: const TextStyle(color: Color(0xFF4ADE80), fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isLowStock ? Colors.amber.withOpacity(0.2) : const Color(0xFF334155),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Estoque: ${part.stockQuantity}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isLowStock ? Colors.amber : Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () => ref.read(partsProvider.notifier).deletePart(part.id),
        ),
      ),
    );
  }
}
