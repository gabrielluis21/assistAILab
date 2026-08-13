import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'equipments_provider.dart';
import 'equipment_entity.dart';
import '../customers/customers_provider.dart';

class EquipmentsPage extends ConsumerWidget {
  const EquipmentsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final equipmentsAsync = ref.watch(equipmentsProvider);
    final customersAsync = ref.watch(customersProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.devices, color: Color(0xFF38BDF8)),
            SizedBox(width: 10),
            Text(
              'Equipamentos',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
            onPressed: () => ref.read(equipmentsProvider.notifier).refresh(),
          ),
        ],
      ),
      body: equipmentsAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
        ),
        error: (err, _) => Center(
          child: Text('Erro: $err', style: const TextStyle(color: Colors.redAccent)),
        ),
        data: (equipments) {
          if (equipments.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.devices_other, size: 64, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  const Text(
                    'Nenhum equipamento cadastrado',
                    style: TextStyle(fontSize: 16, color: Colors.white54),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: equipments.length,
            itemBuilder: (context, index) {
              final eq = equipments[index];
              return _EquipmentCard(equipment: eq);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0284C7),
        onPressed: () => _showCreateEquipmentDialog(context, ref, customersAsync.value ?? []),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'Novo Equipamento',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _showCreateEquipmentDialog(
    BuildContext context,
    WidgetRef ref,
    List<dynamic> customers,
  ) {
    final brandController = TextEditingController();
    final modelController = TextEditingController();
    final typeController = TextEditingController(text: 'Notebook');
    final serialController = TextEditingController();
    final notesController = TextEditingController();
    String? selectedCustomerId = customers.isNotEmpty ? customers.first.id : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              'Novo Equipamento',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
                        prefixIcon: const Icon(Icons.person, color: Color(0xFF38BDF8), size: 20),
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
                      items: customers.map<DropdownMenuItem<String>>((c) {
                        return DropdownMenuItem<String>(
                          value: c.id as String,
                          child: Text(c.name as String, style: const TextStyle(color: Colors.white)),
                        );
                      }).toList(),
                      onChanged: (val) => setState(() => selectedCustomerId = val),
                    ),
                  const SizedBox(height: 12),
                  _buildTextField(typeController, 'Tipo (ex: Smartphone, Notebook) *', Icons.category),
                  const SizedBox(height: 12),
                  _buildTextField(brandController, 'Marca (ex: Apple, Dell) *', Icons.branding_watermark),
                  const SizedBox(height: 12),
                  _buildTextField(modelController, 'Modelo *', Icons.devices),
                  const SizedBox(height: 12),
                  _buildTextField(serialController, 'Nº de Série / IMEI', Icons.qr_code),
                  const SizedBox(height: 12),
                  _buildTextField(notesController, 'Observações', Icons.note, maxLines: 2),
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
                  if (brandController.text.trim().isEmpty ||
                      modelController.text.trim().isEmpty ||
                      typeController.text.trim().isEmpty ||
                      selectedCustomerId == null) {
                    return;
                  }
                  await ref.read(equipmentsProvider.notifier).createEquipment(
                        customerId: selectedCustomerId!,
                        type: typeController.text.trim(),
                        brand: brandController.text.trim(),
                        model: modelController.text.trim(),
                        serialNumber: serialController.text.trim().isEmpty ? null : serialController.text.trim(),
                        notes: notesController.text.trim().isEmpty ? null : notesController.text.trim(),
                      );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Salvar', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    int maxLines = 1,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
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

class _EquipmentCard extends ConsumerWidget {
  final EquipmentEntity equipment;
  const _EquipmentCard({required this.equipment});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0284C7).withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.devices, color: Color(0xFF38BDF8)),
        ),
        title: Text(
          '${equipment.brand} ${equipment.model}',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tipo: ${equipment.type}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
            if (equipment.serialNumber != null)
              Text('S/N: ${equipment.serialNumber}', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
            if (equipment.notes != null)
              Text('Obs: ${equipment.notes}', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: () => ref.read(equipmentsProvider.notifier).deleteEquipment(equipment.id),
        ),
      ),
    );
  }
}
