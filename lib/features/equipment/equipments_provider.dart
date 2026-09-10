import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'equipment_entity.dart';
import 'equipment_repository.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/sync/sync_payload_mapper.dart';
import '../../core/sync/sync_providers.dart';
import '../../core/sync/sync_trigger.dart';
import '../auth/application/auth_provider.dart';
import '../auth/domain/entities/session_state.dart';

typedef _SessionDatabaseBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
});

final equipmentRepositoryProvider = Provider<EquipmentRepository>(
  (ref) => EquipmentLocalDataSource(),
);

class EquipmentsNotifier
    extends AutoDisposeAsyncNotifier<List<EquipmentEntity>> {
  @override
  Future<List<EquipmentEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    return _load(binding);
  }

  Future<List<EquipmentEntity>> _load(
    _SessionDatabaseBinding binding,
  ) async {
    final repo = ref.read(equipmentRepositoryProvider);
    final equipments = await repo.listAll(
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    return equipments;
  }

  Future<void> createEquipment({
    required String customerId,
    required String type,
    required String brand,
    required String model,
    String? serialNumber,
    String? notes,
  }) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
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

    await binding.databaseHandle.database.transaction((txn) async {
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

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    final equipments = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(equipments);
  }

  Future<void> deleteEquipment(String id) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final repo = ref.read(equipmentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await binding.databaseHandle.database.transaction((txn) async {
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

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    final equipments = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(equipments);
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    final equipments = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(equipments);
  }

  _SessionDatabaseBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError('An authenticated session is required for equipment.');
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated equipment session.',
      );
    }

    return (
      sessionKey: sessionKey,
      databaseHandle: handle,
    );
  }

  bool _isBindingCurrent(_SessionDatabaseBinding binding) {
    return ref.read(authenticatedSessionKeyProvider) == binding.sessionKey &&
        binding.databaseHandle.authScope == binding.sessionKey.scope &&
        binding.databaseHandle.sessionGeneration ==
            binding.sessionKey.sessionGeneration &&
        AuthScopedDatabaseManager.instance
            .isCurrentHandle(binding.databaseHandle);
  }

  void _ensureBindingCurrent(_SessionDatabaseBinding binding) {
    if (!_isBindingCurrent(binding)) {
      throw StateError('The equipment operation belongs to a stale session.');
    }
  }

  void _requestSyncIfOnline(_SessionDatabaseBinding binding) {
    _ensureBindingCurrent(binding);
    if (ref.read(isOnlineSessionProvider)) {
      ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);
    }
  }
}

final equipmentsProvider =
    AutoDisposeAsyncNotifierProvider<EquipmentsNotifier, List<EquipmentEntity>>(
  EquipmentsNotifier.new,
);
