import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'part_entity.dart';
import 'part_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/database/sqlite_database.dart';
import '../../core/sync/sync_payload_mapper.dart';
import '../../core/sync/sync_providers.dart';
import '../../core/sync/sync_trigger.dart';

final partRepositoryProvider = Provider<PartRepository>(
  (ref) => PartLocalDataSource(),
);

class PartsNotifier extends AsyncNotifier<List<PartEntity>> {
  @override
  Future<List<PartEntity>> build() async {
    return _load();
  }

  Future<List<PartEntity>> _load() async {
    final repo = ref.read(partRepositoryProvider);
    return repo.listAll();
  }

  Future<void> createPart({
    required String name,
    required String sku,
    required double price,
    required double costPrice,
    required int stockQuantity,
  }) async {
    const uuid = Uuid();
    final part = PartEntity(
      id: uuid.v4(),
      name: name,
      sku: sku,
      price: price,
      costPrice: costPrice,
      stockQuantity: stockQuantity,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final repo = ref.read(partRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    final db = await SqliteDatabase.instance;
    await db.transaction((txn) async {
      await repo.upsert(part, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: uuid.v4(),
          entityType: 'PART',
          entityId: part.id,
          operationType: 'CREATE',
          payload: SyncPayloadMapper.part(part),
          createdAt: DateTime.now().toIso8601String(),
        ),
        executor: txn,
      );
    });

    ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);

    state = AsyncData(await _load());
  }

  Future<void> deletePart(String id) async {
    final repo = ref.read(partRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    final db = await SqliteDatabase.instance;
    await db.transaction((txn) async {
      await repo.delete(id, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: const Uuid().v4(),
          entityType: 'PART',
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

final partsProvider = AsyncNotifierProvider<PartsNotifier, List<PartEntity>>(
  PartsNotifier.new,
);
