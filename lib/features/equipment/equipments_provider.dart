import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'equipment_entity.dart';
import 'equipment_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/database/sqlite_database.dart';
import '../../core/sync/sync_payload_mapper.dart';
import '../../core/sync/sync_providers.dart';
import '../../core/sync/sync_trigger.dart';

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

    final db = await SqliteDatabase.instance;
    await db.transaction((txn) async {
      await repo.upsert(equipment, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: uuid.v4(),
          entityType: 'EQUIPMENT',
          entityId: equipment.id,
          operationType: 'CREATE',
          payload: SyncPayloadMapper.equipment(equipment),
          createdAt: DateTime.now().toIso8601String(),
        ),
        executor: txn,
      );
    });

    ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);

    state = AsyncData(await _load());
  }

  Future<void> deleteEquipment(String id) async {
    final repo = ref.read(equipmentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    final db = await SqliteDatabase.instance;
    await db.transaction((txn) async {
      await repo.delete(id, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: const Uuid().v4(),
          entityType: 'EQUIPMENT',
          entityId: id,
          operationType: 'DELETE',
          payload: SyncPayloadMapper.delete(id),
          createdAt: DateTime.now().toIso8601String(),
        ),
        executor: txn,
      );
    });

    ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);

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
