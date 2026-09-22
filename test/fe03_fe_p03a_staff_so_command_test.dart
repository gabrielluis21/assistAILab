import 'dart:async';
import 'dart:convert';

import 'package:assistailab/core/commands/command_intent.dart';
import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/features/service_orders/staff_so_commands_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/customer_quote_test_database.dart';

const _orderId = '10000000-0000-4000-8000-000000000001';
const _scopeA = ProfessionalAuthScope(userId: 'user-a', organizationId: 'org-1');
const _scopeB = ProfessionalAuthScope(userId: 'user-b', organizationId: 'org-2');
const _keyA = AuthenticatedSessionKey(scope: _scopeA, sessionGeneration: 1);
const _keyB = AuthenticatedSessionKey(scope: _scopeB, sessionGeneration: 2);

const _adminUser = User(
  id: 'user-a',
  name: 'Admin User',
  email: 'admin@example.com',
  role: 'ADMIN',
  status: 'ACTIVE',
  organizationId: 'org-1',
);

const _techUser = User(
  id: 'user-tech',
  name: 'Tech User',
  email: 'tech@example.com',
  role: 'TECHNICIAN',
  status: 'ACTIVE',
  organizationId: 'org-1',
);

const _customerUser = User(
  id: 'user-cust',
  name: 'Customer User',
  email: 'cust@example.com',
  role: 'CUSTOMER',
  status: 'ACTIVE',
  customerId: 'cust-1',
);

final _controlledStaffSessionKey =
    StateProvider<AuthenticatedSessionKey?>((ref) => _keyA);
final _controlledStaffUser = StateProvider<User?>((ref) => _adminUser);

