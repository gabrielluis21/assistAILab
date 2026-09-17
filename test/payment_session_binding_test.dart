import 'dart:async';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/finance/payment_command_gateway.dart';
import 'package:assistailab/features/finance/payment_entity.dart';
import 'package:assistailab/features/finance/payment_repository.dart';
import 'package:assistailab/features/finance/payments_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/payment_test_database.dart';

const _scopeA =
    ProfessionalAuthScope(userId: 'payment-user-a', organizationId: 'org-a');
const _scopeB =
    ProfessionalAuthScope(userId: 'payment-user-b', organizationId: 'org-b');
const _keyA = AuthenticatedSessionKey(scope: _scopeA, sessionGeneration: 1);
const _keyB = AuthenticatedSessionKey(scope: _scopeB, sessionGeneration: 2);

final _controlledPaymentSessionKey =
    StateProvider<AuthenticatedSessionKey?>((ref) => _keyA);

void main() {
  test('CREATE response from A cannot commit or publish into B', () async {
    final harness = await _Harness.create(online: true);
    addTearDown(harness.dispose);
    final entered = Completer<void>();
    final response = Completer<PaymentEntity>();
    final gateway = _Gateway(
      onCreate: (_) {
        entered.complete();
        return response.future;
      },
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);
    final subscription = container.listen(
      paymentsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(paymentsProvider.future);

    final command = container
        .read(paymentsProvider.notifier)
        .createPayment(
          serviceOrderId: 'order-a',
          amount: MoneyMinor(100),
          method: PaymentMethod.pix,
        )
        .then<Object?>((_) => null, onError: (Object error) => error);
    await entered.future;

    final handleB = await harness.switchToB(container);
    await container.read(paymentsProvider.future);
    response.complete(_payment(id: 'payment-a', orderId: 'order-a'));
    expect(await command, isA<StateError>());

    final paymentsB = await PaymentLocalDataSource().listAll(
      executor: handleB.database,
    );
    expect(paymentsB, isEmpty);
    expect(container.read(paymentsProvider).value, isEmpty);
  });

  test('LIST response from A cannot reconcile or publish into B', () async {
    final harness = await _Harness.create(online: true);
    addTearDown(harness.dispose);
    final aEntered = Completer<void>();
    final aResponse = Completer<List<PaymentEntity>>();
    var listCalls = 0;
    final gateway = _Gateway(
      onList: () {
        listCalls++;
        if (listCalls == 1) {
          aEntered.complete();
          return aResponse.future;
        }
        return Future.value([
          _payment(id: 'payment-b', orderId: 'order-b'),
        ]);
      },
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);
    final subscription = container.listen(
      paymentsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    final aFuture = container
        .read(paymentsProvider.future)
        .then<Object?>((value) => value, onError: (Object error) => error);
    await aEntered.future;

    final handleB = await harness.switchToB(container);
    final bState = await container.read(paymentsProvider.future);
    expect(bState.map((payment) => payment.id), ['payment-b']);

    aResponse.complete([_payment(id: 'payment-a', orderId: 'order-a')]);
    await aFuture;
    await Future<void>.value();

    final storedB = await PaymentLocalDataSource().listAll(
      executor: handleB.database,
    );
    expect(storedB.map((payment) => payment.id), ['payment-b']);
    expect(
      container.read(paymentsProvider).value?.map((payment) => payment.id),
      ['payment-b'],
    );
  });

  test('paymentsProvider rebuild hides cached A data after switch to B',
      () async {
    final harness = await _Harness.create(online: false);
    addTearDown(harness.dispose);
    await PaymentLocalDataSource().upsert(
      _payment(id: 'cached-a', orderId: 'order-a'),
      executor: harness.handleA.database,
    );
    final container = harness.container(const _Gateway());
    addTearDown(container.dispose);
    final subscription = container.listen(
      paymentsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    final aState = await container.read(paymentsProvider.future);
    expect(aState.map((payment) => payment.id), ['cached-a']);

    final handleB = await harness.switchToB(container);
    await PaymentLocalDataSource().upsert(
      _payment(id: 'cached-b', orderId: 'order-b'),
      executor: handleB.database,
    );
    container.invalidate(paymentsProvider);
    final bState = await container.read(paymentsProvider.future);

    expect(bState.map((payment) => payment.id), ['cached-b']);
    expect(bState.map((payment) => payment.id), isNot(contains('cached-a')));
  });
}

final class _Harness {
  _Harness._({
    required this.manager,
    required this.handleA,
    required this.online,
    required this.databases,
  });

  final AuthScopedDatabaseManager manager;
  final BoundDatabaseHandle handleA;
  final bool online;
  final Set<Database> databases;

  static Future<_Harness> create({required bool online}) async {
    final databases = <Database>{};
    final manager = AuthScopedDatabaseManager.forTesting(
      opener: (_) async {
        final db = await openPaymentTestDatabase();
        databases.add(db);
        return db;
      },
      // Keep old handles inspectable while still invalidating their binding.
      closer: (_) async {},
    );
    final handleA = await manager.openDatabaseForScope(
      _scopeA,
      sessionGeneration: _keyA.sessionGeneration,
    );
    return _Harness._(
      manager: manager,
      handleA: handleA,
      online: online,
      databases: databases,
    );
  }

  ProviderContainer container(PaymentCommandGateway gateway) {
    return ProviderContainer(
      overrides: [
        authenticatedSessionKeyProvider.overrideWith(
          (ref) => ref.watch(_controlledPaymentSessionKey),
        ),
        isOnlineSessionProvider.overrideWith((ref) => online),
        paymentDatabaseManagerProvider.overrideWithValue(manager),
        paymentCommandGatewayProvider.overrideWithValue(gateway),
        paymentOperationIdFactoryProvider.overrideWithValue(
          () => 'operation-a',
        ),
      ],
    );
  }

  Future<BoundDatabaseHandle> switchToB(ProviderContainer container) async {
    final handle = await manager.openDatabaseForScope(
      _scopeB,
      sessionGeneration: _keyB.sessionGeneration,
    );
    container.read(_controlledPaymentSessionKey.notifier).state = _keyB;
    return handle;
  }

  Future<void> dispose() async {
    for (final database in databases) {
      if (database.isOpen) await database.close();
    }
  }
}

PaymentEntity _payment({required String id, required String orderId}) {
  return PaymentEntity(
    id: id,
    serviceOrderId: orderId,
    customerId: 'customer',
    amount: MoneyMinor(100),
    method: PaymentMethod.pix,
    status: PaymentStatus.pending,
    createdAt: '2026-09-17T10:00:00Z',
    updatedAt: '2026-09-17T10:00:00Z',
  );
}

final class _Gateway implements PaymentCommandGateway {
  const _Gateway({this.onCreate, this.onList});

  final Future<PaymentEntity> Function(String operationId)? onCreate;
  final Future<List<PaymentEntity>> Function()? onList;

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
      onList?.call() ?? Future.value(const <PaymentEntity>[]);

  @override
  Future<PaymentEntity> transition({
    required String operationId,
    required String paymentId,
    required PaymentStatus status,
  }) =>
      throw UnimplementedError();
}
