import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../../service_orders/service_order_entity.dart';
import '../../service_orders/service_orders_provider.dart';

final customerServiceOrdersProvider =
    FutureProvider<List<ServiceOrderEntity>>((ref) async {
  final auth = ref.watch(authStateProvider);

  final user = auth.valueOrNull;

  if (user == null ||
      user.role.trim().toUpperCase() != 'CUSTOMER' ||
      user.customerId == null ||
      user.customerId!.isEmpty) {
    return const <ServiceOrderEntity>[];
  }

  final repository =
      ref.read(serviceOrderRepositoryProvider);

  return repository.listByCustomerId(
    user.customerId!,
  );
});