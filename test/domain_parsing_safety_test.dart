import 'package:assistailab/core/domain/unsupported_domain_value_exception.dart';
import 'package:assistailab/features/equipment/equipment_entity.dart';
import 'package:assistailab/features/finance/payment_entity.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:assistailab/features/service_orders/service_orders_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const unsupportedValues = <Object?>[
    'UNKNOWN',
    'FUTURE_BACKEND_VALUE',
    '',
    'pending',
    null,
    1,
  ];

  group('ServiceOrderStatus external parsing', () {
    const values = <String, ServiceOrderStatusEnum>{
      'DRAFT': ServiceOrderStatusEnum.draft,
      'DIAGNOSTICO': ServiceOrderStatusEnum.diagnostico,
      'AGUARDANDO_APROVACAO': ServiceOrderStatusEnum.aguardandoAprovacao,
      'AGUARDANDO_REAPROVACAO': ServiceOrderStatusEnum.aguardandoReaprovacao,
      'EM_EXECUCAO': ServiceOrderStatusEnum.emExecucao,
      'PRONTO': ServiceOrderStatusEnum.pronto,
      'ENTREGUE': ServiceOrderStatusEnum.entregue,
      'CANCELADO': ServiceOrderStatusEnum.cancelado,
    };

    test('every valid wire value parses and round-trips exactly', () {
      for (final entry in values.entries) {
        final parsed = ServiceOrderStatusExtension.fromDbString(entry.key);
        expect(parsed, entry.value);
        expect(parsed.toDbString(), entry.key);
      }
    });

    test('unknown, malformed, wrong-case, and missing values fail closed', () {
      for (final value in <Object?>[...unsupportedValues, 'draft']) {
        expect(
          () => ServiceOrderStatusExtension.fromDbString(value),
          throwsA(isA<UnsupportedDomainValueException>()),
          reason: 'value: $value',
        );
      }
    });

    test('external entity decode cannot invent a missing status', () {
      final map = _serviceOrderMap()..remove('status');

      expect(
        () => ServiceOrderEntity.fromMap(map),
        throwsA(isA<UnsupportedDomainValueException>()),
      );
    });

    test('reapproval has its own presentation and no local transitions', () {
      expect(
        ServiceOrderStatusEnum.aguardandoReaprovacao.label,
        'Aguardando reaprovação',
      );
      expect(
        allowedTransitionsFor(
          ServiceOrderStatusEnum.aguardandoReaprovacao,
        ),
        isEmpty,
      );
      for (final status in ServiceOrderStatusEnum.values) {
        expect(
          allowedTransitionsFor(status),
          isNot(contains(ServiceOrderStatusEnum.aguardandoReaprovacao)),
        );
      }
    });
  });

  group('PaymentMethod external parsing', () {
    const values = <String, PaymentMethod>{
      'DINHEIRO': PaymentMethod.dinheiro,
      'CARTAO_CREDITO': PaymentMethod.cartaoCredito,
      'CARTAO_DEBITO': PaymentMethod.cartaoDebito,
      'PIX': PaymentMethod.pix,
      'TRANSFERENCIA': PaymentMethod.transferencia,
      'BOLETO': PaymentMethod.boleto,
    };

    test('every valid wire value parses exactly', () {
      for (final entry in values.entries) {
        final parsed = PaymentMethodExtension.fromDbString(entry.key);
        expect(parsed, entry.value);
        expect(parsed.toDbString(), entry.key);
      }
    });

    test('unknown, malformed, wrong-case, and missing values fail closed', () {
      for (final value in <Object?>[...unsupportedValues, 'pix']) {
        expect(
          () => PaymentMethodExtension.fromDbString(value),
          throwsA(isA<UnsupportedDomainValueException>()),
          reason: 'value: $value',
        );
      }
    });

    test('external entity decode cannot invent a missing method', () {
      final map = _paymentMap()..remove('method');

      expect(
        () => PaymentEntity.fromMap(map),
        throwsA(isA<UnsupportedDomainValueException>()),
      );
    });
  });

  group('PaymentStatus provenance', () {
    const values = <String, PaymentStatus>{
      'PENDING': PaymentStatus.pending,
      'CONFIRMED': PaymentStatus.confirmed,
      'CANCELLED': PaymentStatus.cancelled,
      'REFUNDED': PaymentStatus.refunded,
    };

    test('every valid wire value parses exactly', () {
      for (final entry in values.entries) {
        final parsed = PaymentStatusExtension.fromDbString(entry.key);
        expect(parsed, entry.value);
        expect(parsed.toDbString(), entry.key);
      }
    });

    test('unknown, malformed, wrong-case, and missing values fail closed', () {
      for (final value in unsupportedValues) {
        expect(
          () => PaymentStatusExtension.fromDbString(value),
          throwsA(isA<UnsupportedDomainValueException>()),
          reason: 'value: $value',
        );
      }
    });

    test('external decode requires status while internal creation defaults it',
        () {
      final externalMap = _paymentMap()..remove('status');
      expect(
        () => PaymentEntity.fromMap(externalMap),
        throwsA(isA<UnsupportedDomainValueException>()),
      );

      final internalPayment = PaymentEntity(
        id: 'payment-local',
        serviceOrderId: 'order-1',
        customerId: 'customer-1',
        amount: 10.0,
        method: PaymentMethod.pix,
        createdAt: '2026-09-14T10:00:00Z',
        updatedAt: '2026-09-14T10:00:00Z',
      );
      expect(internalPayment.status, PaymentStatus.pending);
    });
  });

  group('Equipment external parsing', () {
    test('every valid owner wire value parses and serializes exactly', () {
      const values = <String, EquipmentOwnerType>{
        'CUSTOMER': EquipmentOwnerType.customer,
        'ORGANIZATION': EquipmentOwnerType.organization,
      };

      for (final entry in values.entries) {
        final parsed = EquipmentOwnerType.fromDbValue(entry.key);
        expect(parsed, entry.value);
        expect(parsed.wireValue, entry.key);
      }
    });

    test('every valid organization purpose parses and serializes exactly', () {
      const values = <String, EquipmentOrganizationPurpose>{
        'RESALE': EquipmentOrganizationPurpose.resale,
        'PARTS_DONOR': EquipmentOrganizationPurpose.partsDonor,
        'INTERNAL_USE': EquipmentOrganizationPurpose.internalUse,
      };

      for (final entry in values.entries) {
        final parsed =
            EquipmentOrganizationPurpose.fromNullableDbValue(entry.key);
        expect(parsed, entry.value);
        expect(parsed?.wireValue, entry.key);
      }
      expect(
        EquipmentOrganizationPurpose.fromNullableDbValue(null),
        isNull,
      );
    });

    test('unknown and missing owner values fail closed', () {
      for (final value in <Object?>[...unsupportedValues, 'customer']) {
        expect(
          () => EquipmentOwnerType.fromDbValue(value),
          throwsA(isA<UnsupportedDomainValueException>()),
          reason: 'value: $value',
        );
      }

      final map = _equipmentMap()..remove('owner_type');
      expect(
        () => EquipmentEntity.fromMap(map),
        throwsA(isA<UnsupportedDomainValueException>()),
      );
    });

    test('unknown organization purpose fails closed', () {
      for (final value in <Object?>[
        'UNKNOWN',
        'future_value',
        'resale',
        '',
        1,
      ]) {
        expect(
          () => EquipmentOrganizationPurpose.fromNullableDbValue(value),
          throwsA(isA<UnsupportedDomainValueException>()),
          reason: 'value: $value',
        );
      }
    });

    test('internal equipment creation retains the explicit customer default',
        () {
      final equipment = EquipmentEntity(
        id: 'equipment-local',
        customerId: 'customer-1',
        type: 'Notebook',
        brand: 'Brand',
        model: 'Model',
        updatedAt: '2026-09-14T10:00:00Z',
      );

      expect(equipment.ownerType, EquipmentOwnerType.customer);
      expect(equipment.toMap()['owner_type'], 'CUSTOMER');
    });
  });

  test('controlled failure reports only field and safe value description', () {
    const exception = UnsupportedDomainValueException(
      field: 'Payment.status',
      receivedValue: <String, Object?>{'unrelated': 'payload'},
    );

    expect(exception.field, 'Payment.status');
    expect(exception.toString(), contains('Payment.status'));
    expect(exception.toString(), contains('<'));
    expect(exception.toString(), isNot(contains('payload')));
  });
}

