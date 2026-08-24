import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'customer_entity.dart';
import 'customer_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/sync/sync_providers.dart';
import '../../core/sync/sync_trigger.dart';

// Repository provider
final customerRepositoryProvider = Provider<CustomerRepository>(
  (ref) => CustomerLocalDataSource(),
);

// Customers state
class CustomersNotifier extends AsyncNotifier<List<CustomerEntity>> {
  @override
  Future<List<CustomerEntity>> build() async {
    return _load();
  }

  Future<List<CustomerEntity>> _load() async {
    final repo = ref.read(customerRepositoryProvider);
    return repo.listAll();
  }

  Future<void> createCustomer({
    required String name,
    String? document,
    String? email,
    String? phone,
    String? address,
  }) async {
    const uuid = Uuid();
    final customer = CustomerEntity(
      id: uuid.v4(),
      name: name,
      document: document,
      email: email,
      phone: phone,
      address: address,
      updatedAt: DateTime.now().toIso8601String(),
    );

    final repo = ref.read(customerRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    // Save locally first
    await repo.upsert(customer);

    // Enqueue to outbox for background sync
    await outbox.insert(OutboxItem(
      operationId: uuid.v4(),
      entityType: 'CUSTOMER',
      entityId: customer.id,
      operationType: 'CREATE',
      payload: customer.toMap(),
      createdAt: DateTime.now().toIso8601String(),
    ));

    // Request background sync
    ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);

    state = AsyncData(await _load());
  }

  Future<void> deleteCustomer(String id) async {
    final repo = ref.read(customerRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await repo.delete(id);

    await outbox.insert(OutboxItem(
      operationId: const Uuid().v4(),
      entityType: 'CUSTOMER',
      entityId: id,
      operationType: 'DELETE',
      payload: {'id': id},
      createdAt: DateTime.now().toIso8601String(),
    ));

    // Request background sync
    ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);

    state = AsyncData(await _load());
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _load());
  }
}

final customersProvider =
    AsyncNotifierProvider<CustomersNotifier, List<CustomerEntity>>(
  CustomersNotifier.new,
);
