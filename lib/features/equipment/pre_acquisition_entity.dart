import '../../core/domain/unsupported_domain_value_exception.dart';

enum PreAcquisitionStatus {
  pendingEvaluation('PENDING_EVALUATION'),
  approved('APPROVED'),
  rejected('REJECTED'),
  expired('EXPIRED'),
  cancelled('CANCELLED');

  const PreAcquisitionStatus(this.wireValue);

  final String wireValue;

  bool get isTerminal => this != PreAcquisitionStatus.pendingEvaluation;

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

class PreAcquisitionEntity {
  final String id;
  final String equipmentId;
  final String customerId;
  final String organizationId;
  final String? serviceOrderId;
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
    required this.status,
    this.offeredAmountMinor,
    this.notes,
    required this.createdAt,
    required this.evaluationDeadline,
    this.evaluatedAt,
    this.resolutionReason,
  });

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'equipment_id': equipmentId,
      'customer_id': customerId,
      'organization_id': organizationId,
      'service_order_id': serviceOrderId,
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
    return PreAcquisitionEntity(
      id: map['id'] as String,
      equipmentId: map['equipment_id'] as String,
      customerId: map['customer_id'] as String,
      organizationId: map['organization_id'] as String,
      serviceOrderId: map['service_order_id'] as String?,
      status: PreAcquisitionStatus.fromDbValue(map['status']),
      offeredAmountMinor: map['offered_amount_minor'] as int?,
      notes: map['notes'] as String?,
      createdAt: map['created_at'] as String,
      evaluationDeadline: map['evaluation_deadline'] as String,
      evaluatedAt: map['evaluated_at'] as String?,
      resolutionReason: map['resolution_reason'] as String?,
    );
  }
}
