import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'part_entity.dart';
import 'part_repository.dart';
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

final partRepositoryProvider = Provider<PartRepository>(
  (ref) => PartLocalDataSource(),
);

class PartsNotifier extends AutoDisposeAsyncNotifier<List<PartEntity>> {
  @override
  Future<List<PartEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    return _load(binding);
  }

  Future<List<PartEntity>> _load(
    _SessionDatabaseBinding binding,
  ) async {
    final repo = ref.read(partRepositoryProvider);
    final parts = await repo.listAll(
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    return parts;
  }

  Future<void> createPart({
    required String name,
    required String sku,
    required double price,
    required double costPrice,
    required int stockQuantity,
  }) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
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

    await binding.databaseHandle.database.transaction((txn) async {
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

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    final parts = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(parts);
  }

  Future<void> deletePart(String id) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final repo = ref.read(partRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await binding.databaseHandle.database.transaction((txn) async {
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

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    final parts = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(parts);
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    final parts = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(parts);
  }

  _SessionDatabaseBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError('An authenticated session is required for parts.');
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated parts session.',
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
      throw StateError('The parts operation belongs to a stale session.');
    }
  }

  void _requestSyncIfOnline(_SessionDatabaseBinding binding) {
    _ensureBindingCurrent(binding);
    if (ref.read(isOnlineSessionProvider)) {
      ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);
    }
  }
}

final partsProvider =
    AutoDisposeAsyncNotifierProvider<PartsNotifier, List<PartEntity>>(
  PartsNotifier.new,
);
