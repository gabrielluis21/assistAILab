import 'dart:async';

import 'package:assistailab/core/commands/command_intent.dart';
import 'package:assistailab/core/database/service_order_repository.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:assistailab/features/service_orders/staff_so_command_executor.dart';
import 'package:assistailab/features/service_orders/staff_so_command_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// Stub gateway
// ---------------------------------------------------------------------------

final class _StubGateway implements StaffSoCommandGateway {
  int callCount = 0;
  Object? _nextThrow;

  void throwNext(Object e) => _nextThrow = e;

  ServiceOrderEntity _respond(String serviceOrderId) {
    callCount++;
    final throwable = _nextThrow;
    if (throwable != null) {
      _nextThrow = null;
      throw throwable;
    }
    return ServiceOrderEntity(
      id: serviceOrderId,
      customerId: 'cust-1',
      equipmentId: 'equip-1',
      status: ServiceOrderStatusEnum.diagnostico,
      problemDescription: 'problem',
      updatedAt: DateTime.now().toIso8601String(),
    );
  }

  @override
  Future<ServiceOrderEntity> updateStatus({
    required String operationId,
    required String serviceOrderId,
    required ServiceOrderStatusEnum status,
  }) async =>
      _respond(serviceOrderId);

  @override
  Future<ServiceOrderEntity> publishInitialQuote({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async =>
      _respond(serviceOrderId);

  @override
  Future<ServiceOrderEntity> publishCommercialRevision({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async =>
      _respond(serviceOrderId);

  @override
  Future<ServiceOrderEntity> resumeApprovedScope({
    required String operationId,
    required String serviceOrderId,
  }) async =>
      _respond(serviceOrderId);

  @override
  Future<ServiceOrderEntity> markReady({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  }) async =>
      _respond(serviceOrderId);

  @override
  Future<ServiceOrderEntity> markDelivered({
    required String operationId,
    required String serviceOrderId,
  }) async =>
      _respond(serviceOrderId);

  @override
  Future<ServiceOrderEntity> recordNotApproved({
    required String operationId,
    required String serviceOrderId,
  }) async =>
      _respond(serviceOrderId);
}

/// Gateway that flips [onCall] (simulating session invalidation) then throws
/// [errorToThrow], so [CommandExecutor] observes stale binding in its catch.
final class _FlipBeforeThrowGateway implements StaffSoCommandGateway {
  const _FlipBeforeThrowGateway({
    required this.onCall,
    required this.errorToThrow,
    required this.responseId,
  });

  final void Function() onCall;
  final Object errorToThrow;
  final String responseId;

  Never _throw() {
    onCall();
    throw errorToThrow;
  }

  @override
  Future<ServiceOrderEntity> updateStatus({
    required String operationId,
    required String serviceOrderId,
    required ServiceOrderStatusEnum status,
  }) async => _throw();

  @override
  Future<ServiceOrderEntity> publishInitialQuote({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async => _throw();

  @override
  Future<ServiceOrderEntity> publishCommercialRevision({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async => _throw();

  @override
  Future<ServiceOrderEntity> resumeApprovedScope({
    required String operationId,
    required String serviceOrderId,
  }) async => _throw();

  @override
  Future<ServiceOrderEntity> markReady({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  }) async => _throw();

  @override
  Future<ServiceOrderEntity> markDelivered({
    required String operationId,
    required String serviceOrderId,
  }) async => _throw();

  @override
  Future<ServiceOrderEntity> recordNotApproved({
    required String operationId,
    required String serviceOrderId,
  }) async => _throw();
}


// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<Database> _openInMemoryDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE command_intents (
            operation_id TEXT PRIMARY KEY,
            command_type TEXT NOT NULL,
            target_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            lifecycle_state TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE service_orders (
            id TEXT PRIMARY KEY,
            friendly_id INTEGER,
            customer_id TEXT,
            equipment_id TEXT NOT NULL,
            technician_id TEXT,
            status TEXT NOT NULL,
            problem_description TEXT NOT NULL,
            diagnosis TEXT,
            solution TEXT,
            total_amount_minor INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    ),
  );
  return db;
}

StaffSoCommandIntentExecutor _makeExecutor(
  _StubGateway gateway,
  Database db, {
  bool Function()? isBindingCurrent,
  int operationIdSuffix = 0,
}) {
  int counter = operationIdSuffix;
  return StaffSoCommandIntentExecutor(
    gateway: gateway,
    serviceOrderRepository: ServiceOrderLocalDataSource(),
    intentRepository: CommandIntentLocalDataSource(),
    database: db,
    isBindingCurrent: isBindingCurrent ?? () => true,
    operationIdFactory: () => 'op-id-${counter++}',
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('staffSoOwnedCommandTypes', () {
    test('contains exactly the 7 expected wire values', () {
      expect(staffSoOwnedCommandTypes, {
        'SO_STATUS_UPDATE',
        'SO_QUOTE_PUBLISH',
        'SO_QUOTE_REVISE',
        'SO_QUOTE_RESUME_APPROVED',
        'SO_MARK_READY',
        'SO_MARK_DELIVERED',
        'SO_NOT_APPROVED',
      });
    });

    test('each value satisfies the command-type pattern', () {
      for (final type in staffSoOwnedCommandTypes) {
        expect(
          RegExp(r'^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$').hasMatch(type),
          isTrue,
          reason: '$type did not match command-type pattern',
        );
      }
    });

    test('each StaffSoCommandType.wireValue is in owned set', () {
      for (final t in StaffSoCommandType.values) {
        expect(staffSoOwnedCommandTypes, contains(t.wireValue));
      }
    });
  });

  group('StaffSoCommandIntentExecutor', () {
    late Database db;
    late _StubGateway gateway;

    setUp(() async {
      db = await _openInMemoryDb();
      gateway = _StubGateway();
    });

    tearDown(() => db.close());

    // ── happy-path round-trips ──────────────────────────────────────────

    test('updateStatus dispatches and commits authoritative entity', () async {
      const soId = 'so-001';
      final executor = _makeExecutor(gateway, db);

      final result = await executor.updateStatus(
        serviceOrderId: soId,
        status: ServiceOrderStatusEnum.emExecucao,
      );

      expect(result.id, soId);
      expect(gateway.callCount, 1);

      // intent should be COMPLETED
      final intents = await db.query(
        'command_intents',
        where: 'target_id = ?',
        whereArgs: [soId],
      );
      expect(intents, hasLength(1));
      expect(intents.first['lifecycle_state'], 'COMPLETED');

      // entity committed to local DB
      final rows = await db.query(
        'service_orders',
        where: 'id = ?',
        whereArgs: [soId],
      );
      expect(rows, hasLength(1));
    });

    test('publishInitialQuote round-trip', () async {
      const soId = 'so-002';
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 10);
      final result = await executor.publishInitialQuote(serviceOrderId: soId);
      expect(result.id, soId);
      expect(gateway.callCount, 1);
    });

    test('publishCommercialRevision round-trip', () async {
      const soId = 'so-003';
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 20);
      final result = await executor.publishCommercialRevision(
        serviceOrderId: soId,
        changeReason: 'scope changed',
      );
      expect(result.id, soId);
      expect(gateway.callCount, 1);
    });

    test('resumeApprovedScope round-trip', () async {
      const soId = 'so-004';
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 30);
      final result = await executor.resumeApprovedScope(serviceOrderId: soId);
      expect(result.id, soId);
    });

    test('markReady round-trip', () async {
      const soId = 'so-005';
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 40);
      final result = await executor.markReady(
        serviceOrderId: soId,
        notes: 'all good',
      );
      expect(result.id, soId);
    });

    test('markDelivered round-trip', () async {
      const soId = 'so-006';
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 50);
      final result = await executor.markDelivered(serviceOrderId: soId);
      expect(result.id, soId);
    });

    test('recordNotApproved round-trip', () async {
      const soId = 'so-007';
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 60);
      final result = await executor.recordNotApproved(serviceOrderId: soId);
      expect(result.id, soId);
    });

    // ── idempotency / intent de-duplication ─────────────────────────────

    test('repeated identical command reuses existing PENDING intent', () async {
      const soId = 'so-idem';
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 100);

      // Manually insert a PENDING intent for the same command+payload
      final intentRepo = CommandIntentLocalDataSource();
      await intentRepo.getOrCreate(
        commandType: 'SO_STATUS_UPDATE',
        targetId: soId,
        payload: {
          'serviceOrderId': soId,
          'status': ServiceOrderStatusEnum.emExecucao.toDbString(),
        },
        operationIdFactory: () => 'pre-existing-op-id',
        executor: db,
      );

      await executor.updateStatus(
        serviceOrderId: soId,
        status: ServiceOrderStatusEnum.emExecucao,
      );

      final intents = await db.query(
        'command_intents',
        where: 'target_id = ?',
        whereArgs: [soId],
      );
      // Only one intent (reused), not two
      expect(intents, hasLength(1));
      expect(intents.first['operation_id'], 'pre-existing-op-id');
    });

    // ── failure lifecycle ────────────────────────────────────────────────

    test('4xx gateway failure marks intent REJECTED and rethrows', () async {
      const soId = 'so-rej';
      gateway.throwNext(const StaffSoCommandException(422, 'INVALID_TRANSITION'));
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 200);

      await expectLater(
        () => executor.updateStatus(
          serviceOrderId: soId,
          status: ServiceOrderStatusEnum.entregue,
        ),
        throwsA(isA<StaffSoCommandException>()),
      );

      final intents = await db.query(
        'command_intents',
        where: 'target_id = ?',
        whereArgs: [soId],
      );
      expect(intents.first['lifecycle_state'], 'REJECTED');
    });

    test('timeout marks intent UNKNOWN and rethrows', () async {
      const soId = 'so-timeout';
      gateway.throwNext(TimeoutException('timeout'));
      final executor = _makeExecutor(gateway, db, operationIdSuffix: 300);

      await expectLater(
        () => executor.markReady(serviceOrderId: soId),
        throwsA(isA<TimeoutException>()),
      );

      final intents = await db.query(
        'command_intents',
        where: 'target_id = ?',
        whereArgs: [soId],
      );
      expect(intents.first['lifecycle_state'], 'UNKNOWN');
    });

    test('stale binding rethrows without classifying intent', () async {
      // Scenario: the session becomes stale while the dispatch is in flight.
      // CommandExecutor's catch block sees isBindingCurrent()==false and
      // rethrows immediately — the intent remains SENDING (to be recovered
      // on next boot as UNKNOWN).
      const soId = 'so-stale';
      bool stale = false;

      // The gateway flips `stale` before throwing so CommandExecutor sees
      // a stale binding when it enters the catch block.
      late final StaffSoCommandIntentExecutor executor;
      final stubGw = _FlipBeforeThrowGateway(
        onCall: () => stale = true,
        errorToThrow: StateError('session invalidated mid-flight'),
        responseId: soId,
      );
      executor = StaffSoCommandIntentExecutor(
        gateway: stubGw,
        serviceOrderRepository: ServiceOrderLocalDataSource(),
        intentRepository: CommandIntentLocalDataSource(),
        database: db,
        isBindingCurrent: () => !stale,
        operationIdFactory: () => 'stale-op-id',
      );

      await expectLater(
        () => executor.updateStatus(
          serviceOrderId: soId,
          status: ServiceOrderStatusEnum.diagnostico,
        ),
        throwsA(isA<StateError>()),
      );

      final intents = await db.query(
        'command_intents',
        where: 'target_id = ?',
        whereArgs: [soId],
      );
      // Stale path rethrows before calling setLifecycle — intent stays SENDING.
      expect(intents.first['lifecycle_state'], 'SENDING');
    });

    // ── interrupted-sending recovery ────────────────────────────────────

    test('recoverInterruptedSending promotes SENDING intents to UNKNOWN', () async {
      // Simulate a crash: insert a SENDING intent directly
      final now = DateTime.now().toIso8601String();
      await db.insert('command_intents', {
        'operation_id': 'crashed-op-id',
        'command_type': 'SO_MARK_READY',
        'target_id': 'so-crashed',
        'payload_json': '{"serviceOrderId":"so-crashed"}',
        'lifecycle_state': 'SENDING',
        'created_at': now,
        'updated_at': now,
      });

      final intentRepo = CommandIntentLocalDataSource();
      await intentRepo.recoverInterruptedSending(
        ownedCommandTypes: staffSoOwnedCommandTypes,
        executor: db,
      );

      final rows = await db.query(
        'command_intents',
        where: 'operation_id = ?',
        whereArgs: ['crashed-op-id'],
      );
      expect(rows.first['lifecycle_state'], 'UNKNOWN');
    });

    test('recoverInterruptedSending does not touch foreign command types', () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('command_intents', {
        'operation_id': 'payment-op-id',
        'command_type': 'PAYMENT_CREATE',
        'target_id': 'so-x',
        'payload_json': '{"serviceOrderId":"so-x"}',
        'lifecycle_state': 'SENDING',
        'created_at': now,
        'updated_at': now,
      });

      final intentRepo = CommandIntentLocalDataSource();
      await intentRepo.recoverInterruptedSending(
        ownedCommandTypes: staffSoOwnedCommandTypes,
        executor: db,
      );

      final rows = await db.query(
        'command_intents',
        where: 'operation_id = ?',
        whereArgs: ['payment-op-id'],
      );
      // PAYMENT_CREATE is not owned — must remain SENDING
      expect(rows.first['lifecycle_state'], 'SENDING');
    });
  });
}
