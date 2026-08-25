import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../customers/customers_provider.dart';
import '../../equipment/equipments_provider.dart';
import '../service_order_entity.dart';
import '../service_order_details_provider.dart';
import 'service_order_print_data.dart';

final serviceOrderPrintDataProvider =
    FutureProvider.family<ServiceOrderPrintData, ServiceOrderEntity>(
  (ref, order) async {
    final customerRepository = ref.read(
      customerRepositoryProvider,
    );

    final equipmentRepository = ref.read(
      equipmentRepositoryProvider,
    );

    final itemRepository = ref.read(
      serviceOrderItemRepositoryProvider,
    );

    final customer = await customerRepository.findById(
      order.customerId,
    );

    final equipment = await equipmentRepository.findById(
      order.equipmentId,
    );

    final items = await itemRepository.listByOrder(
      order.id,
    );

    return ServiceOrderPrintData(
      order: order,
      customer: customer,
      equipment: equipment,
      items: items,
    );
  },
);
