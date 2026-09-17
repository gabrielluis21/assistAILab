import '../../core/money/money_minor.dart';

class ServiceOrderItemEntity {
  final String id;
  final String serviceOrderId;
  final String? partId;
  final String description;
  final int quantity;
  final MoneyMinor unitPrice;
  final MoneyMinor totalPrice;
  final String updatedAt;

  ServiceOrderItemEntity({
    required this.id,
    required this.serviceOrderId,
    this.partId,
    required this.description,
    required this.quantity,
    required this.unitPrice,
    required this.totalPrice,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'service_order_id': serviceOrderId,
      'part_id': partId,
      'description': description,
      'quantity': quantity,
      'unit_price_minor': unitPrice.minorUnits,
      'total_price_minor': totalPrice.minorUnits,
      'updated_at': updatedAt,
    };
  }

  factory ServiceOrderItemEntity.fromMap(Map<String, dynamic> map) {
    return ServiceOrderItemEntity(
      id: map['id'] as String,
      serviceOrderId:
          (map['service_order_id'] ?? map['serviceOrderId']) as String,
      partId: (map['part_id'] ?? map['partId']) as String?,
      description: map['description'] as String,
      quantity: (map['quantity'] as num).toInt(),
      unitPrice: MoneyMinor.serviceOrderFromJson(map['unit_price_minor']),
      totalPrice: MoneyMinor.serviceOrderFromJson(map['total_price_minor']),
      updatedAt: (map['updated_at'] ?? map['updatedAt'] ?? '') as String,
    );
  }
}
