import 'dart:async';

import 'package:assistailab/core/commands/command_intent.dart';
import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/customer_portal/application/customer_quote_decision_provider.dart';
import 'package:assistailab/features/customer_portal/application/customer_service_orders_provider.dart';
import 'package:assistailab/features/customer_portal/data/customer_quote_command_gateway.dart';
import 'package:assistailab/features/customer_portal/domain/customer_quote.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/customer_quote_test_database.dart';

const _orderId = '10000000-0000-4000-8000-000000000001';
const _revisionId = '20000000-0000-4000-8000-000000000002';
const _scopeA = CustomerAuthScope(userId: 'user-a', customerId: 'customer-a');
const _scopeB = CustomerAuthScope(userId: 'user-b', customerId: 'customer-b');
const _keyA = AuthenticatedSessionKey(scope: _scopeA, sessionGeneration: 1);
const _keyB = AuthenticatedSessionKey(scope: _scopeB, sessionGeneration: 2);

final _controlledCustomerSessionKey =
    StateProvider<AuthenticatedSessionKey?>((ref) => _keyA);

void main() {
  test('offline-limited CUSTOMER cannot create or dispatch a decision',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _Gateway();
    final container = harness.container(gateway, online: false);
    addTearDown(container.dispose);
    final subscription = container.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(customerQuoteDecisionProvider.future);

    await expectLater(
      container.read(customerQuoteDecisionProvider.notifier).submit(
            serviceOrderId: _orderId,
            decision: CustomerQuoteDecision.approve,
          ),
      throwsA(isA<CustomerQuoteDecisionException>()),
    );
    expect(gateway.quoteReads, 0);
    expect(gateway.operationIds, isEmpty);
    expect(await harness.handleA.database.query('command_intents'), isEmpty);
  });

  test('provider restart recovers CUSTOMER SENDING but not Payment SENDING',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final intents = CommandIntentLocalDataSource();
    final customer = await intents.getOrCreate(
      commandType: 'CUSTOMER_QUOTE_DECISION',
      targetId: _orderId,
      payload: const {'decision': 'APPROVE'},
      operationIdFactory: () => 'customer-interrupted',
      executor: harness.handleA.database,
    );
    final payment = await intents.getOrCreate(
      commandType: 'PAYMENT_CREATE',
      targetId: _orderId,
      payload: const {'amountMinor': 100},
      operationIdFactory: () => 'payment-live',
      executor: harness.handleA.database,
    );
    await intents.setLifecycle(
      customer.operationId,
      CommandIntentLifecycle.sending,
      executor: harness.handleA.database,
    );
    await intents.setLifecycle(
      payment.operationId,
      CommandIntentLifecycle.sending,
      executor: harness.handleA.database,
    );
    final container = harness.container(_Gateway());
    addTearDown(container.dispose);
    final subscription = container.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(customerQuoteDecisionProvider.future);

    expect(
      await _lifecycleById(harness.handleA.database, customer.operationId),
      'UNKNOWN',
    );
    expect(
      await _lifecycleById(harness.handleA.database, payment.operationId),
      'SENDING',
    );
  });

  test('UNKNOWN survives provider recreation and retry keeps operationId',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final firstGateway = _Gateway(
      onSubmit: (_) async => throw TimeoutException('response lost'),
    );
    final first = harness.container(firstGateway);
    final firstSubscription = first.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    await first.read(customerQuoteDecisionProvider.future);
    await expectLater(
      first.read(customerQuoteDecisionProvider.notifier).submit(
            serviceOrderId: _orderId,
            decision: CustomerQuoteDecision.approve,
          ),
      throwsA(isA<TimeoutException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
    firstSubscription.close();
    first.dispose();

    final secondGateway = _Gateway();
    final second = harness.container(secondGateway);
    addTearDown(second.dispose);
    final secondSubscription = second.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(secondSubscription.close);
    await second.read(customerQuoteDecisionProvider.future);
    await second.read(customerQuoteDecisionProvider.notifier).submit(
          serviceOrderId: _orderId,
          decision: CustomerQuoteDecision.approve,
        );

    expect(firstGateway.operationIds, ['operation-a']);
    expect(secondGateway.operationIds, ['operation-a']);
    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');
    expect(
      second.read(customerServiceOrdersProvider).value?.single.status.name,
      'emExecucao',
    );
  });

  test('late session A response cannot commit or publish into session B',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final entered = Completer<void>();
    final response = Completer<void>();
    final gateway = _Gateway(
      onSubmit: (_) {
        entered.complete();
        return response.future;
      },
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);
    final decisionSubscription = container.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(decisionSubscription.close);
    await container.read(customerQuoteDecisionProvider.future);

    final command = container
        .read(customerQuoteDecisionProvider.notifier)
        .submit(
          serviceOrderId: _orderId,
          decision: CustomerQuoteDecision.approve,
        )
        .then<Object?>((_) => null, onError: (Object error) => error);
    await entered.future;
    final handleB = await harness.switchToB(container);
    await container.read(customerQuoteDecisionProvider.future);
    response.complete();

    expect(await command, isA<StateError>());
    expect(await handleB.database.query('service_orders'), isEmpty);
    expect(await handleB.database.query('command_intents'), isEmpty);
    final aIntent =
        (await harness.handleA.database.query('command_intents')).single;
    expect(aIntent['lifecycle_state'], 'SENDING');
    expect(gateway.projectionReads, 0);
  });

  test('stale session after quote GET cannot dispatch the command', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final entered = Completer<void>();
    final quoteResponse = Completer<CustomerQuote>();
    final gateway = _Gateway(
      onRead: () {
        entered.complete();
        return quoteResponse.future;
      },
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);
    final subscription = container.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(customerQuoteDecisionProvider.future);

    final command = container
        .read(customerQuoteDecisionProvider.notifier)
        .submit(
          serviceOrderId: _orderId,
          decision: CustomerQuoteDecision.approve,
        )
        .then<Object?>((_) => null, onError: (Object error) => error);
    await entered.future;
    await harness.switchToB(container);
    await container.read(customerQuoteDecisionProvider.future);
    quoteResponse.complete(_quote());

    expect(await command, isA<StateError>());
    expect(gateway.operationIds, isEmpty);
    expect(await harness.handleA.database.query('command_intents'), isEmpty);
  });
}

