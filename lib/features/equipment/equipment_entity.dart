import '../../core/domain/unsupported_domain_value_exception.dart';

enum EquipmentOwnerType {
  customer('CUSTOMER'),
  organization('ORGANIZATION');

  const EquipmentOwnerType(this.wireValue);

  final String wireValue;

  static EquipmentOwnerType fromDbValue(Object? value) {
    switch (value) {
      case 'CUSTOMER':
        return EquipmentOwnerType.customer;
      case 'ORGANIZATION':
        return EquipmentOwnerType.organization;
      default:
        throw UnsupportedDomainValueException(
          field: 'Equipment.ownerType',
          receivedValue: value,
        );
    }
  }
}

enum EquipmentOrganizationPurpose {
  resale('RESALE'),
  partsDonor('PARTS_DONOR'),
  internalUse('INTERNAL_USE');

  const EquipmentOrganizationPurpose(this.wireValue);

  final String wireValue;

  static EquipmentOrganizationPurpose? fromNullableDbValue(Object? value) {
    if (value == null) return null;
    switch (value) {
      case 'RESALE':
        return EquipmentOrganizationPurpose.resale;
      case 'PARTS_DONOR':
        return EquipmentOrganizationPurpose.partsDonor;
      case 'INTERNAL_USE':
        return EquipmentOrganizationPurpose.internalUse;
      default:
        throw UnsupportedDomainValueException(
          field: 'Equipment.organizationPurpose',
          receivedValue: value,
        );
    }
  }
}

class EquipmentEntity {
  final String id;
  final String? customerId;
  final String? organizationId;
  final EquipmentOwnerType ownerType;
  final EquipmentOrganizationPurpose? organizationPurpose;
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
    this.ownerType = EquipmentOwnerType.customer,
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
      'owner_type': ownerType.wireValue,
      'organization_purpose': organizationPurpose?.wireValue,
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
      organizationId:
          (map['organization_id'] ?? map['organizationId']) as String?,
      ownerType: EquipmentOwnerType.fromDbValue(
        map['owner_type'] ?? map['ownerType'],
      ),
      organizationPurpose: EquipmentOrganizationPurpose.fromNullableDbValue(
        map['organization_purpose'] ?? map['organizationPurpose'],
      ),
      type: map['type'] as String,
      brand: map['brand'] as String,
      model: map['model'] as String,
      serialNumber: (map['serial_number'] ?? map['serialNumber']) as String?,
      notes: map['notes'] as String?,
      updatedAt: (map['updated_at'] ?? map['updatedAt'] ?? '') as String,
    );
  }
}
