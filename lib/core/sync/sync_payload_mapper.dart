import '../../features/customers/customer_entity.dart';
import '../../features/equipment/equipment_entity.dart';
import '../../features/parts/part_entity.dart';
import '../../features/service_orders/service_order_entity.dart';
import '../../features/service_orders/service_order_item_entity.dart';

/// Centralized mapper that converts domain entities into payloads conforming
/// exactly to the backend API `/sync/push` contracts.
abstract final class SyncPayloadMapper {
  /// Builds payload for CUSTOMER (CREATE / UPDATE).
  static Map<String, dynamic> customer(CustomerEntity customer) {
    return {
      'name': customer.name,
      'document': customer.document,
      'email': customer.email,
      'phone': customer.phone,
      'address': customer.address,
    };
  }

  /// Builds payload for EQUIPMENT (CREATE / UPDATE).
  static Map<String, dynamic> equipment(EquipmentEntity equipment) {
    return {
      'customerId': equipment.customerId,
      'type': equipment.type,
      'brand': equipment.brand,
      'model': equipment.model,
      'serialNumber': equipment.serialNumber,
      'notes': equipment.notes,
    };
  }

  /// Builds payload for SERVICE_ORDER (CREATE / UPDATE).
  ///
  /// Guarantees that all fields required by the backend handler
  /// (customerId, equipmentId, problemDescription, status, etc.)
  /// are included in the snapshot.
  static Map<String, dynamic> serviceOrder(ServiceOrderEntity order) {
    return {
      'customerId': order.customerId,
      'equipmentId': order.equipmentId,
      'technicianId': order.technicianId,
      'status': order.status.toDbString(),
      'problemDescription': order.problemDescription,
      'diagnosis': order.diagnosis,
      'solution': order.solution,
      'totalAmount': order.totalAmount,
    };
  }

  /// Builds payload for SERVICE_ORDER_ITEM (CREATE / UPDATE).
  static Map<String, dynamic> serviceOrderItem(ServiceOrderItemEntity item) {
    return {
      'serviceOrderId': item.serviceOrderId,
      'partId': item.partId,
      'description': item.description,
      'quantity': item.quantity,
      'unitPrice': item.unitPrice,
      'totalPrice': item.totalPrice,
    };
  }

  /// Builds payload for PART (CREATE / UPDATE).
  static Map<String, dynamic> part(PartEntity part) {
    return {
      'name': part.name,
      'sku': part.sku,
      'price': part.price,
      'costPrice': part.costPrice,
      'stockQuantity': part.stockQuantity,
    };
  }

  /// Builds payload for generic entity DELETE operations.
  static Map<String, dynamic> delete(String id) {
    return {
      'id': id,
    };
  }
}
