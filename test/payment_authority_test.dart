import 'dart:async';

import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/finance/payment_command_gateway.dart';
import 'package:assistailab/features/finance/payment_entity.dart';
import 'package:assistailab/features/finance/payments_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backend-authoritative payment commands', () {
    for (final requested in const [
      PaymentStatus.confirmed,
      PaymentStatus.cancelled,
    ]) {
      test('$requested is not published before Backend success', () async {
        final pending = _payment(PaymentStatus.pending);
        var local = pending;
        final response = Completer<PaymentEntity>();
        final coordinator = PaymentAuthorityCoordinator(
          gateway: _Gateway(onTransition: () => response.future),
          commit: (payment) async => local = payment,
        );

        final command = coordinator.transition(
          operationId: 'op-1',
          paymentId: pending.id,
          status: requested,
        );
        await Future<void>.delayed(Duration.zero);
        expect(local.status, PaymentStatus.pending);

        response.complete(pending.copyWith(status: requested));
        await command;
        expect(local.status, requested);
      });

      test('$requested failure preserves the prior snapshot', () async {
        final pending = _payment(PaymentStatus.pending);
        var local = pending;
        final coordinator = PaymentAuthorityCoordinator(
          gateway: _Gateway(
            onTransition: () async => throw const PaymentCommandException(
              409,
              'PAYMENT_TRANSITION_REJECTED',
            ),
          ),
          commit: (payment) async => local = payment,
        );

        await expectLater(
          coordinator.transition(
            operationId: 'op-2',
            paymentId: pending.id,
            status: requested,
          ),
          throwsA(isA<PaymentCommandException>()),
        );
        expect(local.status, PaymentStatus.pending);
      });
    }
  });

  test('confirmed revenue by method is accumulated exactly in minor units', () {
    final totals = aggregateConfirmedRevenueByMethod([
      _payment(PaymentStatus.confirmed,
          amount: MoneyMinor(10), method: PaymentMethod.pix),
      _payment(PaymentStatus.confirmed,
          amount: MoneyMinor(20), method: PaymentMethod.pix),
      _payment(PaymentStatus.confirmed,
          amount: MoneyMinor(7), method: PaymentMethod.dinheiro),
      _payment(PaymentStatus.pending,
          amount: MoneyMinor(999), method: PaymentMethod.pix),
    ]);

    expect(totals[PaymentMethod.pix], MoneyMinor(30));
    expect(totals[PaymentMethod.dinheiro], MoneyMinor(7));
  });
}

PaymentEntity _payment(
  PaymentStatus status, {
  MoneyMinor? amount,
  PaymentMethod method = PaymentMethod.pix,
}) {
  return PaymentEntity(
    id: 'payment-1',
    serviceOrderId: 'order-1',
    customerId: 'customer-1',
    amount: amount ?? MoneyMinor(12345),
    method: method,
    status: status,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
  );
}

final class _Gateway implements PaymentCommandGateway {
  final Future<PaymentEntity> Function() onTransition;

  const _Gateway({required this.onTransition});

  @override
  Future<PaymentEntity> transition({
    required String operationId,
    required String paymentId,
    required PaymentStatus status,
  }) =>
      onTransition();

  @override
  Future<PaymentEntity> create({
    required String operationId,
    required String serviceOrderId,
    required MoneyMinor amount,
    required PaymentMethod method,
    String? notes,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<PaymentEntity>> listAll() => throw UnimplementedError();
}
