import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:assistailab/features/service_orders/service_orders_provider.dart';

void main() {
  group('Service Order State Machine Tests', () {
    test('DIAGNOSTICO allows transition to AGUARDANDO_APROVACAO and CANCELADO',
        () {
      final allowed = allowedTransitionsFor(ServiceOrderStatusEnum.diagnostico);
      expect(allowed, contains(ServiceOrderStatusEnum.aguardandoAprovacao));
      expect(allowed, contains(ServiceOrderStatusEnum.cancelado));
      expect(allowed, isNot(contains(ServiceOrderStatusEnum.entregue)));
    });

    test('ENTREGUE has no allowed transitions', () {
      final allowed = allowedTransitionsFor(ServiceOrderStatusEnum.entregue);
      expect(allowed, isEmpty);
    });

    test('PRONTO allows ENTREGUE and CANCELADO', () {
      final allowed = allowedTransitionsFor(ServiceOrderStatusEnum.pronto);
      expect(allowed, contains(ServiceOrderStatusEnum.entregue));
      expect(allowed, contains(ServiceOrderStatusEnum.cancelado));
    });

    test('EM_EXECUCAO does NOT allow going to AGUARDANDO_APROVACAO', () {
      final allowed = allowedTransitionsFor(ServiceOrderStatusEnum.emExecucao);
      expect(
          allowed, isNot(contains(ServiceOrderStatusEnum.aguardandoAprovacao)));
    });
  });

  group('ServiceOrderEntity Serialization', () {
    test('toMap and fromMap round-trips correctly', () {
      final order = ServiceOrderEntity(
        id: 'abc-123',
        customerId: 'cust-01',
        equipmentId: 'eq-01',
        status: ServiceOrderStatusEnum.emExecucao,
        problemDescription: 'Tela quebrada',
        totalAmount: 450.0,
        updatedAt: '2026-08-11T10:00:00Z',
      );

      final map = order.toMap();
      expect(map['status'], equals('EM_EXECUCAO'));

      final restored = ServiceOrderEntity.fromMap(map);
      expect(restored.id, equals(order.id));
      expect(restored.status, equals(ServiceOrderStatusEnum.emExecucao));
      expect(restored.totalAmount, equals(450.0));
    });
  });
}