Map<String, dynamic> _validProjectionWire({String serviceOrderId = _orderId}) =>
    {
      'contractVersion': 2,
      'projectionRevision': '2',
      'id': serviceOrderId,
      'friendlyId': 10,
      'organizationId': 'org-1',
      'customerId': 'cust-1',
      'equipmentId': 'equipment-1',
      'technicianId': 'user-tech',
      'status': 'EM_EXECUCAO',
      'problemDescription': 'Não liga',
      'diagnosis': 'Fonte queimada',
      'solution': null,
      'totalAmountMinor': 25000,
      'updatedAt': '2026-09-21T10:01:00.000Z',
      'items': [
        {
          'id': 'item-1',
          'serviceOrderId': serviceOrderId,
          'partId': null,
          'description': 'Troca de capacitor',
          'quantity': 2,
          'unitPriceMinor': 12500,
          'totalPriceMinor': 25000,
          'createdAt': '2026-09-21T10:01:00.000Z',
        }
      ],
    };

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
    StaffSoCommandGateway gateway, {
    bool online = true,
    String Function()? operationIdFactory,
  }) =>
      ProviderContainer(
        overrides: [
          authenticatedSessionKeyProvider.overrideWith(
            (ref) => ref.watch(_controlledStaffSessionKey),
          ),
          currentUserProvider.overrideWith(
            (ref) => ref.watch(_controlledStaffUser),
          ),
          isOnlineSessionProvider.overrideWith((ref) => online),
          staffSoDatabaseManagerProvider.overrideWithValue(manager),
          staffSoCommandGatewayProvider.overrideWithValue(gateway),
          staffSoOperationIdFactoryProvider.overrideWithValue(
            operationIdFactory ?? () => 'operation-a',
          ),
        ],
      );

  Future<BoundDatabaseHandle> switchToB(ProviderContainer container) async {
    final handle = await manager.openDatabaseForScope(
      _scopeB,
      sessionGeneration: _keyB.sessionGeneration,
    );
    container.read(_controlledStaffSessionKey.notifier).state = _keyB;
    return handle;
  }

  Future<void> dispose() async {
    for (final db in databases) {
      if (db.isOpen) await db.close();
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

final class _TrackingGateway implements StaffSoCommandGateway {
  _TrackingGateway({
    this.onPublish,
    this.onResume,
    this.onReady,
    this.onProjection,
  });

  final Future<void> Function(String opId)? onPublish;
  final Future<void> Function(String opId)? onResume;
  final Future<void> Function(String opId)? onReady;
  final Future<StaffServiceOrderProjection> Function(String serviceOrderId)?
      onProjection;

  final List<String> dispatchedOperations = [];
  int projectionReads = 0;

  @override
  Future<void> publishInitialQuote({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async {
    dispatchedOperations.add(operationId);
    await onPublish?.call(operationId);
  }

  @override
  Future<void> publishCommercialRevision({
    required String operationId,
    required String serviceOrderId,
    required String? diagnosis,
    required List<StaffSoQuoteRevisionItem> items,
    required String changeReason,
  }) async {
    dispatchedOperations.add(operationId);
  }

  @override
  Future<void> resumeApprovedScope({
    required String operationId,
    required String serviceOrderId,
    required String reason,
  }) async {
    dispatchedOperations.add(operationId);
    await onResume?.call(operationId);
  }

  @override
  Future<void> markReady({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  }) async {
    dispatchedOperations.add(operationId);
    await onReady?.call(operationId);
  }

  @override
  Future<void> markDelivered({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  }) async {
    dispatchedOperations.add(operationId);
  }

  @override
  Future<StaffServiceOrderProjection> readProjection(
    String serviceOrderId,
  ) async {
    projectionReads++;
    if (onProjection != null) return onProjection!(serviceOrderId);
    return StaffServiceOrderProjection(
      serviceOrderId: serviceOrderId,
      wire: _validProjectionWire(serviceOrderId: serviceOrderId),
    );
  }
}

void main() {
  setUp(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 1-3: Ownership set invariants
  // ─────────────────────────────────────────────────────────────────────────

  test('1. ownership set contains exactly five approved command types', () {
    expect(staffSoOwnedCommandTypes, {
      'SERVICE_ORDER_QUOTE_PUBLISH',
      'SERVICE_ORDER_QUOTE_REVISE',
      'SERVICE_ORDER_RESUME_APPROVED_SCOPE',
      'SERVICE_ORDER_MARK_READY',
      'SERVICE_ORDER_MARK_DELIVERED',
    });
    expect(staffSoOwnedCommandTypes.length, 5);
  });

  test('2. no SO_STATUS_UPDATE ownership', () {
    expect(staffSoOwnedCommandTypes.contains('SO_STATUS_UPDATE'), isFalse);
    expect(
      staffSoOwnedCommandTypes.contains('SERVICE_ORDER_STATUS_UPDATE'),
      isFalse,
    );
  });

  test('3. no SO_NOT_APPROVED ownership', () {
    expect(staffSoOwnedCommandTypes.contains('SO_NOT_APPROVED'), isFalse);
    expect(
      staffSoOwnedCommandTypes.contains('SERVICE_ORDER_NOT_APPROVED'),
      isFalse,
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 4-5: Exact HTTP endpoints and X-Operation-Id headers
  // ─────────────────────────────────────────────────────────────────────────

  test('4. exact endpoint for all five commands', () async {
    final recorded = <String, String>{};
    final gateway = StaffSoHttpCommandGateway.forTesting(
      get: (endpoint) async => http.Response(
        jsonEncode(_validProjectionWire()),
        200,
      ),
      post: (endpoint, {body, headers = const {}}) async {
        recorded[endpoint] = 'OK';
        return http.Response('{"ok": true}', 200);
      },
    );

    await gateway.publishInitialQuote(
      operationId: 'op-1',
      serviceOrderId: _orderId,
    );
    await gateway.publishCommercialRevision(
      operationId: 'op-2',
      serviceOrderId: _orderId,
      diagnosis: 'diag',
      items: [
        const StaffSoQuoteRevisionItem(
          description: 'part',
          quantity: 1,
          unitPriceMinor: 100,
        )
      ],
      changeReason: 'rev',
    );
    await gateway.resumeApprovedScope(
      operationId: 'op-3',
      serviceOrderId: _orderId,
      reason: 'res',
    );
    await gateway.markReady(operationId: 'op-4', serviceOrderId: _orderId);
    await gateway.markDelivered(operationId: 'op-5', serviceOrderId: _orderId);

    expect(
      recorded.containsKey('/service-orders/$_orderId/quotes/publish'),
      isTrue,
    );
    expect(
      recorded.containsKey('/service-orders/$_orderId/quotes/revise'),
      isTrue,
    );
    expect(
      recorded.containsKey(
        '/service-orders/$_orderId/quotes/resume-approved-scope',
      ),
      isTrue,
    );
    expect(
      recorded.containsKey('/service-orders/$_orderId/mark-ready'),
      isTrue,
    );
    expect(
      recorded.containsKey('/service-orders/$_orderId/mark-delivered'),
      isTrue,
    );
  });

  test('5. exact X-Operation-Id for all five', () async {
    final headersSeen = <String, String?>{};
    final gateway = StaffSoHttpCommandGateway.forTesting(
      get: (_) async => http.Response(jsonEncode(_validProjectionWire()), 200),
      post: (endpoint, {body, headers = const {}}) async {
        headersSeen[endpoint] = headers['X-Operation-Id'];
        return http.Response('{"ok": true}', 200);
      },
    );

    await gateway.publishInitialQuote(
      operationId: 'op-pub',
      serviceOrderId: _orderId,
    );
    await gateway.publishCommercialRevision(
      operationId: 'op-rev',
      serviceOrderId: _orderId,
      diagnosis: null,
      items: [
        const StaffSoQuoteRevisionItem(
          description: 'item',
          quantity: 1,
          unitPriceMinor: 50,
        )
      ],
      changeReason: 'reason',
    );
    await gateway.resumeApprovedScope(
      operationId: 'op-resume',
      serviceOrderId: _orderId,
      reason: 'reason',
    );
    await gateway.markReady(operationId: 'op-ready', serviceOrderId: _orderId);
    await gateway.markDelivered(
      operationId: 'op-delivered',
      serviceOrderId: _orderId,
    );

    expect(
      headersSeen['/service-orders/$_orderId/quotes/publish'],
      'op-pub',
    );
    expect(
      headersSeen['/service-orders/$_orderId/quotes/revise'],
      'op-rev',
    );
    expect(
      headersSeen['/service-orders/$_orderId/quotes/resume-approved-scope'],
      'op-resume',
    );
    expect(
      headersSeen['/service-orders/$_orderId/mark-ready'],
      'op-ready',
    );
    expect(
      headersSeen['/service-orders/$_orderId/mark-delivered'],
      'op-delivered',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 6-12: Exact canonical payloads and normalization
  // ─────────────────────────────────────────────────────────────────────────

  test('6. exact canonical payload publish', () {
    const identity = StaffSoPublishQuoteIdentity(
      serviceOrderId: _orderId,
      changeReason: '  Initial quote note  ',
    );
    expect(identity.toCanonicalPayload(), {
      'changeReason': '  Initial quote note  ',
      'serviceOrderId': _orderId,
    });
    final intent = CommandIntent(
      operationId: 'op-1',
      commandType: 'SERVICE_ORDER_QUOTE_PUBLISH',
      targetId: _orderId,
      canonicalPayload: jsonEncode({
        'changeReason': 'Initial quote note',
        'serviceOrderId': _orderId,
      }),
      lifecycle: CommandIntentLifecycle.pending,
      createdAt: '2026-09-21T10:00:00.000Z',
      updatedAt: '2026-09-21T10:00:00.000Z',
    );
    final reconstructed = StaffSoPublishQuoteIdentity.fromIntent(intent);
    expect(reconstructed.serviceOrderId, _orderId);
    expect(reconstructed.changeReason, 'Initial quote note');
  });

  test('7. exact canonical payload revise', () {
    const identity = StaffSoReviseQuoteIdentity(
      serviceOrderId: _orderId,
      diagnosis: 'Broken screen',
      items: [
        StaffSoQuoteRevisionItem(
          description: 'LCD Panel',
          quantity: 1,
          unitPriceMinor: 15000,
        )
      ],
      changeReason: 'Customer requested OEM part',
    );
    expect(identity.toCanonicalPayload(), {
      'changeReason': 'Customer requested OEM part',
      'diagnosis': 'Broken screen',
      'items': [
        {
          'description': 'LCD Panel',
          'quantity': 1,
          'unitPriceMinor': 15000,
        }
      ],
      'serviceOrderId': _orderId,
    });
  });

  test('8. MoneyMinor-only revise payload', () {
    const item = StaffSoQuoteRevisionItem(
      description: 'Cable',
      quantity: 3,
      unitPriceMinor: 2500,
    );
    expect(item.unitPriceMinor, isA<int>());
    expect(item.toMap()['unitPriceMinor'], 2500);
    // Disallows floating point
    expect(
      () => StaffSoQuoteRevisionItem.fromMap({
        'description': 'Cable',
        'quantity': 1,
        'unitPriceMinor': 25.5, // double invalid
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('9. deterministic revise item representation', () {
    const item1 = StaffSoQuoteRevisionItem(
      description: 'Screw',
      quantity: 10,
      unitPriceMinor: 50,
    );
    const item2 = StaffSoQuoteRevisionItem(
      description: 'Screw',
      quantity: 10,
      unitPriceMinor: 50,
    );
    expect(item1, equals(item2));
    expect(jsonEncode(item1.toMap()), jsonEncode(item2.toMap()));
  });

  test('10. exact canonical payload resume', () {
    const identity = StaffSoResumeScopeIdentity(
      serviceOrderId: _orderId,
      reason: 'Resume approved scope',
    );
    expect(identity.toCanonicalPayload(), {
      'reason': 'Resume approved scope',
      'serviceOrderId': _orderId,
    });
  });

  test('11. exact canonical payload mark-ready', () {
    const identity = StaffSoMarkReadyIdentity(
      serviceOrderId: _orderId,
      notes: 'Ready for pickup',
    );
    expect(identity.toCanonicalPayload(), {
      'notes': 'Ready for pickup',
      'serviceOrderId': _orderId,
    });
  });

  test('12. exact canonical payload mark-delivered', () {
    const identity = StaffSoMarkDeliveredIdentity(
      serviceOrderId: _orderId,
      notes: 'Delivered to owner',
    );
    expect(identity.toCanonicalPayload(), {
      'notes': 'Delivered to owner',
      'serviceOrderId': _orderId,
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 13-15: Role Safety (ADMIN / TECHNICIAN accepted, CUSTOMER rejected)
  // ─────────────────────────────────────────────────────────────────────────

  test('13. ADMIN accepted', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);
    container.read(_controlledStaffUser.notifier).state = _adminUser;

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await container
        .read(staffSoCommandsProvider.notifier)
        .markReady(serviceOrderId: _orderId);
    expect(gateway.dispatchedOperations, ['operation-a']);
  });

  test('14. TECHNICIAN accepted', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);
    container.read(_controlledStaffUser.notifier).state = _techUser;

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await container
        .read(staffSoCommandsProvider.notifier)
        .markReady(serviceOrderId: _orderId);
    expect(gateway.dispatchedOperations, ['operation-a']);
  });

  test('15. CUSTOMER rejected before dispatch', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);
    container.read(_controlledStaffUser.notifier).state = _customerUser;

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(
        isA<StaffSoCommandException>().having(
          (e) => e.errorCode,
          'errorCode',
          'STAFF_ROLE_REQUIRED',
        ),
      ),
    );
    expect(gateway.dispatchedOperations, isEmpty);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 16: Recovery Isolation
  // ─────────────────────────────────────────────────────────────────────────

  test('16. STAFF/Payment/CUSTOMER recovery isolation', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final intents = CommandIntentLocalDataSource();

    final staff = await intents.getOrCreate(
      commandType: staffSoQuotePublishCommandType,
      targetId: _orderId,
      payload: const {'serviceOrderId': _orderId},
      operationIdFactory: () => 'staff-sending',
      executor: harness.handleA.database,
    );
    final payment = await intents.getOrCreate(
      commandType: 'PAYMENT_CREATE',
      targetId: _orderId,
      payload: const {'amountMinor': 100},
      operationIdFactory: () => 'payment-sending',
      executor: harness.handleA.database,
    );
    final customer = await intents.getOrCreate(
      commandType: 'CUSTOMER_QUOTE_DECISION',
      targetId: _orderId,
      payload: const {'decision': 'APPROVE'},
      operationIdFactory: () => 'customer-sending',
      executor: harness.handleA.database,
    );

    for (final intent in [staff, payment, customer]) {
      await intents.setLifecycle(
        intent.operationId,
        CommandIntentLifecycle.sending,
        executor: harness.handleA.database,
      );
    }

    await intents.recoverInterruptedSending(
      ownedCommandTypes: staffSoOwnedCommandTypes,
      executor: harness.handleA.database,
    );

    expect(
      await _lifecycleById(harness.handleA.database, 'staff-sending'),
      'UNKNOWN',
    );
    expect(
      await _lifecycleById(harness.handleA.database, 'payment-sending'),
      'SENDING',
    );
    expect(
      await _lifecycleById(harness.handleA.database, 'customer-sending'),
      'SENDING',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 17-21: Mutation failures before POST success
  // ─────────────────────────────────────────────────────────────────────────

  test('17. timeout during mutation → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onPublish: (_) => throw TimeoutException('gateway timed out'),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .publishInitialQuote(serviceOrderId: _orderId),
      throwsA(isA<TimeoutException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('18. deterministic mutation conflict → REJECTED', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onPublish: (_) => throw const StaffSoCommandException(400, 'INVALID_STATUS'),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .publishInitialQuote(serviceOrderId: _orderId),
      throwsA(isA<StaffSoCommandException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'REJECTED');
  });

  test('19. IDEMPOTENCY_KEY_REUSE → REJECTED', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onPublish: (_) => throw const StaffSoCommandException(
        409,
        'IDEMPOTENCY_KEY_REUSE',
      ),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .publishInitialQuote(serviceOrderId: _orderId),
      throwsA(isA<StaffSoCommandException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'REJECTED');
  });

  test('20. IDEMPOTENCY_IN_PROGRESS → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onPublish: (_) => throw const StaffSoCommandException(
        409,
        'IDEMPOTENCY_IN_PROGRESS',
      ),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .publishInitialQuote(serviceOrderId: _orderId),
      throwsA(isA<StaffSoCommandException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('21. IDEMPOTENCY_STATE_CONFLICT → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onPublish: (_) => throw const StaffSoCommandException(
        409,
        'IDEMPOTENCY_STATE_CONFLICT',
      ),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .publishInitialQuote(serviceOrderId: _orderId),
      throwsA(isA<StaffSoCommandException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 22-31: POST success + projection failure → UNKNOWN
  // ─────────────────────────────────────────────────────────────────────────

  test('22. POST success + projection 409 → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) => throw const StaffSoCommandException(
        409,
        'SYNC_V2_REFRESH_REQUIRED',
      ),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('23. POST success + projection 401 → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) => throw const StaffSoCommandException(
        401,
        'UNAUTHORIZED',
      ),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('24. projection 403 → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) => throw const StaffSoCommandException(403, 'FORBIDDEN'),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('25. projection 404 → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) => throw const StaffSoCommandException(404, 'NOT_FOUND'),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('26. projection 5xx → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) => throw const StaffSoCommandException(500, 'SERVER_ERROR'),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('27. projection timeout → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) => throw TimeoutException('projection timed out'),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('28. malformed projection → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) => throw const FormatException('malformed json'),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('29. wrong projection serviceOrderId → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway(
      onProjection: (_) async => StaffServiceOrderProjection(
        serviceOrderId: 'wrong-id',
        wire: _validProjectionWire(serviceOrderId: 'wrong-id'),
      ),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('30. wrong projection contractVersion → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final badWire = _validProjectionWire();
    badWire['contractVersion'] = 1; // contract version 1 invalid
    final gateway = _TrackingGateway(
      onProjection: (_) async => StaffServiceOrderProjection(
        serviceOrderId: _orderId,
        wire: badWire,
      ),
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StaffSoProjectionUncertaintyException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  test('31. local projection persistence failure → UNKNOWN', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    // Drop the service_orders table so SyncProjectionApplier fails inside commit
    await harness.handleA.database.execute('DROP TABLE service_orders');

    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<Object>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 32: Successful projection + COMPLETED atomic
  // ─────────────────────────────────────────────────────────────────────────

  test('32. successful projection + COMPLETED atomic', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await container
        .read(staffSoCommandsProvider.notifier)
        .markReady(serviceOrderId: _orderId);

    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');
    final rows = await harness.handleA.database.query('service_orders');
    expect(rows.length, 1);
    expect(rows.single['id'], _orderId);
    expect(rows.single['status'], 'EM_EXECUCAO');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 33-35: UNKNOWN retry preserves identity and operationId
  // ─────────────────────────────────────────────────────────────────────────

  test('33. UNKNOWN retry uses same operationId', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    var attempt = 0;
    final gateway = _TrackingGateway(
      onPublish: (_) async {
        if (attempt++ == 0) throw TimeoutException('network timeout');
      },
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    // Call 1 fails with timeout
    await expectLater(
      container.read(staffSoCommandsProvider.notifier).publishInitialQuote(
            serviceOrderId: _orderId,
            changeReason: 'reason',
          ),
      throwsA(isA<TimeoutException>()),
    );
    expect(await _lifecycle(harness.handleA.database), 'UNKNOWN');

    // Call 2 retries with same parameters
    await container.read(staffSoCommandsProvider.notifier).publishInitialQuote(
          serviceOrderId: _orderId,
          changeReason: 'reason',
        );
    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');

    expect(gateway.dispatchedOperations, ['operation-a', 'operation-a']);
  });

  test('34. UNKNOWN retry uses original immutable payload', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    var attempt = 0;
    final gateway = _TrackingGateway(
      onResume: (_) async {
        if (attempt++ == 0) throw TimeoutException('first attempt timeout');
      },
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container.read(staffSoCommandsProvider.notifier).resumeApprovedScope(
            serviceOrderId: _orderId,
            reason: 'scope note',
          ),
      throwsA(isA<TimeoutException>()),
    );

    // Verify stored payload in command_intents
    final intentRow =
        (await harness.handleA.database.query('command_intents')).single;
    final payloadJson = intentRow['payload_json'] as String;

    await container.read(staffSoCommandsProvider.notifier).resumeApprovedScope(
          serviceOrderId: _orderId,
          reason: 'scope note',
        );

    final secondRow =
        (await harness.handleA.database.query('command_intents')).single;
    expect(secondRow['payload_json'], payloadJson);
  });

  test('35. retry does not depend on original pre-command status', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    var attempt = 0;
    final gateway = _TrackingGateway(
      onReady: (_) async {
        if (attempt++ == 0) throw TimeoutException('first timeout');
      },
    );
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container.read(staffSoCommandsProvider.notifier).markReady(
            serviceOrderId: _orderId,
            notes: 'ready notes',
          ),
      throwsA(isA<TimeoutException>()),
    );

    // Modify the local service_orders status to something completely different
    await harness.handleA.database.insert('service_orders', {
      'id': _orderId,
      'status': 'ENTREGUE',
      'equipment_id': 'equip-1',
      'problem_description': 'desc',
      'total_amount_minor': 100,
      'projection_revision': '1',
      'updated_at': '2026-09-21T11:00:00.000Z',
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Replay should still succeed regardless of pre-command status
    await container.read(staffSoCommandsProvider.notifier).markReady(
          serviceOrderId: _orderId,
          notes: 'ready notes',
        );
    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 36-39: Unresolved intent fail-closed and concurrency rules
  // ─────────────────────────────────────────────────────────────────────────

  test('36. malformed unresolved payload fails closed', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.handleA.database.insert('command_intents', {
      'operation_id': 'op-malformed',
      'command_type': staffSoQuotePublishCommandType,
      'target_id': _orderId,
      'payload_json': 'NOT_VALID_JSON{',
      'lifecycle_state': 'UNKNOWN',
      'created_at': '2026-09-21T10:00:00.000Z',
      'updated_at': '2026-09-21T10:00:00.000Z',
    });

    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .publishInitialQuote(serviceOrderId: _orderId),
      throwsA(isA<FormatException>()),
    );
    expect(gateway.dispatchedOperations, isEmpty);
  });

  test('37. ambiguous unresolved identity fails closed', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);

    // Drop unique index to simulate database state where multiple matching intents exist
    await harness.handleA.database.execute(
      'DROP INDEX IF EXISTS command_intents_unresolved_identity',
    );

    final canonicalJson = jsonEncode({
      'reason': 'scope reason',
      'serviceOrderId': _orderId,
    });

    await harness.handleA.database.insert('command_intents', {
      'operation_id': 'op-1',
      'command_type': staffSoResumeApprovedScopeCommandType,
      'target_id': _orderId,
      'payload_json': canonicalJson,
      'lifecycle_state': 'UNKNOWN',
      'created_at': '2026-09-21T10:00:00.000Z',
      'updated_at': '2026-09-21T10:00:00.000Z',
    });
    await harness.handleA.database.insert('command_intents', {
      'operation_id': 'op-2',
      'command_type': staffSoResumeApprovedScopeCommandType,
      'target_id': _orderId,
      'payload_json': canonicalJson,
      'lifecycle_state': 'UNKNOWN',
      'created_at': '2026-09-21T10:00:00.000Z',
      'updated_at': '2026-09-21T10:00:00.000Z',
    });

    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    await expectLater(
      container.read(staffSoCommandsProvider.notifier).resumeApprovedScope(
            serviceOrderId: _orderId,
            reason: 'scope reason',
          ),
      throwsA(isA<StateError>()),
    );
    expect(gateway.dispatchedOperations, isEmpty);
  });

  test('38. unrelated unresolved action is not consumed', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    await harness.handleA.database.insert('command_intents', {
      'operation_id': 'op-unrelated',
      'command_type': staffSoQuotePublishCommandType,
      'target_id': _orderId,
      'payload_json': jsonEncode({
        'changeReason': 'unrelated old reason',
        'serviceOrderId': _orderId,
      }),
      'lifecycle_state': 'UNKNOWN',
      'created_at': '2026-09-21T10:00:00.000Z',
      'updated_at': '2026-09-21T10:00:00.000Z',
    });

    final gateway = _TrackingGateway();
    var opCount = 0;
    final container = harness.container(
      gateway,
      operationIdFactory: () => 'op-new-${++opCount}',
    );
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    // Call with a DIFFERENT reason
    await container.read(staffSoCommandsProvider.notifier).publishInitialQuote(
          serviceOrderId: _orderId,
          changeReason: 'brand new reason',
        );

    // Should create and dispatch a new intent, leaving the unrelated one untouched
    expect(gateway.dispatchedOperations, ['op-new-1']);
    expect(
      await _lifecycleById(harness.handleA.database, 'op-unrelated'),
      'UNKNOWN',
    );
    expect(
      await _lifecycleById(harness.handleA.database, 'op-new-1'),
      'COMPLETED',
    );
  });

  test('39. live SENDING is not replayed concurrently', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);

    final gateway = _TrackingGateway();
    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    // Insert live SENDING intent after build has run so it is not recovered on boot
    await harness.handleA.database.insert('command_intents', {
      'operation_id': 'op-inflight',
      'command_type': staffSoMarkReadyCommandType,
      'target_id': _orderId,
      'payload_json': jsonEncode({'serviceOrderId': _orderId}),
      'lifecycle_state': 'SENDING',
      'created_at': '2026-09-21T10:00:00.000Z',
      'updated_at': '2026-09-21T10:00:00.000Z',
    });

    await expectLater(
      container
          .read(staffSoCommandsProvider.notifier)
          .markReady(serviceOrderId: _orderId),
      throwsA(isA<StateError>()),
    );
    expect(gateway.dispatchedOperations, isEmpty);
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 40: Non-auto-dispose lifecycle & listener churn
  // ─────────────────────────────────────────────────────────────────────────

  test('40. listener churn does not recover live SENDING', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final inFlight = Completer<void>();
    final responseGate = Completer<void>();

    final gateway = _TrackingGateway(
      onReady: (_) {
        inFlight.complete();
        return responseGate.future;
      },
    );

    final container = harness.container(gateway);
    addTearDown(container.dispose);

    var subscription = container.listen(
      staffSoCommandsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(staffSoCommandsProvider.future);

    final notifier = container.read(staffSoCommandsProvider.notifier);
    final commandFuture = notifier.markReady(serviceOrderId: _orderId);

    // Wait until command is dispatched and in flight
    await inFlight.future;
    expect(await _lifecycle(harness.handleA.database), 'SENDING');

    // Churn listeners (remove and re-add)
    subscription.close();
    await Future<void>.delayed(Duration.zero);
    subscription = container.listen(
      staffSoCommandsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    // Notifier instance must be stable and SENDING must not have been recovered to UNKNOWN
    expect(
      identical(notifier, container.read(staffSoCommandsProvider.notifier)),
      isTrue,
    );
    expect(await _lifecycle(harness.handleA.database), 'SENDING');

    // Finish the response
    responseGate.complete();
    await commandFuture;

    expect(await _lifecycle(harness.handleA.database), 'COMPLETED');
  });

  // ─────────────────────────────────────────────────────────────────────────
  // 41-43: Session A→B isolation during execution
  // ─────────────────────────────────────────────────────────────────────────

  test('41. session A→B during POST cannot commit/publish', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final enteredPost = Completer<void>();
    final postGate = Completer<void>();

    final gateway = _TrackingGateway(
      onReady: (_) {
        enteredPost.complete();
        return postGate.future;
      },
    );

    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    final command = container
        .read(staffSoCommandsProvider.notifier)
        .markReady(serviceOrderId: _orderId)
        .then<Object?>((_) => null, onError: (Object error) => error);

    await enteredPost.future;
    final handleB = await harness.switchToB(container);
    await container.read(staffSoCommandsProvider.future);
    postGate.complete();

    expect(await command, isA<StateError>());
    expect(await _lifecycle(harness.handleA.database), 'SENDING');
    expect(await handleB.database.query('service_orders'), isEmpty);
    expect(await handleB.database.query('command_intents'), isEmpty);
  });

  test('42. session A→B during projection cannot commit/publish', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    final enteredProjection = Completer<void>();
    final projectionGate = Completer<StaffServiceOrderProjection>();

    final gateway = _TrackingGateway(
      onProjection: (_) {
        enteredProjection.complete();
        return projectionGate.future;
      },
    );

    final container = harness.container(gateway);
    addTearDown(container.dispose);

    final sub = container.listen(staffSoCommandsProvider, (_, __) {});
    addTearDown(sub.close);
    await container.read(staffSoCommandsProvider.future);

    final command = container
        .read(staffSoCommandsProvider.notifier)
        .markReady(serviceOrderId: _orderId)
        .then<Object?>((_) => null, onError: (Object error) => error);

    await enteredProjection.future;
    final handleB = await harness.switchToB(container);
    await container.read(staffSoCommandsProvider.future);
    projectionGate.complete(StaffServiceOrderProjection(
      serviceOrderId: _orderId,
      wire: _validProjectionWire(),
    ));

    expect(await command, isA<StateError>());
    expect(await _lifecycle(harness.handleA.database), 'SENDING');
    expect(await handleB.database.query('service_orders'), isEmpty);
    expect(await handleB.database.query('command_intents'), isEmpty);
  });

  test('43. stale A journal remains isolated/recoverable', () async {
    final harness = await _Harness.create();
    addTearDown(harness.dispose);
    // Insert a SENDING intent into A
    await harness.handleA.database.insert('command_intents', {
      'operation_id': 'op-abandoned-a',
      'command_type': staffSoMarkDeliveredCommandType,
      'target_id': _orderId,
      'payload_json': jsonEncode({'serviceOrderId': _orderId}),
      'lifecycle_state': 'SENDING',
      'created_at': '2026-09-21T10:00:00.000Z',
      'updated_at': '2026-09-21T10:00:00.000Z',
    });

    final handleB = await harness.manager.openDatabaseForScope(
      _scopeB,
      sessionGeneration: _keyB.sessionGeneration,
    );

    // Database B has no intents
    expect(await handleB.database.query('command_intents'), isEmpty);

    // Recovering A promotes the abandoned SENDING to UNKNOWN
    final intents = CommandIntentLocalDataSource();
    await intents.recoverInterruptedSending(
      ownedCommandTypes: staffSoOwnedCommandTypes,
      executor: harness.handleA.database,
    );

    expect(
      await _lifecycleById(harness.handleA.database, 'op-abandoned-a'),
      'UNKNOWN',
    );
    expect(await handleB.database.query('command_intents'), isEmpty);
  });
}
