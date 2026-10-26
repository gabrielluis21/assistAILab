import '../../core/domain/unsupported_domain_value_exception.dart';

enum EquipmentAcquisitionSource {
  serviceOrder('SERVICE_ORDER'),
  directOffer('DIRECT_OFFER');

  const EquipmentAcquisitionSource(this.wireValue);

  final String wireValue;

  static EquipmentAcquisitionSource fromValue(Object? value) => switch (value) {
        'SERVICE_ORDER' => EquipmentAcquisitionSource.serviceOrder,
        'DIRECT_OFFER' => EquipmentAcquisitionSource.directOffer,
        _ => throw UnsupportedDomainValueException(
            field: 'EquipmentAcquisition.source',
            receivedValue: value,
          ),
      };
}

enum EquipmentAcquisitionPurpose {
  resale('RESALE'),
  partsDonor('PARTS_DONOR');

  const EquipmentAcquisitionPurpose(this.wireValue);

  final String wireValue;

  static EquipmentAcquisitionPurpose fromValue(Object? value) =>
      switch (value) {
        'RESALE' => EquipmentAcquisitionPurpose.resale,
        'PARTS_DONOR' => EquipmentAcquisitionPurpose.partsDonor,
        _ => throw UnsupportedDomainValueException(
            field: 'EquipmentAcquisition.purpose',
            receivedValue: value,
          ),
      };
}

enum EquipmentAcquisitionStatus {
  pending('PENDING'),
  authorized('AUTHORIZED'),
  rejected('REJECTED'),
  cancelled('CANCELLED'),
  completed('COMPLETED');

  const EquipmentAcquisitionStatus(this.wireValue);

  final String wireValue;

  bool get isTerminal => switch (this) {
        EquipmentAcquisitionStatus.rejected ||
        EquipmentAcquisitionStatus.cancelled ||
        EquipmentAcquisitionStatus.completed =>
          true,
        _ => false,
      };

  static EquipmentAcquisitionStatus fromValue(Object? value) => switch (value) {
        'PENDING' => EquipmentAcquisitionStatus.pending,
        'AUTHORIZED' => EquipmentAcquisitionStatus.authorized,
        'REJECTED' => EquipmentAcquisitionStatus.rejected,
        'CANCELLED' => EquipmentAcquisitionStatus.cancelled,
        'COMPLETED' => EquipmentAcquisitionStatus.completed,
        _ => throw UnsupportedDomainValueException(
            field: 'EquipmentAcquisition.status',
            receivedValue: value,
          ),
      };
}

enum EquipmentConsentMethod {
  customerApp('CUSTOMER_APP'),
  qrCode('QR_CODE'),
  digitalSignature('DIGITAL_SIGNATURE'),
  signedDocument('SIGNED_DOCUMENT'),
  inPersonAssisted('IN_PERSON_ASSISTED');

  const EquipmentConsentMethod(this.wireValue);

  final String wireValue;

  bool get isCustomerSelectable => this != inPersonAssisted;

  static EquipmentConsentMethod? fromNullableValue(Object? value) =>
      switch (value) {
        null => null,
        'CUSTOMER_APP' => EquipmentConsentMethod.customerApp,
        'QR_CODE' => EquipmentConsentMethod.qrCode,
        'DIGITAL_SIGNATURE' => EquipmentConsentMethod.digitalSignature,
        'SIGNED_DOCUMENT' => EquipmentConsentMethod.signedDocument,
        'IN_PERSON_ASSISTED' => EquipmentConsentMethod.inPersonAssisted,
        _ => throw UnsupportedDomainValueException(
            field: 'EquipmentAcquisition.consentMethod',
            receivedValue: value,
          ),
      };
}

