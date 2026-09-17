import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/auth_scoped_database_manager.dart';
import '../../auth/application/auth_provider.dart';
import '../../customers/customers_provider.dart';
import '../../equipment/equipments_provider.dart';
import '../service_order_entity.dart';
import '../service_order_details_provider.dart';
import '../service_orders_provider.dart';
import 'service_order_print_data.dart';

final serviceOrderPrintDataProvider =
    FutureProvider.family<ServiceOrderPrintData, ServiceOrderEntity>(
  (ref, order) async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    if (sessionKey == null) {
      throw StateError(
        'An authenticated session is required to load print data.',
      );
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated print session.',
      );
    }

    bool isBindingCurrent() {
      return ref.read(authenticatedSessionKeyProvider) == sessionKey &&
          handle.authScope == sessionKey.scope &&
          handle.sessionGeneration == sessionKey.sessionGeneration &&
          manager.isCurrentHandle(handle);
    }

    void ensureBindingCurrent() {
      if (!isBindingCurrent()) {
        throw StateError('The print-data request belongs to a stale session.');
      }
    }

    final orderRepository = ref.read(
      serviceOrderRepositoryProvider,
    );

    final customerRepository = ref.read(
      customerRepositoryProvider,
    );

    final equipmentRepository = ref.read(
      equipmentRepositoryProvider,
    );

    final itemRepository = ref.read(
      serviceOrderItemRepositoryProvider,
    );

    final boundOrder = await orderRepository.findById(
      order.id,
      executor: handle.database,
    );
    ensureBindingCurrent();
    if (boundOrder == null) {
      throw StateError(
        'The service order does not belong to the bound session database.',
      );
    }

    final customerId = boundOrder.customerId;
    final customer = customerId == null
        ? null
        : await customerRepository.findById(
            customerId,
            executor: handle.database,
          );
    ensureBindingCurrent();

    final equipment = await equipmentRepository.findById(
      boundOrder.equipmentId,
      executor: handle.database,
    );
    ensureBindingCurrent();

    final items = await itemRepository.listByOrder(
      boundOrder.id,
      executor: handle.database,
    );
    ensureBindingCurrent();

    return ServiceOrderPrintData(
      order: boundOrder,
      customer: customer,
      equipment: equipment,
      items: items,
    );
  },
);
