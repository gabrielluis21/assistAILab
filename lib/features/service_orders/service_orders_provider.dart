import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'service_order_entity.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../../core/database/service_order_repository.dart';
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

final serviceOrderRepositoryProvider = Provider<ServiceOrderRepository>(
  (ref) => ServiceOrderLocalDataSource(),
);

// Valid state machine transitions - mirrors backend rule set
final Map<ServiceOrderStatusEnum, List<ServiceOrderStatusEnum>>
    _allowedTransitions = {
  ServiceOrderStatusEnum.draft: [
    ServiceOrderStatusEnum.diagnostico,
    ServiceOrderStatusEnum.cancelado,
  ],
  ServiceOrderStatusEnum.diagnostico: [
    ServiceOrderStatusEnum.aguardandoAprovacao,
    ServiceOrderStatusEnum.cancelado,
  ],
  ServiceOrderStatusEnum.aguardandoAprovacao: [
    ServiceOrderStatusEnum.emExecucao,
    ServiceOrderStatusEnum.cancelado,
  ],
  ServiceOrderStatusEnum.aguardandoReaprovacao: <ServiceOrderStatusEnum>[],
  ServiceOrderStatusEnum.emExecucao: [
    ServiceOrderStatusEnum.pronto,
    ServiceOrderStatusEnum.cancelado,
  ],
  ServiceOrderStatusEnum.pronto: [
    ServiceOrderStatusEnum.entregue,
    ServiceOrderStatusEnum.cancelado
  ],
  ServiceOrderStatusEnum.entregue: <ServiceOrderStatusEnum>[],
  ServiceOrderStatusEnum.cancelado: <ServiceOrderStatusEnum>[],
};

List<ServiceOrderStatusEnum> allowedTransitionsFor(
    ServiceOrderStatusEnum current) {
  return _allowedTransitions[current] ?? <ServiceOrderStatusEnum>[];
}

class ServiceOrdersNotifier
    extends AutoDisposeAsyncNotifier<List<ServiceOrderEntity>> {
  @override
  Future<List<ServiceOrderEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    return _load(binding);
  }

  Future<List<ServiceOrderEntity>> _load(
    _SessionDatabaseBinding binding,
  ) async {
    final orders = await ref.read(serviceOrderRepositoryProvider).listAll(
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
    return orders;
  }

  Future<void> createOrder({
    required String customerId,
    required String equipmentId,
    required String problemDescription,
    String? technicianId,
  }) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    const uuid = Uuid();
    final order = ServiceOrderEntity(
      id: uuid.v4(),
      customerId: customerId,
      equipmentId: equipmentId,
      technicianId: technicianId,
      status: ServiceOrderStatusEnum.diagnostico,
      problemDescription: problemDescription,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final repo = ref.read(serviceOrderRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    final outboxItem = OutboxItem(
      operationId: uuid.v4(),
      entityType: 'SERVICE_ORDER',
      entityId: order.id,
      operationType: 'CREATE',
      payload: SyncPayloadMapper.serviceOrder(order),
      createdAt: DateTime.now().toIso8601String(),
    );

    await binding.databaseHandle.database.transaction((txn) async {
      await repo.upsert(order, executor: txn);
      await outbox.insert(outboxItem, executor: txn);
    });

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    final orders = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(orders);
  }

  Future<bool> updateStatus(String id, ServiceOrderStatusEnum newStatus) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final repo = ref.read(serviceOrderRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    final order = await repo.findById(
      id,
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    if (order == null) return false;

    final allowed = allowedTransitionsFor(order.status);
    if (!allowed.contains(newStatus)) return false;

    final updatedOrder = order.copyWith(
      status: newStatus,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final outboxItem = OutboxItem(
      operationId: const Uuid().v4(),
      entityType: 'SERVICE_ORDER',
      entityId: id,
      operationType: 'UPDATE',
      payload: SyncPayloadMapper.serviceOrder(updatedOrder),
      createdAt: DateTime.now().toIso8601String(),
    );

    // The requested transition is process state until the Backend confirms it.
    // Keep the last authoritative local snapshot and only enqueue the command.
    await outbox.insert(
      outboxItem,
      executor: binding.databaseHandle.database,
    );

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    return true;
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    final orders = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(orders);
  }

  _SessionDatabaseBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError(
        'An authenticated session is required for service orders.',
      );
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated service-order session.',
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
        'The service-order operation belongs to a stale session.',
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

final serviceOrdersProvider = AutoDisposeAsyncNotifierProvider<
    ServiceOrdersNotifier, List<ServiceOrderEntity>>(
  ServiceOrdersNotifier.new,
);
