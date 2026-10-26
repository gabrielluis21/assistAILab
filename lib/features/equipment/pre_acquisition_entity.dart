import '../../core/domain/unsupported_domain_value_exception.dart';

enum PreAcquisitionStatus {
  pendingEvaluation('PENDING_EVALUATION'),
  approved('APPROVED'),
  rejected('REJECTED'),
  expired('EXPIRED'),
  cancelled('CANCELLED');

  const PreAcquisitionStatus(this.wireValue);

  final String wireValue;

  bool get isTerminal => switch (this) {
        PreAcquisitionStatus.rejected ||
        PreAcquisitionStatus.expired ||
        PreAcquisitionStatus.cancelled =>
          true,
        _ => false,
      };

  static PreAcquisitionStatus fromDbValue(Object? value) {
    for (final status in PreAcquisitionStatus.values) {
      if (status.wireValue == value) return status;
    }
    throw UnsupportedDomainValueException(
      field: 'PreAcquisition.status',
      receivedValue: value,
    );
  }
}

enum PreAcquisitionPurpose {
  resale('RESALE'),
  partsDonor('PARTS_DONOR');

  const PreAcquisitionPurpose(this.wireValue);

  final String wireValue;

  static PreAcquisitionPurpose fromDbValue(Object? value) => switch (value) {
        'RESALE' => PreAcquisitionPurpose.resale,
        'PARTS_DONOR' => PreAcquisitionPurpose.partsDonor,
        _ => throw UnsupportedDomainValueException(
            field: 'PreAcquisition.purpose',
            receivedValue: value,
          ),
      };
}

class PreAcquisitionEntity {
  final String id;
  final String equipmentId;
  final String customerId;
  final String organizationId;
  final String? serviceOrderId;
  final PreAcquisitionPurpose purpose;
  final PreAcquisitionStatus status;
  final int? offeredAmountMinor;
  final String? notes;
  final String createdAt;
  final String evaluationDeadline;
  final String? evaluatedAt;
  final String? resolutionReason;

  const PreAcquisitionEntity({
    required this.id,
    required this.equipmentId,
    required this.customerId,
    required this.organizationId,
    this.serviceOrderId,
    required this.purpose,
    required this.status,
    this.offeredAmountMinor,
    this.notes,
    required this.createdAt,
    required this.evaluationDeadline,
    this.evaluatedAt,
    this.resolutionReason,
  });

  PreAcquisitionEntity copyWith({
    PreAcquisitionStatus? status,
    String? evaluatedAt,
    String? resolutionReason,
  }) {
    return PreAcquisitionEntity(
      id: id,
      equipmentId: equipmentId,
      customerId: customerId,
      organizationId: organizationId,
      serviceOrderId: serviceOrderId,
      purpose: purpose,
      status: status ?? this.status,
      offeredAmountMinor: offeredAmountMinor,
      notes: notes,
      createdAt: createdAt,
      evaluationDeadline: evaluationDeadline,
      evaluatedAt: evaluatedAt ?? this.evaluatedAt,
      resolutionReason: resolutionReason ?? this.resolutionReason,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'equipment_id': equipmentId,
      'customer_id': customerId,
      'organization_id': organizationId,
      'service_order_id': serviceOrderId,
      'purpose': purpose.wireValue,
      'status': status.wireValue,
      'offered_amount_minor': offeredAmountMinor,
      'notes': notes,
      'created_at': createdAt,
      'evaluation_deadline': evaluationDeadline,
      'evaluated_at': evaluatedAt,
      'resolution_reason': resolutionReason,
    };
  }

  Map<String, dynamic> toOutboxPayload() {
    return {
      'equipmentId': equipmentId,
      'customerId': customerId,
      'organizationId': organizationId,
      'serviceOrderId': serviceOrderId,
      'purpose': purpose.wireValue,
      'status': status.wireValue,
      'offeredAmountMinor': offeredAmountMinor,
      'notes': notes,
      'createdAt': createdAt,
      'evaluationDeadline': evaluationDeadline,
      'evaluatedAt': evaluatedAt,
      'resolutionReason': resolutionReason,
    };
  }

  factory PreAcquisitionEntity.fromMap(Map<String, Object?> map) {
    final offeredAmountMinor = map['offered_amount_minor'];
    if (offeredAmountMinor != null &&
        (offeredAmountMinor is! int ||
            offeredAmountMinor < 1 ||
            offeredAmountMinor > 9999999999)) {
      throw const FormatException(
        'Invalid PreAcquisition.offeredAmountMinor.',
      );
    }
    return PreAcquisitionEntity(
      id: map['id'] as String,
      equipmentId: map['equipment_id'] as String,
      customerId: map['customer_id'] as String,
      organizationId: map['organization_id'] as String,
      serviceOrderId: map['service_order_id'] as String?,
      purpose: PreAcquisitionPurpose.fromDbValue(map['purpose']),
      status: PreAcquisitionStatus.fromDbValue(map['status']),
      offeredAmountMinor: offeredAmountMinor as int?,
      notes: map['notes'] as String?,
      createdAt: map['created_at'] as String,
      evaluationDeadline: map['evaluation_deadline'] as String,
      evaluatedAt: map['evaluated_at'] as String?,
      resolutionReason: map['resolution_reason'] as String?,
    );
  }
}
