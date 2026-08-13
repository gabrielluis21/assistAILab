import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'service_order_entity.dart';
import '../../core/database/service_order_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../customers/customers_provider.dart' show outboxDaoProvider;

final serviceOrderRepositoryProvider = Provider<ServiceOrderRepository>(
  (ref) => ServiceOrderLocalDataSource(),
);

// Valid state machine transitions - mirrors backend rule set
final Map<ServiceOrderStatusEnum, List<ServiceOrderStatusEnum>> _allowedTransitions = {
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
  ServiceOrderStatusEnum.emExecucao: [
    ServiceOrderStatusEnum.pronto,
    ServiceOrderStatusEnum.cancelado,
  ],
  ServiceOrderStatusEnum.pronto: [ServiceOrderStatusEnum.entregue, ServiceOrderStatusEnum.cancelado],
  ServiceOrderStatusEnum.entregue: <ServiceOrderStatusEnum>[],
  ServiceOrderStatusEnum.cancelado: <ServiceOrderStatusEnum>[],
};

List<ServiceOrderStatusEnum> allowedTransitionsFor(ServiceOrderStatusEnum current) {
  return _allowedTransitions[current] ?? <ServiceOrderStatusEnum>[];
}

class ServiceOrdersNotifier extends AsyncNotifier<List<ServiceOrderEntity>> {
  @override
  Future<List<ServiceOrderEntity>> build() async {
    return _load();
  }

  Future<List<ServiceOrderEntity>> _load() async {
    return ref.read(serviceOrderRepositoryProvider).listAll();
  }

  Future<void> createOrder({
    required String customerId,
    required String equipmentId,
    required String problemDescription,
    String? technicianId,
  }) async {
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

    await repo.upsert(order);

    await outbox.insert(OutboxItem(
      operationId: uuid.v4(),
      entityType: 'SERVICE_ORDER',
      entityId: order.id,
      operationType: 'CREATE',
      payload: order.toMap(),
      createdAt: DateTime.now().toIso8601String(),
    ));

    state = AsyncData(await _load());
  }

  Future<bool> updateStatus(String id, ServiceOrderStatusEnum newStatus) async {
    final repo = ref.read(serviceOrderRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    final order = await repo.findById(id);
    if (order == null) return false;

    final allowed = allowedTransitionsFor(order.status);
    if (!allowed.contains(newStatus)) return false;

    await repo.updateStatus(id, newStatus);

    await outbox.insert(OutboxItem(
      operationId: const Uuid().v4(),
      entityType: 'SERVICE_ORDER',
      entityId: id,
      operationType: 'UPDATE',
      payload: {'id': id, 'status': newStatus.toDbString()},
      createdAt: DateTime.now().toIso8601String(),
    ));

    state = AsyncData(await _load());
    return true;
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _load());
  }
}

final serviceOrdersProvider =
    AsyncNotifierProvider<ServiceOrdersNotifier, List<ServiceOrderEntity>>(
  ServiceOrdersNotifier.new,
);
