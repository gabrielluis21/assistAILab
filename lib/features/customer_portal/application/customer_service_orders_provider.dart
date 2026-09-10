import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/auth_scoped_database_manager.dart';
import '../../../core/sync/sync_providers.dart';
import '../../../core/sync/sync_state.dart';
import '../../auth/application/auth_provider.dart';
import '../../auth/domain/entities/auth_scope.dart';
import '../../auth/domain/entities/session_state.dart';
import '../../service_orders/service_order_entity.dart';
import '../../service_orders/service_orders_provider.dart';

typedef _SessionDatabaseBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
});

class CustomerServiceOrdersNotifier
    extends AsyncNotifier<List<ServiceOrderEntity>> {
  @override
  Future<List<ServiceOrderEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);

    ref.listen<SyncState>(
      syncStateProvider,
      (previous, next) {
        _handleSyncStateChanged(
          previous,
          next,
        );
      },
    );

    return _load(binding);
  }

  Future<List<ServiceOrderEntity>> _load(
    _SessionDatabaseBinding binding,
  ) async {
    final scope = binding.sessionKey.scope;
    if (scope is! CustomerAuthScope) {
      _ensureBindingCurrent(binding);
      return const <ServiceOrderEntity>[];
    }

    final repository = ref.read(
      serviceOrderRepositoryProvider,
    );

    final orders = await repository.listByCustomerId(
      scope.customerId,
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    return orders;
  }

  void _handleSyncStateChanged(
    SyncState? previous,
    SyncState next,
  ) {
    if (next.status != SyncStatus.idle ||
        next.isSyncing ||
        next.lastSyncAt == null) {
      return;
    }

    final previousSyncAt = previous?.lastSyncAt;

    if (previousSyncAt == next.lastSyncAt) {
      return;
    }

    final coordinator = ref.read(
      backgroundSyncCoordinatorProvider,
    );

    if (!coordinator.lastCycleDidWork) {
      return;
    }

    unawaited(
      refreshSilently(),
    );
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();

    try {
      final orders = await _load(binding);
      _ensureBindingCurrent(binding);
      state = AsyncData(orders);
    } catch (error, stackTrace) {
      if (_isBindingCurrent(binding)) {
        state = AsyncError(error, stackTrace);
      }
    }
  }

  Future<void> refreshSilently() async {
    final sessionKey = ref.read(authenticatedSessionKeyProvider);
    if (sessionKey == null) return;

    _SessionDatabaseBinding? binding;
    try {
      binding = _captureBinding(sessionKey);
      final orders = await _load(binding);

      _ensureBindingCurrent(binding);
      state = AsyncData(orders);
    } catch (error, stackTrace) {
      if (binding != null &&
          ref.read(authenticatedSessionKeyProvider) == sessionKey &&
          _isBindingCurrent(binding)) {
        state = AsyncError(
          error,
          stackTrace,
        );
      }
    }
  }

  _SessionDatabaseBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError(
        'An authenticated session is required for customer service orders.',
      );
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated customer portal session.',
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
        'The customer service-order operation belongs to a stale session.',
      );
    }
  }
}

final customerServiceOrdersProvider = AsyncNotifierProvider<
    CustomerServiceOrdersNotifier, List<ServiceOrderEntity>>(
  CustomerServiceOrdersNotifier.new,
);

final customerServiceOrderByIdProvider =
    Provider.family<AsyncValue<ServiceOrderEntity?>, String>(
  (ref, serviceOrderId) {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    if (sessionKey == null) {
      return const AsyncData(null);
    }

    final ordersAsync = ref.watch(
      customerServiceOrdersProvider,
    );

    return ordersAsync.whenData(
      (orders) {
        for (final order in orders) {
          if (order.id == serviceOrderId) {
            return order;
          }
        }

        return null;
      },
    );
  },
);
