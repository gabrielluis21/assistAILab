import '../../customers/customer_entity.dart';
import '../../equipment/equipment_entity.dart';
import '../service_order_entity.dart';
import '../service_order_item_entity.dart';

class ServiceOrderPrintData {
  const ServiceOrderPrintData({
    required this.order,
    required this.items,
    this.customer,
    this.equipment,
    this.consultationQrPayload,
    this.onboardingQrPayload,
  });

  final ServiceOrderEntity order;
  final CustomerEntity? customer;
  final EquipmentEntity? equipment;
  final List<ServiceOrderItemEntity> items;

  // Reservados para o contrato definitivo com o backend.
  final String? consultationQrPayload;
  final String? onboardingQrPayload;
}
