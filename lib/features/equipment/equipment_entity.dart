class EquipmentEntity {
  final String id;
  final String? customerId;
  final String? organizationId;
  final String ownerType; // 'CUSTOMER' | 'ORGANIZATION'
  final String? organizationPurpose; // 'RESALE' | 'PARTS_DONOR' | 'INTERNAL_USE' | null
  final String type;
  final String brand;
  final String model;
  final String? serialNumber;
  final String? notes;
  final String updatedAt;

  EquipmentEntity({
    required this.id,
    this.customerId,
    this.organizationId,
    this.ownerType = 'CUSTOMER',
    this.organizationPurpose,
    required this.type,
    required this.brand,
    required this.model,
    this.serialNumber,
    this.notes,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'customer_id': customerId,
      'organization_id': organizationId,
      'owner_type': ownerType,
      'organization_purpose': organizationPurpose,
      'type': type,
      'brand': brand,
      'model': model,
      'serial_number': serialNumber,
      'notes': notes,
      'updated_at': updatedAt,
    };
  }

  factory EquipmentEntity.fromMap(Map<String, dynamic> map) {
    return EquipmentEntity(
      id: map['id'] as String,
      customerId: (map['customer_id'] ?? map['customerId']) as String?,
      organizationId: (map['organization_id'] ?? map['organizationId']) as String?,
      ownerType: (map['owner_type'] ?? map['ownerType'] ?? 'CUSTOMER') as String,
      organizationPurpose: (map['organization_purpose'] ?? map['organizationPurpose']) as String?,
      type: map['type'] as String,
      brand: map['brand'] as String,
      model: map['model'] as String,
      serialNumber: (map['serial_number'] ?? map['serialNumber']) as String?,
      notes: map['notes'] as String?,
      updatedAt: (map['updated_at'] ?? map['updatedAt'] ?? '') as String,
    );
  }
}
