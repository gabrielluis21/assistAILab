import '../../core/money/money_minor.dart';

class PartEntity {
  final String id;
  final String name;
  final String sku;
  final MoneyMinor price;
  final MoneyMinor costPrice;
  final int stockQuantity;
  final String updatedAt;

  PartEntity({
    required this.id,
    required this.name,
    required this.sku,
    required this.price,
    required this.costPrice,
    required this.stockQuantity,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'sku': sku,
      'price_minor': price.minorUnits,
      'cost_price_minor': costPrice.minorUnits,
      'stock_quantity': stockQuantity,
      'updated_at': updatedAt,
    };
  }

  factory PartEntity.fromMap(Map<String, dynamic> map) {
    return PartEntity(
      id: map['id'] as String,
      name: map['name'] as String,
      sku: map['sku'] as String,
      price: MoneyMinor.serviceOrderFromJson(map['price_minor']),
      costPrice: MoneyMinor.serviceOrderFromJson(map['cost_price_minor']),
      stockQuantity:
          (map['stock_quantity'] ?? map['stockQuantity'] ?? 0) as int,
      updatedAt: (map['updated_at'] ?? map['updatedAt'] ?? '') as String,
    );
  }
}
