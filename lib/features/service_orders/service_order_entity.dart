enum ServiceOrderStatusEnum {
  draft,
  diagnostico,
  aguardandoAprovacao,
  emExecucao,
  pronto,
  entregue,
  cancelado,
}

extension ServiceOrderStatusExtension on ServiceOrderStatusEnum {
  String toDbString() {
    switch (this) {
      case ServiceOrderStatusEnum.draft:
        return 'DRAFT';
      case ServiceOrderStatusEnum.diagnostico:
        return 'DIAGNOSTICO';
      case ServiceOrderStatusEnum.aguardandoAprovacao:
        return 'AGUARDANDO_APROVACAO';
      case ServiceOrderStatusEnum.emExecucao:
        return 'EM_EXECUCAO';
      case ServiceOrderStatusEnum.pronto:
        return 'PRONTO';
      case ServiceOrderStatusEnum.entregue:
        return 'ENTREGUE';
      case ServiceOrderStatusEnum.cancelado:
        return 'CANCELADO';
    }
  }

  static ServiceOrderStatusEnum fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'DRAFT':
        return ServiceOrderStatusEnum.draft;
      case 'DIAGNOSTICO':
        return ServiceOrderStatusEnum.diagnostico;
      case 'AGUARDANDO_APROVACAO':
        return ServiceOrderStatusEnum.aguardandoAprovacao;
      case 'EM_EXECUCAO':
        return ServiceOrderStatusEnum.emExecucao;
      case 'PRONTO':
        return ServiceOrderStatusEnum.pronto;
      case 'ENTREGUE':
        return ServiceOrderStatusEnum.entregue;
      case 'CANCELADO':
      default:
        return ServiceOrderStatusEnum.cancelado;
    }
  }
}

class ServiceOrderEntity {
  final String id;
  final int? friendlyId;
  final String customerId;
  final String equipmentId;
  final String? technicianId;
  final ServiceOrderStatusEnum status;
  final String problemDescription;
  final String? diagnosis;
  final String? solution;
  final double totalAmount;
  final String updatedAt;

  ServiceOrderEntity({
    required this.id,
    this.friendlyId,
    required this.customerId,
    required this.equipmentId,
    this.technicianId,
    required this.status,
    required this.problemDescription,
    this.diagnosis,
    this.solution,
    this.totalAmount = 0.0,
    required this.updatedAt,
  });

  ServiceOrderEntity copyWith({
    String? id,
    int? friendlyId,
    String? customerId,
    String? equipmentId,
    String? technicianId,
    ServiceOrderStatusEnum? status,
    String? problemDescription,
    String? diagnosis,
    String? solution,
    double? totalAmount,
    String? updatedAt,
  }) {
    return ServiceOrderEntity(
      id: id ?? this.id,
      friendlyId: friendlyId ?? this.friendlyId,
      customerId: customerId ?? this.customerId,
      equipmentId: equipmentId ?? this.equipmentId,
      technicianId: technicianId ?? this.technicianId,
      status: status ?? this.status,
      problemDescription: problemDescription ?? this.problemDescription,
      diagnosis: diagnosis ?? this.diagnosis,
      solution: solution ?? this.solution,
      totalAmount: totalAmount ?? this.totalAmount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'friendly_id': friendlyId,
      'customer_id': customerId,
      'equipment_id': equipmentId,
      'technician_id': technicianId,
      'status': status.toDbString(),
      'problem_description': problemDescription,
      'diagnosis': diagnosis,
      'solution': solution,
      'total_amount': totalAmount,
      'updated_at': updatedAt,
    };
  }

  factory ServiceOrderEntity.fromMap(Map<String, dynamic> map) {
    return ServiceOrderEntity(
      id: map['id'],
      friendlyId: map['friendly_id'],
      customerId: map['customer_id'],
      equipmentId: map['equipment_id'],
      technicianId: map['technician_id'],
      status: ServiceOrderStatusExtension.fromDbString(map['status']),
      problemDescription: map['problem_description'],
      diagnosis: map['diagnosis'],
      solution: map['solution'],
      totalAmount: (map['total_amount'] as num?)?.toDouble() ?? 0.0,
      updatedAt: map['updated_at'],
    );
  }
}
