import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'equipment_entity.dart';
import 'equipment_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../customers/customers_provider.dart' show outboxDaoProvider;

final equipmentRepositoryProvider = Provider<EquipmentRepository>(
  (ref) => EquipmentLocalDataSource(),
);

class EquipmentsNotifier extends AsyncNotifier<List<EquipmentEntity>> {
  @override
  Future<List<EquipmentEntity>> build() async {
    return _load();
  }

  Future<List<EquipmentEntity>> _load() async {
    final repo = ref.read(equipmentRepositoryProvider);
    return repo.listAll();
  }

  Future<void> createEquipment({
    required String customerId,
    required String type,
    required String brand,
    required String model,
    String? serialNumber,
    String? notes,
  }) async {
    const uuid = Uuid();
    final equipment = EquipmentEntity(
      id: uuid.v4(),
      customerId: customerId,
      type: type,
      brand: brand,
      model: model,
      serialNumber: serialNumber,
      notes: notes,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final repo = ref.read(equipmentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await repo.upsert(equipment);

    await outbox.insert(OutboxItem(
      operationId: uuid.v4(),
      entityType: 'EQUIPMENT',
      entityId: equipment.id,
      operationType: 'CREATE',
      payload: equipment.toMap(),
      createdAt: DateTime.now().toIso8601String(),
    ));

    state = AsyncData(await _load());
  }

  Future<void> deleteEquipment(String id) async {
    final repo = ref.read(equipmentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await repo.delete(id);

    await outbox.insert(OutboxItem(
      operationId: const Uuid().v4(),
      entityType: 'EQUIPMENT',
      entityId: id,
      operationType: 'DELETE',
      payload: {'id': id},
      createdAt: DateTime.now().toIso8601String(),
    ));

    state = AsyncData(await _load());
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _load());
  }
}

final equipmentsProvider =
    AsyncNotifierProvider<EquipmentsNotifier, List<EquipmentEntity>>(
  EquipmentsNotifier.new,
);