final class EquipmentAcquisitionEntity {
  const EquipmentAcquisitionEntity({
    required this.id,
    required this.equipmentId,
    required this.customerId,
    required this.organizationId,
    required this.serviceOrderId,
    required this.source,
    required this.clientPreAcquisitionId,
    required this.purpose,
    required this.status,
    required this.offeredAmountMinor,
    required this.consentMethod,
    required this.authorizedAt,
    required this.rejectedAt,
    required this.cancelledAt,
    required this.completedAt,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String equipmentId;
  final String customerId;
  final String organizationId;
  final String? serviceOrderId;
  final EquipmentAcquisitionSource source;
  final String? clientPreAcquisitionId;
  final EquipmentAcquisitionPurpose purpose;
  final EquipmentAcquisitionStatus status;
  final int? offeredAmountMinor;
  final EquipmentConsentMethod? consentMethod;
  final String? authorizedAt;
  final String? rejectedAt;
  final String? cancelledAt;
  final String? completedAt;
  final String? notes;
  final String createdAt;
  final String updatedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'equipment_id': equipmentId,
        'customer_id': customerId,
        'organization_id': organizationId,
        'service_order_id': serviceOrderId,
        'source': source.wireValue,
        'client_pre_acquisition_id': clientPreAcquisitionId,
        'purpose': purpose.wireValue,
        'status': status.wireValue,
        'offered_amount_minor': offeredAmountMinor,
        'consent_method': consentMethod?.wireValue,
        'authorized_at': authorizedAt,
        'rejected_at': rejectedAt,
        'cancelled_at': cancelledAt,
        'completed_at': completedAt,
        'notes': notes,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory EquipmentAcquisitionEntity.fromMap(Map<String, Object?> map) {
    final source = EquipmentAcquisitionSource.fromValue(
      map['source'],
    );
    final serviceOrderId = map['service_order_id'] as String?;
    _validateSourceCorrelation(source, serviceOrderId);
    return EquipmentAcquisitionEntity(
      id: _requiredText(map['id'], 'id'),
      equipmentId: _requiredText(map['equipment_id'], 'equipmentId'),
      customerId: _requiredText(map['customer_id'], 'customerId'),
      organizationId: _requiredText(map['organization_id'], 'organizationId'),
      serviceOrderId: serviceOrderId,
      source: source,
      clientPreAcquisitionId: map['client_pre_acquisition_id'] as String?,
      purpose: EquipmentAcquisitionPurpose.fromValue(map['purpose']),
      status: EquipmentAcquisitionStatus.fromValue(map['status']),
      offeredAmountMinor: _optionalPositiveMinor(
        map['offered_amount_minor'],
      ),
      consentMethod:
          EquipmentConsentMethod.fromNullableValue(map['consent_method']),
      authorizedAt: _optionalDate(map['authorized_at'], 'authorizedAt'),
      rejectedAt: _optionalDate(map['rejected_at'], 'rejectedAt'),
      cancelledAt: _optionalDate(map['cancelled_at'], 'cancelledAt'),
      completedAt: _optionalDate(map['completed_at'], 'completedAt'),
      notes: map['notes'] as String?,
      createdAt: _requiredDate(map['created_at'], 'createdAt'),
      updatedAt: _requiredDate(map['updated_at'], 'updatedAt'),
    );
  }

  factory EquipmentAcquisitionEntity.fromWire(Map<String, dynamic> wire) {
    final source = EquipmentAcquisitionSource.fromValue(wire['source']);
    final serviceOrderId = wire['serviceOrderId'];
    if (serviceOrderId != null && serviceOrderId is! String) {
      throw const FormatException('Invalid acquisition serviceOrderId.');
    }
    _validateSourceCorrelation(source, serviceOrderId as String?);
    final notes = wire['notes'];
    if (notes != null && notes is! String) {
      throw const FormatException('Invalid acquisition notes.');
    }
    final clientPreAcquisitionId = wire['clientPreAcquisitionId'];
    if (clientPreAcquisitionId != null && clientPreAcquisitionId is! String) {
      throw const FormatException(
        'Invalid acquisition clientPreAcquisitionId.',
      );
    }
    final equipmentId = _requiredText(wire['equipmentId'], 'equipmentId');
    return EquipmentAcquisitionEntity(
      id: _requiredText(wire['id'], 'id'),
      equipmentId: equipmentId,
      customerId: _requiredText(wire['customerId'], 'customerId'),
      organizationId: _requiredText(wire['organizationId'], 'organizationId'),
      serviceOrderId: serviceOrderId,
      source: source,
      clientPreAcquisitionId: clientPreAcquisitionId as String?,
      purpose: EquipmentAcquisitionPurpose.fromValue(wire['purpose']),
      status: EquipmentAcquisitionStatus.fromValue(wire['status']),
      offeredAmountMinor: _optionalPositiveMinor(wire['offeredAmountMinor']),
      consentMethod:
          EquipmentConsentMethod.fromNullableValue(wire['consentMethod']),
      authorizedAt: _optionalDate(wire['authorizedAt'], 'authorizedAt'),
      rejectedAt: _optionalDate(wire['rejectedAt'], 'rejectedAt'),
      cancelledAt: _optionalDate(wire['cancelledAt'], 'cancelledAt'),
      completedAt: _optionalDate(wire['completedAt'], 'completedAt'),
      notes: notes as String?,
      createdAt: _requiredDate(wire['createdAt'], 'createdAt'),
      updatedAt: _requiredDate(wire['updatedAt'], 'updatedAt'),
    );
  }
}

void _validateSourceCorrelation(
  EquipmentAcquisitionSource source,
  String? serviceOrderId,
) {
  if (source == EquipmentAcquisitionSource.serviceOrder &&
      (serviceOrderId == null || serviceOrderId.isEmpty)) {
    throw const FormatException(
      'SERVICE_ORDER acquisition requires serviceOrderId.',
    );
  }
  if (source == EquipmentAcquisitionSource.directOffer &&
      serviceOrderId != null) {
    throw const FormatException(
      'DIRECT_OFFER acquisition forbids serviceOrderId.',
    );
  }
}

String _requiredText(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid acquisition $field.');
  }
  return value;
}

String _requiredDate(Object? value, String field) {
  if (value is! String || DateTime.tryParse(value) == null) {
    throw FormatException('Invalid acquisition $field.');
  }
  return value;
}

String? _optionalDate(Object? value, String field) {
  if (value == null) return null;
  return _requiredDate(value, field);
}

int? _optionalPositiveMinor(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 1 || value > 9999999999) {
    throw const FormatException('Invalid acquisition offeredAmountMinor.');
  }
  return value;
}
