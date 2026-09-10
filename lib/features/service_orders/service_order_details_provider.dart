import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'service_order_item_entity.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../../core/database/service_order_item_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/sync/sync_payload_mapper.dart';
import '../../core/sync/sync_providers.dart';
import '../../core/sync/sync_trigger.dart';
import '../auth/application/auth_provider.dart';
import '../auth/domain/entities/session_state.dart';
import 'service_orders_provider.dart';

typedef _SessionDatabaseBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
});

final serviceOrderItemRepositoryProvider = Provider<ServiceOrderItemRepository>(
  (ref) => ServiceOrderItemLocalDataSource(),
);

class ServiceOrderItemsNotifier
    extends FamilyAsyncNotifier<List<ServiceOrderItemEntity>, String> {
  @override
  Future<List<ServiceOrderItemEntity>> build(String arg) async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    return _load(arg, binding);
  }

  Future<List<ServiceOrderItemEntity>> _load(
    String orderId,
    _SessionDatabaseBinding binding,
  ) async {
    final repo = ref.read(serviceOrderItemRepositoryProvider);
    final items = await repo.listByOrder(
      orderId,
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    return items;
  }

  Future<void> addItem({
    required String serviceOrderId,
    String? partId,
    required String description,
    required int quantity,
    required double unitPrice,
  }) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    const uuid = Uuid();
    final totalPrice = quantity * unitPrice;
    final item = ServiceOrderItemEntity(
      id: uuid.v4(),
      serviceOrderId: serviceOrderId,
      partId: partId,
      description: description,
      quantity: quantity,
      unitPrice: unitPrice,
      totalPrice: totalPrice,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final itemRepo = ref.read(serviceOrderItemRepositoryProvider);
    final orderRepo = ref.read(serviceOrderRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await binding.databaseHandle.database.transaction((txn) async {
      await itemRepo.upsert(item, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: uuid.v4(),
          entityType: 'SERVICE_ORDER_ITEM',
          entityId: item.id,
          operationType: 'CREATE',
          payload: SyncPayloadMapper.serviceOrderItem(item),
          createdAt: DateTime.now().toIso8601String(),
        ),
        executor: txn,
      );

      // Recalculate OS total amount inside transaction
      final allItems =
          await itemRepo.listByOrder(serviceOrderId, executor: txn);
      final newTotal =
          allItems.fold<double>(0.0, (sum, i) => sum + i.totalPrice);

      final existingOrder =
          await orderRepo.findById(serviceOrderId, executor: txn);
      if (existingOrder != null) {
        final updatedOrder = existingOrder.copyWith(
          totalAmount: newTotal,
          updatedAt: DateTime.now().toIso8601String(),
        );
        await orderRepo.upsert(updatedOrder, executor: txn);

        await outbox.insert(
          OutboxItem(
            operationId: uuid.v4(),
            entityType: 'SERVICE_ORDER',
            entityId: serviceOrderId,
            operationType: 'UPDATE',
            payload: SyncPayloadMapper.serviceOrder(updatedOrder),
            createdAt: DateTime.now().toIso8601String(),
          ),
          executor: txn,
        );
      }
    });

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    _ensureBindingCurrent(binding);
    await ref.read(serviceOrdersProvider.notifier).refresh();

    final items = await _load(serviceOrderId, binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(items);
  }

  Future<void> deleteItem(String itemId, String serviceOrderId) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final itemRepo = ref.read(serviceOrderItemRepositoryProvider);
    final orderRepo = ref.read(serviceOrderRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await binding.databaseHandle.database.transaction((txn) async {
      await itemRepo.delete(itemId, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: const Uuid().v4(),
          entityType: 'SERVICE_ORDER_ITEM',
          entityId: itemId,
          operationType: 'DELETE',
          payload: SyncPayloadMapper.delete(itemId),
          createdAt: DateTime.now().toIso8601String(),
        ),
        executor: txn,
      );

      // Recalculate OS total inside transaction
      final remaining =
          await itemRepo.listByOrder(serviceOrderId, executor: txn);
      final newTotal =
          remaining.fold<double>(0.0, (sum, i) => sum + i.totalPrice);

      final existingOrder =
          await orderRepo.findById(serviceOrderId, executor: txn);
      if (existingOrder != null) {
        final updatedOrder = existingOrder.copyWith(
          totalAmount: newTotal,
          updatedAt: DateTime.now().toIso8601String(),
        );
        await orderRepo.upsert(updatedOrder, executor: txn);

        await outbox.insert(
          OutboxItem(
            operationId: const Uuid().v4(),
            entityType: 'SERVICE_ORDER',
            entityId: serviceOrderId,
            operationType: 'UPDATE',
            payload: SyncPayloadMapper.serviceOrder(updatedOrder),
            createdAt: DateTime.now().toIso8601String(),
          ),
          executor: txn,
        );
      }
    });

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    _ensureBindingCurrent(binding);
    await ref.read(serviceOrdersProvider.notifier).refresh();

    final items = await _load(serviceOrderId, binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(items);
  }

  _SessionDatabaseBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError(
        'An authenticated session is required for service-order items.',
      );
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated service-order-item session.',
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
      throw StateError(
        'The service-order-item operation belongs to a stale session.',
      );
    }
  }

  void _requestSyncIfOnline(_SessionDatabaseBinding binding) {
    _ensureBindingCurrent(binding);
    if (ref.read(isOnlineSessionProvider)) {
      ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);
    }
  }
}

final serviceOrderItemsProvider = AsyncNotifierProviderFamily<
    ServiceOrderItemsNotifier, List<ServiceOrderItemEntity>, String>(
  ServiceOrderItemsNotifier.new,
);
