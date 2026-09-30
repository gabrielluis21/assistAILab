import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/auth_scoped_database_manager.dart';
import '../auth/domain/entities/auth_scope.dart';
import 'equipment_acquisition_entity.dart';
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
            tooltip: 'Aquisições autoritativas',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const EquipmentAcquisitionsPage(),
              ),
            ),
            icon: const Icon(Icons.inventory_2, color: Color(0xFF38BDF8)),
          ),
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

class EquipmentAcquisitionsPage extends ConsumerWidget {
  const EquipmentAcquisitionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final acquisitions = ref.watch(equipmentAcquisitionsProvider);
    final equipments = ref.watch(equipmentsProvider);
    final scope = AuthScopedDatabaseManager.instance.currentHandle?.authScope;
    final equipmentById = {
      for (final equipment in equipments.value ?? const <EquipmentEntity>[])
        equipment.id: equipment,
    };

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Aquisições de equipamentos',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: () =>
                ref.read(equipmentAcquisitionsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh, color: Color(0xFF38BDF8)),
          ),
        ],
      ),
      body: acquisitions.when(
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
                'Nenhuma aquisição disponível',
                style: TextStyle(color: Colors.white54),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _SectionTitle('Aquisições autoritativas'),
              for (final acquisition in records)
                _EquipmentAcquisitionCard(
                  acquisition: acquisition,
                  equipment: equipmentById[acquisition.equipmentId],
                  isProfessional: scope is ProfessionalAuthScope,
                  isCustomer: scope is CustomerAuthScope,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF38BDF8),
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
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
            ? PopupMenuButton<_PreAcquisitionAction>(
                color: const Color(0xFF1E293B),
                icon: const Icon(Icons.more_vert, color: Colors.white70),
                onSelected: (action) => _applyAction(ref, action),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _PreAcquisitionAction.createResale,
                    child: Text(
                      'Criar proposta para revenda',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: _PreAcquisitionAction.createPartsDonor,
                    child: Text(
                      'Criar proposta para peças',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: _PreAcquisitionAction.reject,
                    child: Text(
                      'Rejeitar',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: _PreAcquisitionAction.expire,
                    child: Text(
                      'Marcar expirada',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem(
                    value: _PreAcquisitionAction.cancel,
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

  Future<void> _applyAction(
    WidgetRef ref,
    _PreAcquisitionAction action,
  ) {
    return switch (action) {
      _PreAcquisitionAction.createResale => _createAcquisition(
          ref,
          EquipmentAcquisitionPurpose.resale,
        ),
      _PreAcquisitionAction.createPartsDonor => _createAcquisition(
          ref,
          EquipmentAcquisitionPurpose.partsDonor,
        ),
      _PreAcquisitionAction.reject =>
        ref.read(preAcquisitionsProvider.notifier).resolvePreAcquisition(
              id: preAcquisition.id,
              status: PreAcquisitionStatus.rejected,
            ),
      _PreAcquisitionAction.expire =>
        ref.read(preAcquisitionsProvider.notifier).resolvePreAcquisition(
              id: preAcquisition.id,
              status: PreAcquisitionStatus.expired,
            ),
      _PreAcquisitionAction.cancel =>
        ref.read(preAcquisitionsProvider.notifier).resolvePreAcquisition(
              id: preAcquisition.id,
              status: PreAcquisitionStatus.cancelled,
            ),
    };
  }

  Future<void> _createAcquisition(
    WidgetRef ref,
    EquipmentAcquisitionPurpose purpose,
  ) async {
    await ref.read(equipmentAcquisitionsProvider.future);
    await ref
        .read(equipmentAcquisitionsProvider.notifier)
        .createFromPreAcquisition(
          preAcquisitionId: preAcquisition.id,
          purpose: purpose,
        );
  }
}

enum _PreAcquisitionAction {
  createResale,
  createPartsDonor,
  reject,
  expire,
  cancel,
}

class _EquipmentAcquisitionCard extends ConsumerWidget {
  const _EquipmentAcquisitionCard({
    required this.acquisition,
    required this.equipment,
    required this.isProfessional,
    required this.isCustomer,
  });

  final EquipmentAcquisitionEntity acquisition;
  final EquipmentEntity? equipment;
  final bool isProfessional;
  final bool isCustomer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = _availableActions();
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: const Icon(Icons.inventory_2, color: Color(0xFF38BDF8)),
        title: Text(
          equipment == null
              ? acquisition.equipmentId
              : '${equipment!.brand} ${equipment!.model}',
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_acquisitionStatusLabel(acquisition.status)} · '
              '${_sourceLabel(acquisition.source)}',
              style: const TextStyle(color: Colors.white70),
            ),
            Text(
              acquisition.purpose == EquipmentAcquisitionPurpose.resale
                  ? 'Finalidade: revenda'
                  : 'Finalidade: doadora de peças',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        trailing: actions.isEmpty
            ? null
            : PopupMenuButton<_EquipmentAcquisitionAction>(
                color: const Color(0xFF1E293B),
                icon: const Icon(Icons.more_vert, color: Colors.white70),
                onSelected: (action) => _applyAction(ref, action),
                itemBuilder: (_) => [
                  for (final action in actions)
                    PopupMenuItem(
                      value: action,
                      child: Text(
                        _actionLabel(action),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  List<_EquipmentAcquisitionAction> _availableActions() {
    if (isCustomer &&
        acquisition.status == EquipmentAcquisitionStatus.pending) {
      return const [
        _EquipmentAcquisitionAction.authorize,
        _EquipmentAcquisitionAction.reject,
      ];
    }
    if (isProfessional &&
        acquisition.status == EquipmentAcquisitionStatus.pending &&
        acquisition.source == EquipmentAcquisitionSource.directOffer) {
      return const [_EquipmentAcquisitionAction.authorizeInPerson];
    }
    if (isProfessional &&
        acquisition.status == EquipmentAcquisitionStatus.authorized) {
      return const [_EquipmentAcquisitionAction.complete];
    }
    return const [];
  }

  Future<void> _applyAction(
    WidgetRef ref,
    _EquipmentAcquisitionAction action,
  ) {
    final notifier = ref.read(equipmentAcquisitionsProvider.notifier);
    return switch (action) {
      _EquipmentAcquisitionAction.authorize => notifier
          .authorize(
            acquisitionId: acquisition.id,
            consentMethod: EquipmentConsentMethod.customerApp,
          )
          .then((_) {}),
      _EquipmentAcquisitionAction.reject =>
        notifier.reject(acquisitionId: acquisition.id).then((_) {}),
      _EquipmentAcquisitionAction.authorizeInPerson =>
        notifier.authorizeInPerson(acquisitionId: acquisition.id).then((_) {}),
      _EquipmentAcquisitionAction.complete =>
        notifier.complete(acquisitionId: acquisition.id).then((_) {}),
    };
  }
}

enum _EquipmentAcquisitionAction {
  authorize,
  reject,
  authorizeInPerson,
  complete,
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

String _acquisitionStatusLabel(EquipmentAcquisitionStatus status) {
  return switch (status) {
    EquipmentAcquisitionStatus.pending => 'Pendente',
    EquipmentAcquisitionStatus.authorized => 'Autorizada',
    EquipmentAcquisitionStatus.rejected => 'Rejeitada',
    EquipmentAcquisitionStatus.cancelled => 'Cancelada',
    EquipmentAcquisitionStatus.completed => 'Concluída',
  };
}

String _sourceLabel(EquipmentAcquisitionSource source) {
  return switch (source) {
    EquipmentAcquisitionSource.serviceOrder => 'Ordem de Serviço',
    EquipmentAcquisitionSource.directOffer => 'Oferta direta',
  };
}

String _actionLabel(_EquipmentAcquisitionAction action) {
  return switch (action) {
    _EquipmentAcquisitionAction.authorize => 'Autorizar',
    _EquipmentAcquisitionAction.reject => 'Rejeitar',
    _EquipmentAcquisitionAction.authorizeInPerson =>
      'Autorizar presencialmente',
    _EquipmentAcquisitionAction.complete => 'Concluir aquisição',
  };
}

String _dateLabel(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day/$month/${date.year}';
}
