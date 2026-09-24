import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'customer_entity.dart';
import 'customer_repository.dart';
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

// Repository provider
final customerRepositoryProvider = Provider<CustomerRepository>(
  (ref) => CustomerLocalDataSource(),
);

// Customers state
class CustomersNotifier extends AutoDisposeAsyncNotifier<List<CustomerEntity>> {
  @override
  Future<List<CustomerEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    return _load(binding);
  }

  Future<List<CustomerEntity>> _load(
    _SessionDatabaseBinding binding,
  ) async {
    final repo = ref.read(customerRepositoryProvider);
    final customers = await repo.listAll(
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    return customers;
  }

  Future<void> createCustomer({
    required String name,
    String? document,
    String? email,
    String? phone,
    String? address,
  }) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
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

    await binding.databaseHandle.database.transaction((txn) async {
      await repo.upsert(customer, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: uuid.v4(),
          entityType: 'CUSTOMER',
          entityId: customer.id,
          operationType: 'CREATE',
          payload: SyncPayloadMapper.customer(customer),
          createdAt: DateTime.now().toIso8601String(),
        ),
        executor: txn,
      );
    });

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    final customers = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(customers);
  }

  Future<void> updateCustomer({
    required String id,
    required String name,
    String? document,
    String? email,
    String? phone,
    String? address,
  }) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final normalizedName = _requiredCustomerField(
      name,
      field: 'name',
      maximumLength: 500,
    );
    final updatedCustomer = CustomerEntity(
      id: id,
      name: normalizedName,
      document: _optionalCustomerField(
        document,
        field: 'document',
        maximumLength: 100,
      ),
      email: _optionalCustomerField(
        email,
        field: 'email',
        maximumLength: 500,
      ),
      phone: _optionalCustomerField(
        phone,
        field: 'phone',
        maximumLength: 100,
      ),
      address: _optionalCustomerField(
        address,
        field: 'address',
        maximumLength: 2000,
      ),
      updatedAt: DateTime.now().toIso8601String(),
    );
    final repo = ref.read(customerRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await binding.databaseHandle.database.transaction((txn) async {
      final existing = await repo.findById(id, executor: txn);
      if (existing == null) {
        throw StateError(
          'Customer is not available in the current authenticated scope.',
        );
      }

      await repo.upsert(updatedCustomer, executor: txn);
      await outbox.insert(
        OutboxItem(
          operationId: const Uuid().v4(),
          entityType: 'CUSTOMER',
          entityId: updatedCustomer.id,
          operationType: 'UPDATE',
          payload: SyncPayloadMapper.customer(updatedCustomer),
          createdAt: updatedCustomer.updatedAt,
        ),
        executor: txn,
      );
    });

    _ensureBindingCurrent(binding);
    _requestSyncIfOnline(binding);

    final customers = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(customers);
  }

  Future<void> deleteCustomer(String id) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final repo = ref.read(customerRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await binding.databaseHandle.database.transaction((txn) async {
      await repo.delete(id, executor: txn);

      await outbox.insert(
        OutboxItem(
          operationId: const Uuid().v4(),
          entityType: 'CUSTOMER',
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

    final customers = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(customers);
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    final customers = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(customers);
  }

  _SessionDatabaseBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError('An authenticated session is required for customers.');
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated customer session.',
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
      throw StateError('The customer operation belongs to a stale session.');
    }
  }

  void _requestSyncIfOnline(_SessionDatabaseBinding binding) {
    _ensureBindingCurrent(binding);
    if (ref.read(isOnlineSessionProvider)) {
      ref.read(syncSchedulerProvider).requestSync(SyncTrigger.localMutation);
    }
  }
}

final customersProvider =
    AutoDisposeAsyncNotifierProvider<CustomersNotifier, List<CustomerEntity>>(
  CustomersNotifier.new,
);

String _requiredCustomerField(
  String value, {
  required String field,
  required int maximumLength,
}) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maximumLength) {
    throw ArgumentError.value(value, field, 'Invalid Customer field.');
  }
  return normalized;
}

String? _optionalCustomerField(
  String? value, {
  required String field,
  required int maximumLength,
}) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized.length > maximumLength) {
    throw ArgumentError.value(value, field, 'Invalid Customer field.');
  }
  return normalized;
}
