import 'dart:async';

import 'package:assistailab/core/commands/command_intent.dart';
import 'package:assistailab/core/database/service_order_repository.dart';
import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/customer_portal/application/customer_quote_decision_executor.dart';
import 'package:assistailab/features/customer_portal/data/customer_quote_command_gateway.dart';
import 'package:assistailab/features/customer_portal/domain/customer_quote.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/customer_quote_test_database.dart';

const _orderId = '10000000-0000-4000-8000-000000000001';
const _revisionA = '20000000-0000-4000-8000-000000000002';
const _revisionB = '30000000-0000-4000-8000-000000000003';

void main() {
  late Database db;
  late CommandIntentLocalDataSource intents;

  setUp(() async {
    db = await openCustomerQuoteTestDatabase();
    intents = CommandIntentLocalDataSource(
      nowUtc: () => DateTime.utc(2026, 9, 21),
    );
  });

  tearDown(() => db.close());

  test('APPROVE persists authoritative projection and COMPLETED atomically',
      () async {
    final gateway = _Gateway(
      projection: _projection('EM_EXECUCAO'),
    );
    final executor = _executor(db, intents, gateway, () => 'operation-approve');

    await executor.decide(
      identity: _identity(_revisionA, CustomerQuoteDecision.approve),
    );

    expect(gateway.operationIds, ['operation-approve']);
    expect(gateway.decisions, [CustomerQuoteDecision.approve]);
    expect(await _lifecycle(db, 'operation-approve'), 'COMPLETED');
    final stored = await ServiceOrderLocalDataSource().findById(
      _orderId,
      executor: db,
    );
    expect(stored?.status.toDbString(), 'EM_EXECUCAO');
  });

  test('REJECT normalizes reason and commits authoritative CANCELADO',
      () async {
    final gateway = _Gateway(projection: _projection('CANCELADO'));
    await _executor(db, intents, gateway, () => 'operation-reject').decide(
      identity: _identity(
        _revisionA,
        CustomerQuoteDecision.reject,
        reason: '  valor acima do esperado  ',
      ),
    );
    expect(gateway.reasons, ['valor acima do esperado']);
    expect(await _lifecycle(db, 'operation-reject'), 'COMPLETED');
    expect(
      (await ServiceOrderLocalDataSource().findById(_orderId, executor: db))
          ?.status
          .toDbString(),
      'CANCELADO',
    );
  });

  test('timeout becomes UNKNOWN and retry reuses the same operationId',
      () async {
    var attempt = 0;
    final gateway = _Gateway(
      projection: _projection('EM_EXECUCAO'),
      onSubmit: (_) async {
        if (attempt++ == 0) throw TimeoutException('response lost');
      },
    );
    var factoryCalls = 0;
    final executor = _executor(
      db,
      intents,
      gateway,
      () => 'operation-${++factoryCalls}',
    );
    await expectLater(
      executor.decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(await _lifecycle(db, 'operation-1'), 'UNKNOWN');

    await executor.decide(
      identity: _identity(_revisionA, CustomerQuoteDecision.approve),
    );
    expect(gateway.operationIds, ['operation-1', 'operation-1']);
    expect(factoryCalls, 1);
  });

  for (final code in const [
    'IDEMPOTENCY_IN_PROGRESS',
    'IDEMPOTENCY_STATE_CONFLICT',
  ]) {
    test('$code remains UNKNOWN', () async {
      final gateway = _Gateway(
        projection: _projection('EM_EXECUCAO'),
        onSubmit: (_) async => throw CustomerQuoteDecisionException(409, code),
      );
      await expectLater(
        _executor(db, intents, gateway, () => 'operation-uncertain').decide(
          identity: _identity(_revisionA, CustomerQuoteDecision.approve),
        ),
        throwsA(isA<CustomerQuoteDecisionException>()),
      );
      expect(await _lifecycle(db, 'operation-uncertain'), 'UNKNOWN');
    });
  }

  for (final code in const [
    'QUOTE_REVISION_NOT_CURRENT',
    'IDEMPOTENCY_KEY_REUSE',
  ]) {
    test('deterministic $code becomes REJECTED', () async {
      final gateway = _Gateway(
        projection: _projection('EM_EXECUCAO'),
        onSubmit: (_) async => throw CustomerQuoteDecisionException(409, code),
      );
      await expectLater(
        _executor(db, intents, gateway, () => 'operation-rejected').decide(
          identity: _identity(_revisionA, CustomerQuoteDecision.approve),
        ),
        throwsA(isA<CustomerQuoteDecisionException>()),
      );
      expect(await _lifecycle(db, 'operation-rejected'), 'REJECTED');
    });
  }

  test('stale revision A rejection never retargets and B gets a new identity',
      () async {
    var rejectA = true;
    final gateway = _Gateway(
      projection: _projection('EM_EXECUCAO'),
      onSubmit: (revision) async {
        if (revision == _revisionA && rejectA) {
          rejectA = false;
          throw const CustomerQuoteDecisionException(
            409,
            'QUOTE_REVISION_NOT_CURRENT',
          );
        }
      },
    );
    var factoryCalls = 0;
    final executor = _executor(
      db,
      intents,
      gateway,
      () => 'operation-${++factoryCalls}',
    );
    await expectLater(
      executor.decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(isA<CustomerQuoteDecisionException>()),
    );
    await executor.decide(
      identity: _identity(_revisionB, CustomerQuoteDecision.approve),
    );
    expect(gateway.operationIds, ['operation-1', 'operation-2']);
    expect(gateway.revisionIds, [_revisionA, _revisionB]);
  });

  test('projection failure rolls back data and leaves no false COMPLETED',
      () async {
    await db.insert('service_orders', {
      'id': _orderId,
      'equipment_id': 'equipment-old',
      'status': 'AGUARDANDO_APROVACAO',
      'problem_description': 'Original',
      'total_amount_minor': 0,
      'projection_revision': '1',
      'projection_fingerprint': 'old',
      'updated_at': '2026-09-20T00:00:00.000Z',
    });
    final malformed = _projection('EM_EXECUCAO');
    malformed['items'] = [
      {
        'description': 'Invalid total',
        'quantity': 1,
        'unitPriceMinor': 100,
        'totalPriceMinor': 99,
      }
    ];
    final gateway = _Gateway(projection: malformed);
    await expectLater(
      _executor(db, intents, gateway, () => 'operation-rollback').decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(anything),
    );
    expect(await _lifecycle(db, 'operation-rollback'), 'UNKNOWN');
    final row = (await db.query(
      'service_orders',
      where: 'id = ?',
      whereArgs: [_orderId],
    ))
        .single;
    expect(row['status'], 'AGUARDANDO_APROVACAO');
    expect(row['problem_description'], 'Original');
  });

  test('CUSTOMER recovery changes only CUSTOMER SENDING and retains opId',
      () async {
    final customer = await intents.getOrCreate(
      commandType: customerQuoteDecisionCommandType,
      targetId: _orderId,
      payload: {
        'serviceOrderId': _orderId,
        'quoteRevisionId': _revisionA,
        'decision': 'APPROVE',
      },
      operationIdFactory: () => 'customer-operation',
      executor: db,
    );
    final payment = await intents.getOrCreate(
      commandType: 'PAYMENT_CREATE',
      targetId: _orderId,
      payload: const {'amountMinor': 100},
      operationIdFactory: () => 'payment-operation',
      executor: db,
    );
    await intents.setLifecycle(
      customer.operationId,
      CommandIntentLifecycle.sending,
      executor: db,
    );
    await intents.setLifecycle(
      payment.operationId,
      CommandIntentLifecycle.sending,
      executor: db,
    );
    await intents.recoverInterruptedSending(
      ownedCommandTypes: customerQuoteOwnedCommandTypes,
      executor: db,
    );
    expect(await _lifecycle(db, customer.operationId), 'UNKNOWN');
    expect(await _lifecycle(db, payment.operationId), 'SENDING');

    final gateway = _Gateway(projection: _projection('EM_EXECUCAO'));
    await _executor(db, intents, gateway, () => 'must-not-be-used').decide(
      identity: _identity(_revisionA, CustomerQuoteDecision.approve),
    );
    expect(gateway.operationIds, ['customer-operation']);
  });

  test('phase separation: POST 409 is REJECTED but projection 409 is UNKNOWN',
      () async {
    // 1. POST 409 QUOTE_REVISION_NOT_CURRENT -> REJECTED
    final postConflictGateway = _Gateway(
      projection: _projection('EM_EXECUCAO'),
      onSubmit: (_) async => throw const CustomerQuoteDecisionException(
        409,
        'QUOTE_REVISION_NOT_CURRENT',
      ),
    );
    await expectLater(
      _executor(db, intents, postConflictGateway, () => 'op-post-revision')
          .decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(isA<CustomerQuoteDecisionException>()),
    );
    expect(await _lifecycle(db, 'op-post-revision'), 'REJECTED');

    // 2. POST 409 IDEMPOTENCY_KEY_REUSE -> REJECTED
    final postReuseGateway = _Gateway(
      projection: _projection('EM_EXECUCAO'),
      onSubmit: (_) async => throw const CustomerQuoteDecisionException(
        409,
        'IDEMPOTENCY_KEY_REUSE',
      ),
    );
    await expectLater(
      _executor(db, intents, postReuseGateway, () => 'op-post-reuse').decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(isA<CustomerQuoteDecisionException>()),
    );
    expect(await _lifecycle(db, 'op-post-reuse'), 'REJECTED');

    // 3. POST success -> projection 409 SYNC_V2_REFRESH_REQUIRED -> UNKNOWN
    final projectionConflictGateway = _Gateway(
      projection: _projection('EM_EXECUCAO'),
      onReadProjection: () async => throw const CustomerQuoteDecisionException(
        409,
        'SYNC_V2_REFRESH_REQUIRED',
      ),
    );
    await expectLater(
      _executor(
        db,
        intents,
        projectionConflictGateway,
        () => 'op-proj-conflict',
      ).decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(isA<CustomerQuoteProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(db, 'op-proj-conflict'), 'UNKNOWN');
  });

  test('post-success projection failures remain UNKNOWN and not REJECTED',
      () async {
    final failureCases = <({String name, Object failure})>[
      (
        name: '401 Unauthorized',
        failure: const CustomerQuoteDecisionException(401, 'UNAUTHORIZED'),
      ),
      (
        name: '403 Forbidden',
        failure: const CustomerQuoteDecisionException(403, 'FORBIDDEN'),
      ),
      (
        name: '404 Not Found',
        failure: const CustomerQuoteDecisionException(404, 'NOT_FOUND'),
      ),
      (
        name: 'ordinary 409 Conflict',
        failure: const CustomerQuoteDecisionException(409, 'CONFLICT'),
      ),
      (
        name: '409 SYNC_V2_REFRESH_REQUIRED',
        failure: const CustomerQuoteDecisionException(
          409,
          'SYNC_V2_REFRESH_REQUIRED',
        ),
      ),
      (
        name: '500 Internal Server Error',
        failure: const CustomerQuoteDecisionException(
          500,
          'INTERNAL_SERVER_ERROR',
        ),
      ),
      (
        name: '502 Bad Gateway',
        failure: const CustomerQuoteDecisionException(502, 'BAD_GATEWAY'),
      ),
      (
        name: '503 Service Unavailable',
        failure:
            const CustomerQuoteDecisionException(503, 'SERVICE_UNAVAILABLE'),
      ),
      (
        name: 'invalid JSON format',
        failure: const FormatException('Invalid JSON payload'),
      ),
    ];

    var counter = 0;
    for (final testCase in failureCases) {
      await db.delete('command_intents');
      final opId = 'op-failure-${++counter}';
      final gateway = _Gateway(
        projection: _projection('EM_EXECUCAO'),
        onReadProjection: () async => throw testCase.failure,
      );
      await expectLater(
        _executor(db, intents, gateway, () => opId).decide(
          identity: _identity(_revisionA, CustomerQuoteDecision.approve),
        ),
        throwsA(isA<CustomerQuoteProjectionUncertaintyException>()),
        reason: 'Failed on ${testCase.name}',
      );
      expect(
        await _lifecycle(db, opId),
        'UNKNOWN',
        reason: 'Lifecycle for ${testCase.name} must be UNKNOWN, not REJECTED',
      );
    }
  });

  test('malformed projection payload validation results in UNKNOWN',
      () async {
    // 1. wrong serviceOrderId in projection
    await db.delete('command_intents');
    final wrongIdGateway = _Gateway(
      projection: _projection('EM_EXECUCAO'),
      onReadProjection: () async => const CustomerServiceOrderProjection(
        serviceOrderId: 'wrong-order-id',
        wire: {
          'id': 'wrong-order-id',
          'contractVersion': 2,
        },
      ),
    );
    await expectLater(
      _executor(db, intents, wrongIdGateway, () => 'op-wrong-id').decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(isA<CustomerQuoteProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(db, 'op-wrong-id'), 'UNKNOWN');

    // 2. wrong contractVersion in wire
    await db.delete('command_intents');
    final wrongContract = _projection('EM_EXECUCAO');
    wrongContract['contractVersion'] = 1;
    final wrongContractGateway = _Gateway(
      projection: wrongContract,
    );
    await expectLater(
      _executor(db, intents, wrongContractGateway, () => 'op-wrong-contract')
          .decide(
        identity: _identity(_revisionA, CustomerQuoteDecision.approve),
      ),
      throwsA(isA<CustomerQuoteProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(db, 'op-wrong-contract'), 'UNKNOWN');
  });
}

CustomerQuoteDecisionExecutor _executor(
  Database db,
  CommandIntentRepository intents,
  CustomerQuoteCommandGateway gateway,
  String Function() operationIdFactory,
) =>
    CustomerQuoteDecisionExecutor(
      gateway: gateway,
      intentRepository: intents,
      database: db,
      isBindingCurrent: () => true,
      operationIdFactory: operationIdFactory,
    );

CustomerQuote _quote(String revisionId) => CustomerQuote(
      serviceOrderId: _orderId,
      quoteRevisionId: revisionId,
      revisionNumber: revisionId == _revisionA ? 1 : 2,
      decisionMode: CustomerQuoteDecisionMode.initialApproval,
      diagnosis: 'Diagnóstico',
      items: const [],
      totalAmount: MoneyMinor.zero,
      changeReason: null,
      createdAt: DateTime.utc(2026, 9, 21),
    );

CustomerQuoteDecisionIdentity _identity(
  String revisionId,
  CustomerQuoteDecision decision, {
  String? reason,
}) =>
    CustomerQuoteDecisionIdentity.fromQuote(
      quote: _quote(revisionId),
      decision: decision,
      reason: reason,
    );

Map<String, dynamic> _projection(String status) => {
      'contractVersion': 2,
      'projectionRevision': '2',
      'id': _orderId,
      'friendlyId': 10,
      'equipmentId': 'equipment-1',
      'status': status,
      'problemDescription': 'Não liga',
      'solution': null,
      'updatedAt': '2026-09-21T10:01:00.000Z',
      'diagnosis': 'Diagnóstico',
      'totalAmountMinor': 0,
      'items': <Object?>[],
    };

Future<Object?> _lifecycle(Database db, String operationId) async =>
    (await db.query(
      'command_intents',
      columns: ['lifecycle_state'],
      where: 'operation_id = ?',
      whereArgs: [operationId],
    ))
        .single['lifecycle_state'];

final class _Gateway implements CustomerQuoteCommandGateway {
  _Gateway({
    required this.projection,
    this.onSubmit,
    this.onReadProjection,
  });

  final Map<String, dynamic> projection;
  final Future<void> Function(String revisionId)? onSubmit;
  final Future<CustomerServiceOrderProjection> Function()? onReadProjection;
  final List<String> operationIds = [];
  final List<String> revisionIds = [];
  final List<CustomerQuoteDecision> decisions = [];
  final List<String?> reasons = [];

  @override
  Future<CustomerQuote> readActionableQuote(String serviceOrderId) async =>
      _quote(_revisionA);

  @override
  Future<CustomerServiceOrderProjection> readProjection(
    String serviceOrderId,
  ) async {
    final callback = onReadProjection;
    if (callback != null) return callback();
    return CustomerServiceOrderProjection(
      serviceOrderId: serviceOrderId,
      wire: projection,
    );
  }

  @override
  Future<void> submitDecision({
    required String operationId,
    required String serviceOrderId,
    required String quoteRevisionId,
    required CustomerQuoteDecision decision,
    String? reason,
  }) async {
    operationIds.add(operationId);
    revisionIds.add(quoteRevisionId);
    decisions.add(decision);
    reasons.add(reason);
    await onSubmit?.call(quoteRevisionId);
  }
}
