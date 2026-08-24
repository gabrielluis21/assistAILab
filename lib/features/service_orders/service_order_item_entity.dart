class ServiceOrderItemEntity {
  final String id;
  final String serviceOrderId;
  final String? partId;
  final String description;
  final int quantity;
  final double unitPrice;
  final double totalPrice;
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
      'unit_price': unitPrice,
      'total_price': totalPrice,
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
      unitPrice:
          ((map['unit_price'] ?? map['unitPrice'] ?? 0.0) as num).toDouble(),
      totalPrice:
          ((map['total_price'] ?? map['totalPrice'] ?? 0.0) as num).toDouble(),
      updatedAt: (map['updated_at'] ?? map['updatedAt'] ?? '') as String,
    );
  }
}
