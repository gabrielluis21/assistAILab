import 'dart:async';

import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/finance/payment_command_gateway.dart';
import 'package:assistailab/features/finance/payment_command_intent.dart';
import 'package:assistailab/features/finance/payment_entity.dart';
import 'package:assistailab/features/finance/payment_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/payment_test_database.dart';

void main() {
  late Database db;
  late PaymentCommandIntentLocalDataSource intents;
  late PaymentLocalDataSource payments;

  setUp(() async {
    db = await openPaymentTestDatabase();
    intents = PaymentCommandIntentLocalDataSource(
      nowUtc: () => DateTime.utc(2026, 9, 17),
    );
    payments = PaymentLocalDataSource();
  });

  tearDown(() => db.close());

  test('CREATE timeout becomes UNKNOWN and retry reuses operationId', () async {
    var attempt = 0;
    final ids = <String>[];
    final gateway = _Gateway(
      onCreate: (operationId) async {
        ids.add(operationId);
        if (attempt++ == 0) throw TimeoutException('response lost');
        return _payment(id: 'payment-created');
      },
    );
    var factoryCalls = 0;
    final executor = _executor(
      db,
      gateway,
      payments,
      intents,
      () => 'op-${++factoryCalls}',
    );

    await expectLater(
      executor.create(
        serviceOrderId: 'order-1',
        amount: MoneyMinor(12345),
        method: PaymentMethod.pix,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect((await _intentRows(db)).single['lifecycle_state'], 'UNKNOWN');

    await executor.create(
      serviceOrderId: 'order-1',
      amount: MoneyMinor(12345),
      method: PaymentMethod.pix,
    );

    expect(ids, ['op-1', 'op-1']);
    expect(factoryCalls, 1);
    expect((await _intentRows(db)).single['lifecycle_state'], 'COMPLETED');
    expect(await payments.findById('payment-created', executor: db), isNotNull);
  });

  for (final status in const [
    PaymentStatus.confirmed,
    PaymentStatus.cancelled,
  ]) {
    test('$status timeout retry reuses operationId', () async {
      var attempt = 0;
      final ids = <String>[];
      final gateway = _Gateway(
        onTransition: (operationId, requested) async {
          ids.add(operationId);
          if (attempt++ == 0) throw TimeoutException('response lost');
          return _payment(status: requested);
        },
      );
      var factoryCalls = 0;
      final executor = _executor(
        db,
        gateway,
        payments,
        intents,
        () => 'transition-${++factoryCalls}',
      );

      await expectLater(
        executor.transition(paymentId: 'payment-1', status: status),
        throwsA(isA<TimeoutException>()),
      );
      await executor.transition(paymentId: 'payment-1', status: status);

      expect(ids, ['transition-1', 'transition-1']);
      expect(factoryCalls, 1);
    });
  }

  test('new human intent after completion receives a new operationId',
      () async {
    final ids = <String>[];
    var paymentIndex = 0;
    final gateway = _Gateway(
      onCreate: (operationId) async {
        ids.add(operationId);
        return _payment(id: 'payment-${++paymentIndex}');
      },
    );
    var operationIndex = 0;
    final executor = _executor(
      db,
      gateway,
      payments,
      intents,
      () => 'op-${++operationIndex}',
    );

    for (var i = 0; i < 2; i++) {
      await executor.create(
        serviceOrderId: 'order-1',
        amount: MoneyMinor(500),
        method: PaymentMethod.dinheiro,
      );
    }

    expect(ids, ['op-1', 'op-2']);
    expect(await _intentRows(db), hasLength(2));
  });

  test('operationId reuse with a changed canonical payload fails closed',
      () async {
    final first = await intents.getOrCreate(
      commandType: PaymentCommandType.create,
      targetId: 'order-1',
      payload: {'amountMinor': 100, 'serviceOrderId': 'order-1'},
      operationIdFactory: () => 'fixed-operation',
      executor: db,
    );
    expect(first.operationId, 'fixed-operation');

    await expectLater(
      intents.getOrCreate(
        commandType: PaymentCommandType.create,
        targetId: 'order-1',
        payload: {'amountMinor': 200, 'serviceOrderId': 'order-1'},
        operationIdFactory: () => 'fixed-operation',
        executor: db,
      ),
      throwsA(isA<PaymentIntentIdentityException>()),
    );
  });

  test('provider recreation in the same scope retains UNKNOWN operationId',
      () async {
    final firstGateway = _Gateway(
      onCreate: (_) async => throw TimeoutException('response lost'),
    );
    await expectLater(
      _executor(db, firstGateway, payments, intents, () => 'op-original')
          .create(
        serviceOrderId: 'order-1',
        amount: MoneyMinor(250),
        method: PaymentMethod.pix,
      ),
      throwsA(isA<TimeoutException>()),
    );

    final retriedIds = <String>[];
    final recreatedExecutor = _executor(
      db,
      _Gateway(
        onCreate: (operationId) async {
          retriedIds.add(operationId);
          return _payment();
        },
      ),
      PaymentLocalDataSource(),
      PaymentCommandIntentLocalDataSource(),
      () => 'must-not-be-used',
    );
    await recreatedExecutor.create(
      serviceOrderId: 'order-1',
      amount: MoneyMinor(250),
      method: PaymentMethod.pix,
    );

    expect(retriedIds, ['op-original']);
  });

  test('app restart recovers SENDING as UNKNOWN and retains operationId',
      () async {
    final stored = await intents.getOrCreate(
      commandType: PaymentCommandType.create,
      targetId: 'order-1',
      payload: {
        'amountMinor': 250,
        'method': 'PIX',
        'serviceOrderId': 'order-1',
      },
      operationIdFactory: () => 'op-before-restart',
      executor: db,
    );
    await intents.setLifecycle(
      stored.operationId,
      PaymentIntentLifecycle.sending,
      executor: db,
    );

    final recreatedStore = PaymentCommandIntentLocalDataSource();
    await recreatedStore.recoverInterruptedSending(executor: db);
    expect((await _intentRows(db)).single['lifecycle_state'], 'UNKNOWN');
    final ids = <String>[];
    await _executor(
      db,
      _Gateway(
        onCreate: (operationId) async {
          ids.add(operationId);
          return _payment();
        },
      ),
      PaymentLocalDataSource(),
      recreatedStore,
      () => 'must-not-be-used',
    ).create(
      serviceOrderId: 'order-1',
      amount: MoneyMinor(250),
      method: PaymentMethod.pix,
    );

    expect(ids, ['op-before-restart']);
  });

  test('UNKNOWN intent is isolated to its auth-scoped database', () async {
    final dbB = await openPaymentTestDatabase();
    addTearDown(dbB.close);
    await expectLater(
      _executor(
        db,
        _Gateway(onCreate: (_) async => throw TimeoutException('lost')),
        payments,
        intents,
        () => 'scope-a-operation',
      ).create(
        serviceOrderId: 'order-1',
        amount: MoneyMinor(300),
        method: PaymentMethod.pix,
      ),
      throwsA(isA<TimeoutException>()),
    );

    final idsB = <String>[];
    await _executor(
      dbB,
      _Gateway(
        onCreate: (operationId) async {
          idsB.add(operationId);
          return _payment(id: 'payment-b');
        },
      ),
      PaymentLocalDataSource(),
      PaymentCommandIntentLocalDataSource(),
      () => 'scope-b-operation',
    ).create(
      serviceOrderId: 'order-1',
      amount: MoneyMinor(300),
      method: PaymentMethod.pix,
    );

    expect(idsB, ['scope-b-operation']);
    expect((await _intentRows(db)).single['operation_id'], 'scope-a-operation');
    expect(
        (await _intentRows(dbB)).single['operation_id'], 'scope-b-operation');
  });

  test('stale binding after response never commits the authoritative payment',
      () async {
    final entered = Completer<void>();
    final response = Completer<PaymentEntity>();
    var isCurrent = true;
    final executor = PaymentCommandIntentExecutor(
      gateway: _Gateway(
        onCreate: (_) {
          entered.complete();
          return response.future;
        },
      ),
      paymentRepository: payments,
      intentRepository: intents,
      database: db,
      isBindingCurrent: () => isCurrent,
      operationIdFactory: () => 'scope-a-operation',
    );

    final pending = executor.create(
      serviceOrderId: 'order-1',
      amount: MoneyMinor(100),
      method: PaymentMethod.pix,
    );
    await entered.future;
    isCurrent = false;
    response.complete(_payment());

    await expectLater(pending, throwsStateError);
    expect(await payments.listAll(executor: db), isEmpty);
    expect((await _intentRows(db)).single['lifecycle_state'], 'SENDING');
  });
}

PaymentCommandIntentExecutor _executor(
  Database db,
  PaymentCommandGateway gateway,
  PaymentRepository payments,
  PaymentCommandIntentRepository intents,
  String Function() operationIdFactory,
) {
  return PaymentCommandIntentExecutor(
    gateway: gateway,
    paymentRepository: payments,
    intentRepository: intents,
    database: db,
    isBindingCurrent: () => true,
    operationIdFactory: operationIdFactory,
  );
}

Future<List<Map<String, Object?>>> _intentRows(Database db) =>
    db.query('payment_command_intents', orderBy: 'created_at, operation_id');

PaymentEntity _payment({
  String id = 'payment-1',
  PaymentStatus status = PaymentStatus.pending,
}) {
  return PaymentEntity(
    id: id,
    serviceOrderId: 'order-1',
    customerId: 'customer-1',
    amount: MoneyMinor(12345),
    method: PaymentMethod.pix,
    status: status,
    createdAt: '2026-09-17T10:00:00Z',
    updatedAt: '2026-09-17T10:00:00Z',
  );
}

final class _Gateway implements PaymentCommandGateway {
  const _Gateway({this.onCreate, this.onTransition});

  final Future<PaymentEntity> Function(String operationId)? onCreate;
  final Future<PaymentEntity> Function(
    String operationId,
    PaymentStatus status,
  )? onTransition;

  @override
  Future<PaymentEntity> create({
    required String operationId,
    required String serviceOrderId,
    required MoneyMinor amount,
    required PaymentMethod method,
    String? notes,
  }) =>
      onCreate!(operationId);

  @override
  Future<List<PaymentEntity>> listAll() =>
      Future.value(const <PaymentEntity>[]);

  @override
  Future<PaymentEntity> transition({
    required String operationId,
    required String paymentId,
    required PaymentStatus status,
  }) =>
      onTransition!(operationId, status);
}
