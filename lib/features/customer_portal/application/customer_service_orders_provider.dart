import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../../service_orders/service_order_entity.dart';
import '../../service_orders/service_orders_provider.dart';

class CustomerServiceOrdersNotifier
    extends AsyncNotifier<List<ServiceOrderEntity>> {
  @override
  Future<List<ServiceOrderEntity>> build() async {
    return _load();
  }

  Future<List<ServiceOrderEntity>> _load() async {
    final auth = ref.read(authStateProvider);

    final user = auth.valueOrNull;

    if (user == null) {
      return const <ServiceOrderEntity>[];
    }

    if (user.role.trim().toUpperCase() != 'CUSTOMER') {
      return const <ServiceOrderEntity>[];
    }

    final customerId = user.customerId;

    if (customerId == null || customerId.trim().isEmpty) {
      return const <ServiceOrderEntity>[];
    }

    final repository = ref.read(serviceOrderRepositoryProvider);

    return repository.listByCustomerId(
      customerId,
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading();

    state = await AsyncValue.guard(
      _load,
    );
  }

  Future<void> refreshSilently() async {
    try {
      final orders = await _load();

      state = AsyncData(orders);
    } catch (error, stackTrace) {
      state = AsyncError(
        error,
        stackTrace,
      );
    }
  }
}

final customerServiceOrdersProvider = AsyncNotifierProvider<
    CustomerServiceOrdersNotifier, List<ServiceOrderEntity>>(
  CustomerServiceOrdersNotifier.new,
);