Map<String, dynamic> _serviceOrderMap() => <String, dynamic>{
      'id': 'order-1',
      'friendly_id': 1,
      'customer_id': 'customer-1',
      'equipment_id': 'equipment-1',
      'technician_id': null,
      'status': 'DIAGNOSTICO',
      'problem_description': 'Problem',
      'diagnosis': null,
      'solution': null,
      'total_amount': 0.0,
      'updated_at': '2026-09-14T10:00:00Z',
    };

Map<String, dynamic> _paymentMap() => <String, dynamic>{
      'id': 'payment-1',
      'service_order_id': 'order-1',
      'customer_id': 'customer-1',
      'amount': 10.0,
      'method': 'PIX',
      'status': 'PENDING',
      'notes': null,
      'paid_at': null,
      'created_at': '2026-09-14T10:00:00Z',
      'updated_at': '2026-09-14T10:00:00Z',
    };

Map<String, dynamic> _equipmentMap() => <String, dynamic>{
      'id': 'equipment-1',
      'customer_id': 'customer-1',
      'organization_id': null,
      'owner_type': 'CUSTOMER',
      'organization_purpose': null,
      'type': 'Notebook',
      'brand': 'Brand',
      'model': 'Model',
      'serial_number': null,
      'notes': null,
      'updated_at': '2026-09-14T10:00:00Z',
    };
