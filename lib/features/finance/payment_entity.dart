enum PaymentMethod { dinheiro, cartaoCredito, cartaoDebito, pix, transferencia, boleto }

extension PaymentMethodExtension on PaymentMethod {
  String toDbString() {
    switch (this) {
      case PaymentMethod.dinheiro:
        return 'DINHEIRO';
      case PaymentMethod.cartaoCredito:
        return 'CARTAO_CREDITO';
      case PaymentMethod.cartaoDebito:
        return 'CARTAO_DEBITO';
      case PaymentMethod.pix:
        return 'PIX';
      case PaymentMethod.transferencia:
        return 'TRANSFERENCIA';
      case PaymentMethod.boleto:
        return 'BOLETO';
    }
  }

  String get label {
    switch (this) {
      case PaymentMethod.dinheiro:
        return 'Dinheiro';
      case PaymentMethod.cartaoCredito:
        return 'Cartão de Crédito';
      case PaymentMethod.cartaoDebito:
        return 'Cartão de Débito';
      case PaymentMethod.pix:
        return 'PIX';
      case PaymentMethod.transferencia:
        return 'Transferência';
      case PaymentMethod.boleto:
        return 'Boleto';
    }
  }

  static PaymentMethod fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'CARTAO_CREDITO':
        return PaymentMethod.cartaoCredito;
      case 'CARTAO_DEBITO':
        return PaymentMethod.cartaoDebito;
      case 'PIX':
        return PaymentMethod.pix;
      case 'TRANSFERENCIA':
        return PaymentMethod.transferencia;
      case 'BOLETO':
        return PaymentMethod.boleto;
      case 'DINHEIRO':
      default:
        return PaymentMethod.dinheiro;
    }
  }
}

enum PaymentStatus { pending, confirmed, cancelled, refunded }

extension PaymentStatusExtension on PaymentStatus {
  String toDbString() {
    switch (this) {
      case PaymentStatus.pending:
        return 'PENDING';
      case PaymentStatus.confirmed:
        return 'CONFIRMED';
      case PaymentStatus.cancelled:
        return 'CANCELLED';
      case PaymentStatus.refunded:
        return 'REFUNDED';
    }
  }

  String get label {
    switch (this) {
      case PaymentStatus.pending:
        return 'Pendente';
      case PaymentStatus.confirmed:
        return 'Confirmado';
      case PaymentStatus.cancelled:
        return 'Cancelado';
      case PaymentStatus.refunded:
        return 'Estornado';
    }
  }

  static PaymentStatus fromDbString(String value) {
    switch (value.toUpperCase()) {
      case 'CONFIRMED':
        return PaymentStatus.confirmed;
      case 'CANCELLED':
        return PaymentStatus.cancelled;
      case 'REFUNDED':
        return PaymentStatus.refunded;
      case 'PENDING':
      default:
        return PaymentStatus.pending;
    }
  }
}

class PaymentEntity {
  final String id;
  final String serviceOrderId;
  final String customerId;
  final double amount;
  final PaymentMethod method;
  final PaymentStatus status;
  final String? notes;
  final String? paidAt;
  final String createdAt;
  final String updatedAt;

  PaymentEntity({
    required this.id,
    required this.serviceOrderId,
    required this.customerId,
    required this.amount,
    required this.method,
    this.status = PaymentStatus.pending,
    this.notes,
    this.paidAt,
    required this.createdAt,
    required this.updatedAt,
  });

  PaymentEntity copyWith({
    String? id,
    String? serviceOrderId,
    String? customerId,
    double? amount,
    PaymentMethod? method,
    PaymentStatus? status,
    String? notes,
    String? paidAt,
    String? createdAt,
    String? updatedAt,
  }) {
    return PaymentEntity(
      id: id ?? this.id,
      serviceOrderId: serviceOrderId ?? this.serviceOrderId,
      customerId: customerId ?? this.customerId,
      amount: amount ?? this.amount,
      method: method ?? this.method,
      status: status ?? this.status,
      notes: notes ?? this.notes,
      paidAt: paidAt ?? this.paidAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'service_order_id': serviceOrderId,
      'customer_id': customerId,
      'amount': amount,
      'method': method.toDbString(),
      'status': status.toDbString(),
      'notes': notes,
      'paid_at': paidAt,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  factory PaymentEntity.fromMap(Map<String, dynamic> map) {
    return PaymentEntity(
      id: map['id'] as String,
      serviceOrderId: map['service_order_id'] as String,
      customerId: map['customer_id'] as String,
      amount: (map['amount'] as num).toDouble(),
      method: PaymentMethodExtension.fromDbString(map['method'] as String),
      status: PaymentStatusExtension.fromDbString(map['status'] as String),
      notes: map['notes'] as String?,
      paidAt: map['paid_at'] as String?,
      createdAt: map['created_at'] as String,
      updatedAt: map['updated_at'] as String,
    );
  }
}
