import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'equipment_entity.dart';
import 'equipments_provider.dart';
import 'pre_acquisition_entity.dart';
import 'pre_acquisitions_provider.dart';

class PreAcquisitionsPage extends ConsumerWidget {
  const PreAcquisitionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preAcquisitions = ref.watch(preAcquisitionsProvider);
    final equipments = ref.watch(equipmentsProvider);
    final equipmentById = {
      for (final equipment in equipments.value ?? const <EquipmentEntity>[])
        equipment.id: equipment,
    };
    final eligibleEquipments = equipmentById.values
        .where(
          (equipment) =>
              equipment.ownerType == EquipmentOwnerType.customer &&
              equipment.customerId != null,
        )
        .toList(growable: false);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Pré-aquisições',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: () =>
                ref.read(preAcquisitionsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
          ),
        ],
      ),
      body: preAcquisitions.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
        ),
        error: (error, _) => Center(
          child: Text(
            'Erro: $error',
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
        data: (records) {
          if (records.isEmpty) {
            return const Center(
              child: Text(
                'Nenhuma pré-aquisição local',
                style: TextStyle(color: Colors.white54),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: records.length,
            itemBuilder: (context, index) {
              final record = records[index];
              return _PreAcquisitionCard(
                preAcquisition: record,
                equipment: equipmentById[record.equipmentId],
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF0284C7),
        onPressed: eligibleEquipments.isEmpty
            ? null
            : () => showDialog<void>(
                  context: context,
                  builder: (_) => _CreatePreAcquisitionDialog(
                    equipments: eligibleEquipments,
                  ),
                ),
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'Nova pré-aquisição',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _CreatePreAcquisitionDialog extends ConsumerStatefulWidget {
  const _CreatePreAcquisitionDialog({required this.equipments});

  final List<EquipmentEntity> equipments;

  @override
  ConsumerState<_CreatePreAcquisitionDialog> createState() =>
      _CreatePreAcquisitionDialogState();
}

class _CreatePreAcquisitionDialogState
    extends ConsumerState<_CreatePreAcquisitionDialog> {
  late String _equipmentId;
  late DateTime _evaluationDeadline;
  final _serviceOrderController = TextEditingController();
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _equipmentId = widget.equipments.first.id;
    _evaluationDeadline = DateTime.now().add(const Duration(days: 7));
  }

  @override
  void dispose() {
    _serviceOrderController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: const Text(
        'Nova pré-aquisição',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _equipmentId,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white),
              decoration: _decoration('Equipment', Icons.devices),
              items: widget.equipments
                  .map(
                    (equipment) => DropdownMenuItem(
                      value: equipment.id,
                      child: Text('${equipment.brand} ${equipment.model}'),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) setState(() => _equipmentId = value);
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _serviceOrderController,
              style: const TextStyle(color: Colors.white),
              decoration: _decoration(
                'Service Order ID (opcional)',
                Icons.receipt_long,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: _decoration(
                'Valor ofertado em centavos (opcional)',
                Icons.payments_outlined,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesController,
              maxLines: 3,
              style: const TextStyle(color: Colors.white),
              decoration: _decoration('Observações', Icons.notes),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.event,
                color: Color(0xFF38BDF8),
              ),
              title: const Text(
                'Prazo de avaliação',
                style: TextStyle(color: Colors.white70),
              ),
              subtitle: Text(
                _dateLabel(_evaluationDeadline),
                style: const TextStyle(color: Colors.white),
              ),
              onTap: _selectDeadline,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Salvar localmente'),
        ),
      ],
    );
  }

  Future<void> _selectDeadline() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _evaluationDeadline,
      firstDate: DateTime(2000),
      lastDate: DateTime(2200),
    );
    if (selected != null && mounted) {
      setState(() => _evaluationDeadline = selected);
    }
  }

  Future<void> _save() async {
    final amountText = _amountController.text.trim();
    final amount = amountText.isEmpty ? null : int.tryParse(amountText);
    if (amountText.isNotEmpty && amount == null) return;
    await ref.read(preAcquisitionsProvider.notifier).createPreAcquisition(
          equipmentId: _equipmentId,
          serviceOrderId: _serviceOrderController.text,
          offeredAmountMinor: amount,
          notes: _notesController.text,
          evaluationDeadline: _evaluationDeadline,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }
}

class _PreAcquisitionCard extends ConsumerWidget {
  const _PreAcquisitionCard({
    required this.preAcquisition,
    required this.equipment,
  });

  final PreAcquisitionEntity preAcquisition;
  final EquipmentEntity? equipment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending =
        preAcquisition.status == PreAcquisitionStatus.pendingEvaluation;
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.handshake, color: Color(0xFF38BDF8)),
        title: Text(
          equipment == null
              ? preAcquisition.equipmentId
              : '${equipment!.brand} ${equipment!.model}',
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _statusLabel(preAcquisition.status),
              style: const TextStyle(color: Colors.white70),
            ),
            Text(
              'Prazo: ${preAcquisition.evaluationDeadline}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            if (preAcquisition.offeredAmountMinor != null)
              Text(
                'Oferta: ${preAcquisition.offeredAmountMinor} centavos',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
          ],
        ),
        trailing: pending
            ? PopupMenuButton<PreAcquisitionStatus>(
                color: const Color(0xFF1E293B),
                icon: const Icon(Icons.more_vert, color: Colors.white70),
                onSelected: (status) => ref
                    .read(preAcquisitionsProvider.notifier)
                    .resolvePreAcquisition(
                      id: preAcquisition.id,
                      status: status,
                    ),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: PreAcquisitionStatus.approved,
                    child: Text(
                      'Aprovar avaliação',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: PreAcquisitionStatus.rejected,
                    child: Text(
                      'Rejeitar',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: PreAcquisitionStatus.expired,
                    child: Text(
                      'Marcar expirada',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: PreAcquisitionStatus.cancelled,
                    child: Text(
                      'Cancelar',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

InputDecoration _decoration(String label, IconData icon) {
  return InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white54),
    prefixIcon: Icon(icon, color: const Color(0xFF38BDF8)),
    enabledBorder: const OutlineInputBorder(
      borderSide: BorderSide(color: Color(0xFF334155)),
    ),
    focusedBorder: const OutlineInputBorder(
      borderSide: BorderSide(color: Color(0xFF38BDF8)),
    ),
  );
}

String _statusLabel(PreAcquisitionStatus status) {
  return switch (status) {
    PreAcquisitionStatus.pendingEvaluation => 'Pendente de avaliação',
    PreAcquisitionStatus.approved => 'Aprovada',
    PreAcquisitionStatus.rejected => 'Rejeitada',
    PreAcquisitionStatus.expired => 'Expirada',
    PreAcquisitionStatus.cancelled => 'Cancelada',
  };
}

String _dateLabel(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day/$month/${date.year}';
}