final class _Harness {
  _Harness._(this.manager, this.handleA, this.databases);

  final AuthScopedDatabaseManager manager;
  final BoundDatabaseHandle handleA;
  final Set<Database> databases;

  static Future<_Harness> create() async {
    final databases = <Database>{};
    final manager = AuthScopedDatabaseManager.forTesting(
      opener: (_) async {
        final db = await openCustomerQuoteTestDatabase();
        databases.add(db);
        return db;
      },
      closer: (_) async {},
    );
    final handleA = await manager.openDatabaseForScope(
      _scopeA,
      sessionGeneration: _keyA.sessionGeneration,
    );
    return _Harness._(manager, handleA, databases);
  }

  ProviderContainer container(
    CustomerQuoteCommandGateway gateway, {
    bool online = true,
  }) =>
      ProviderContainer(
        overrides: [
          authenticatedSessionKeyProvider.overrideWith(
            (ref) => ref.watch(_controlledCustomerSessionKey),
          ),
          isOnlineSessionProvider.overrideWith((ref) => online),
          customerPortalDatabaseManagerProvider.overrideWithValue(manager),
          customerQuoteCommandGatewayProvider.overrideWithValue(gateway),
          customerQuoteOperationIdFactoryProvider.overrideWithValue(
            () => 'operation-a',
          ),
        ],
      );

  Future<BoundDatabaseHandle> switchToB(ProviderContainer container) async {
    final handle = await manager.openDatabaseForScope(
      _scopeB,
      sessionGeneration: _keyB.sessionGeneration,
    );
    container.read(_controlledCustomerSessionKey.notifier).state = _keyB;
    return handle;
  }

  Future<void> dispose() async {
    for (final database in databases) {
      if (database.isOpen) await database.close();
    }
  }
}

Future<Object?> _lifecycle(Database db) async => (await db.query(
      'command_intents',
      columns: ['lifecycle_state'],
    ))
        .single['lifecycle_state'];

Future<Object?> _lifecycleById(Database db, String operationId) async =>
    (await db.query(
      'command_intents',
      columns: ['lifecycle_state'],
      where: 'operation_id = ?',
      whereArgs: [operationId],
    ))
        .single['lifecycle_state'];

final class _Gateway implements CustomerQuoteCommandGateway {
  _Gateway({this.onRead, this.onSubmit});

  final Future<CustomerQuote> Function()? onRead;
  final Future<void> Function(String operationId)? onSubmit;
  final List<String> operationIds = [];
  int quoteReads = 0;
  int projectionReads = 0;

  @override
  Future<CustomerQuote> readActionableQuote(String serviceOrderId) async {
    quoteReads++;
    final callback = onRead;
    if (callback != null) return callback();
    return _quote();
  }

  @override
  Future<CustomerServiceOrderProjection> readProjection(
    String serviceOrderId,
  ) async {
    projectionReads++;
    return const CustomerServiceOrderProjection(
      serviceOrderId: _orderId,
      wire: {
        'contractVersion': 2,
        'projectionRevision': '2',
        'id': _orderId,
        'friendlyId': 10,
        'equipmentId': 'equipment-1',
        'status': 'EM_EXECUCAO',
        'problemDescription': 'Não liga',
        'solution': null,
        'updatedAt': '2026-09-21T10:01:00.000Z',
        'diagnosis': null,
        'totalAmountMinor': 0,
        'items': <Object?>[],
      },
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
    await onSubmit?.call(operationId);
  }
}

CustomerQuote _quote() => CustomerQuote(
      serviceOrderId: _orderId,
      quoteRevisionId: _revisionId,
      revisionNumber: 1,
      decisionMode: CustomerQuoteDecisionMode.initialApproval,
      diagnosis: null,
      items: const [],
      totalAmount: MoneyMinor.zero,
      changeReason: null,
      createdAt: DateTime.utc(2026, 9, 21),
    );
