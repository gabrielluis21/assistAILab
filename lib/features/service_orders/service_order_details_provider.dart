import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'service_order_item_entity.dart';
import '../../core/database/service_order_item_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/database/sqlite_database.dart';
import '../../core/sync/sync_payload_mapper.dart';
import '../../core/sync/sync_providers.dart';
import '../../core/sync/sync_trigger.dart';
import 'service_orders_provider.dart';

final serviceOrderItemRepositoryProvider = Provider<ServiceOrderItemRepository>(
  (ref) => ServiceOrderItemLocalDataSource(),
);

class ServiceOrderItemsNotifier
    extends FamilyAsyncNotifier<List<ServiceOrderItemEntity>, String> {
  @override
  Future<List<ServiceOrderItemEntity>> build(String arg) async {
    return _load(arg);
  }

  Future<List<ServiceOrderItemEntity>> _load(String orderId) async {
    final repo = ref.read(serviceOrderItemRepositoryProvider);
    return repo.listByOrder(orderId);
  }

  Future<void> addItem({
    required String serviceOrderId,
    String? partId,
    required String description,
    required int quantity,
    required double unitPrice,
  }) async {
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

    final db = await SqliteDatabase.instance;
    await db.transaction((txn) async {
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

    ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);
    ref.read(serviceOrdersProvider.notifier).refresh();
    state = AsyncData(await _load(serviceOrderId));
  }

  Future<void> deleteItem(String itemId, String serviceOrderId) async {
    final itemRepo = ref.read(serviceOrderItemRepositoryProvider);
    final orderRepo = ref.read(serviceOrderRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    final db = await SqliteDatabase.instance;
    await db.transaction((txn) async {
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

    ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);
    ref.read(serviceOrdersProvider.notifier).refresh();
    state = AsyncData(await _load(serviceOrderId));
  }
}

final serviceOrderItemsProvider = AsyncNotifierProviderFamily<
    ServiceOrderItemsNotifier, List<ServiceOrderItemEntity>, String>(
  ServiceOrderItemsNotifier.new,
);
