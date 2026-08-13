class PartEntity {
  final String id;
  final String name;
  final String sku;
  final double price;
  final double costPrice;
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
      'price': price,
      'cost_price': costPrice,
      'stock_quantity': stockQuantity,
      'updated_at': updatedAt,
    };
  }

  factory PartEntity.fromMap(Map<String, dynamic> map) {
    return PartEntity(
      id: map['id'] as String,
      name: map['name'] as String,
      sku: map['sku'] as String,
      price: (map['price'] as num).toDouble(),
      costPrice: ((map['cost_price'] ?? map['costPrice'] ?? 0.0) as num).toDouble(),
      stockQuantity: (map['stock_quantity'] ?? map['stockQuantity'] ?? 0) as int,
      updatedAt: (map['updated_at'] ?? map['updatedAt'] ?? '') as String,
    );
  }
}
