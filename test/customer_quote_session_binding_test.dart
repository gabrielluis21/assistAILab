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
  test('lost successful response replays UNKNOWN without a fresh quote read',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    var backendApplied = false;
    var attempt = 0;
    final gateway = _Gateway(
      onRead: () async {
        if (backendApplied) {
          throw const CustomerQuoteDecisionException(
            409,
            'CUSTOMER_QUOTE_NOT_ACTIONABLE',
          );
        }
        return _quote();
      },
      onSubmit: (_) async {
        if (attempt++ == 0) {
          backendApplied = true;
          throw TimeoutException('successful response was lost');
        }
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

    for (var call = 0; call < 2; call++) {
      final future =
          container.read(customerQuoteDecisionProvider.notifier).submit(
                serviceOrderId: _orderId,
                decision: CustomerQuoteDecision.reject,
                reason: '  valor alto  ',
              );
      if (call == 0) {
        await expectLater(future, throwsA(isA<TimeoutException>()));
        expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
      } else {
        await future;
      }
    }

    expect(gateway.quoteReads, 1);
    expect(gateway.operationIds, ['operation-a', 'operation-a']);
    expect(gateway.revisionIds, [_revisionId, _revisionId]);
    expect(gateway.decisions, [
      CustomerQuoteDecision.reject,
      CustomerQuoteDecision.reject,
    ]);
    expect(gateway.reasons, ['valor alto', 'valor alto']);
    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');
    expect(
      (await harness.handleA.database.query('service_orders')).single['status'],
      'EM_EXECUCAO',
    );
  });

  test('different action does not consume an unrelated UNKNOWN intent',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    var submitAttempt = 0;
    var quoteAttempt = 0;
    final gateway = _Gateway(
      onRead: () async => _quote(
        revisionId: quoteAttempt++ == 0
            ? _revisionId
            : '30000000-0000-4000-8000-000000000003',
      ),
      onSubmit: (_) async {
        if (submitAttempt++ == 0) throw TimeoutException('unknown approval');
      },
    );
    var operation = 0;
    final container = harness.container(
      gateway,
      operationIdFactory: () => 'operation-${++operation}',
    );
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
      throwsA(isA<TimeoutException>()),
    );
    await container.read(customerQuoteDecisionProvider.notifier).submit(
          serviceOrderId: _orderId,
          decision: CustomerQuoteDecision.reject,
          reason: 'nova decisão',
        );

    expect(gateway.quoteReads, 2);
    expect(gateway.operationIds, ['operation-1', 'operation-2']);
    expect(gateway.revisionIds, [
      _revisionId,
      '30000000-0000-4000-8000-000000000003',
    ]);
    expect(
      await _lifecycleById(harness.handleA.database, 'operation-1'),
      'UNKNOWN',
    );
    expect(
      await _lifecycleById(harness.handleA.database, 'operation-2'),
      'COMPLETED',
    );
  });

  test('ambiguous unresolved identities fail closed before quote read',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final intents = CommandIntentLocalDataSource();
    for (final entry in const [
      ('operation-a', _revisionId),
      ('operation-b', '30000000-0000-4000-8000-000000000003'),
    ]) {
      final intent = await intents.getOrCreate(
        commandType: 'CUSTOMER_QUOTE_DECISION',
        targetId: _orderId,
        payload: {
          'decision': 'APPROVE',
          'quoteRevisionId': entry.$2,
          'serviceOrderId': _orderId,
        },
        operationIdFactory: () => entry.$1,
        executor: harness.handleA.database,
      );
      await intents.setLifecycle(
        intent.operationId,
        CommandIntentLifecycle.sending,
        executor: harness.handleA.database,
      );
      await intents.setLifecycle(
        intent.operationId,
        CommandIntentLifecycle.unknown,
        executor: harness.handleA.database,
      );
    }
    final gateway = _Gateway();
    final container = harness.container(gateway);
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
      throwsA(isA<StateError>()),
    );
    expect(gateway.quoteReads, 0);
    expect(gateway.operationIds, isEmpty);
  });

  test('listener churn cannot recover a live CUSTOMER SENDING command',
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
    var subscription = container.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(customerQuoteDecisionProvider.future);
    final notifier = container.read(customerQuoteDecisionProvider.notifier);
    final command = notifier.submit(
      serviceOrderId: _orderId,
      decision: CustomerQuoteDecision.approve,
    );
    await entered.future;
    expect(await _lifecycle(harness.handleA.database), 'SENDING');

    subscription.close();
    await Future<void>.delayed(Duration.zero);
    subscription = container.listen(
      customerQuoteDecisionProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    expect(
      identical(
        notifier,
        container.read(customerQuoteDecisionProvider.notifier),
      ),
      isTrue,
    );
    expect(await _lifecycle(harness.handleA.database), 'SENDING');

    response.complete();
    await command;
    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');
    expect(
      (await harness.handleA.database.query('service_orders')).single['status'],
      'EM_EXECUCAO',
    );
  });

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

  test(
      'post-success projection 409 SYNC_V2_REFRESH_REQUIRED remains UNKNOWN and retries without fresh quote read',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    var backendApplied = false;
    var projectionAttempt = 0;
    final gateway = _Gateway(
      onRead: () async {
        if (backendApplied) {
          throw const CustomerQuoteDecisionException(
            409,
            'CUSTOMER_QUOTE_NOT_ACTIONABLE',
          );
        }
        return _quote();
      },
      onSubmit: (_) async {
        backendApplied = true;
      },
      onReadProjection: () async {
        if (projectionAttempt++ == 0) {
          throw const CustomerQuoteDecisionException(
            409,
            'SYNC_V2_REFRESH_REQUIRED',
          );
        }
        return const CustomerServiceOrderProjection(
          serviceOrderId: _orderId,
          wire: {
            'contractVersion': 2,
            'projectionRevision': '2',
            'id': _orderId,
            'friendlyId': 10,
            'equipmentId': 'equipment-1',
            'status': 'CANCELADO',
            'problemDescription': 'Não liga',
            'solution': null,
            'updatedAt': '2026-09-21T10:01:00.000Z',
            'diagnosis': null,
            'totalAmountMinor': 0,
            'items': <Object?>[],
          },
        );
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

    for (var call = 0; call < 2; call++) {
      final future =
          container.read(customerQuoteDecisionProvider.notifier).submit(
                serviceOrderId: _orderId,
                decision: CustomerQuoteDecision.reject,
                reason: '  valor alto  ',
              );
      if (call == 0) {
        await expectLater(
          future,
          throwsA(isA<CustomerQuoteProjectionUncertaintyException>()),
        );
        expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
      } else {
        await future;
      }
    }

    expect(gateway.quoteReads, 1);
    expect(gateway.operationIds, ['operation-a', 'operation-a']);
    expect(gateway.revisionIds, [_revisionId, _revisionId]);
    expect(gateway.decisions, [
      CustomerQuoteDecision.reject,
      CustomerQuoteDecision.reject,
    ]);
    expect(gateway.reasons, ['valor alto', 'valor alto']);
    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');
    expect(
      (await harness.handleA.database.query('service_orders')).single['status'],
      'CANCELADO',
    );
  });

  test(
      'late session A response during projection read cannot commit or mutate session B or superseded session A',
      () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final enteredProjection = Completer<void>();
    final projectionResponse = Completer<CustomerServiceOrderProjection>();
    final gateway = _Gateway(
      onSubmit: (_) async {
        // submitDecision succeeds
      },
      onReadProjection: () {
        enteredProjection.complete();
        return projectionResponse.future;
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
    await enteredProjection.future;
    final handleB = await harness.switchToB(container);
    await container.read(customerQuoteDecisionProvider.future);
    projectionResponse.complete(const CustomerServiceOrderProjection(
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
    ));

    expect(await command, isA<StateError>());
    expect(await handleB.database.query('service_orders'), isEmpty);
    expect(await handleB.database.query('command_intents'), isEmpty);
    final aIntent =
        (await harness.handleA.database.query('command_intents')).single;
    expect(aIntent['lifecycle_state'], 'SENDING');
    expect(await harness.handleA.database.query('service_orders'), isEmpty);
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
    String Function()? operationIdFactory,
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
            operationIdFactory ?? () => 'operation-a',
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
  _Gateway({
    this.onRead,
    this.onSubmit,
    this.onReadProjection,
  });

  final Future<CustomerQuote> Function()? onRead;
  final Future<void> Function(String operationId)? onSubmit;
  final Future<CustomerServiceOrderProjection> Function()? onReadProjection;
  final List<String> operationIds = [];
  final List<String> revisionIds = [];
  final List<CustomerQuoteDecision> decisions = [];
  final List<String?> reasons = [];
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
    final callback = onReadProjection;
    if (callback != null) return callback();
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
    revisionIds.add(quoteRevisionId);
    decisions.add(decision);
    reasons.add(reason);
    await onSubmit?.call(operationId);
  }
}

CustomerQuote _quote({String revisionId = _revisionId}) => CustomerQuote(
      serviceOrderId: _orderId,
      quoteRevisionId: revisionId,
      revisionNumber: 1,
      decisionMode: CustomerQuoteDecisionMode.initialApproval,
      diagnosis: null,
      items: const [],
      totalAmount: MoneyMinor.zero,
      changeReason: null,
      createdAt: DateTime.utc(2026, 9, 21),
    );
