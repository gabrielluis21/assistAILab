import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:assistailab/core/network/api_client.dart';
import 'package:assistailab/core/sync/background_sync_coordinator.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/sync/sync_lease.dart';
import 'package:assistailab/core/sync/sync_state.dart';
import 'package:assistailab/core/sync/sync_trigger.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';

/// Mock HTTP client with request capturing and programmable handlers.
class _CapturingHttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.Request request) handler;
  final List<http.Request> recordedRequests = [];

  _CapturingHttpClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final httpRequest = request as http.Request;
    recordedRequests.add(httpRequest);
    final response = await handler(httpRequest);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
    );
  }
}

class _TrackingOutboxDao extends OutboxDao {
  final void Function(String status)? afterResponseTransition;
  final void Function(String operationId, String toStatus)? onTransition;
  int responseTransitions = 0;

  _TrackingOutboxDao({
    this.afterResponseTransition,
    this.onTransition,
  });

  @override
  Future<bool> transition({
    required String operationId,
    required String fromStatus,
    required RemoteDisposition fromDisposition,
    required String toStatus,
    required RemoteDisposition toDisposition,
    int? attemptCount,
    String? lastAttemptAt,
    String? nextRetryAt,
    String? lastError,
    bool clearLastAttemptAt = false,
    bool clearNextRetryAt = false,
    bool clearLastError = false,
    String? claimId,
    bool clearClaimId = false,
    bool requireUnattempted = false,
    int? expectedAttemptCount,
    String? expectedLastAttemptAt,
    String? expectedClaimId,
    DatabaseExecutor? executor,
  }) async {
    final changed = await super.transition(
      operationId: operationId,
      fromStatus: fromStatus,
      fromDisposition: fromDisposition,
      toStatus: toStatus,
      toDisposition: toDisposition,
      attemptCount: attemptCount,
      lastAttemptAt: lastAttemptAt,
      nextRetryAt: nextRetryAt,
      lastError: lastError,
      clearLastAttemptAt: clearLastAttemptAt,
      clearNextRetryAt: clearNextRetryAt,
      clearLastError: clearLastError,
      claimId: claimId,
      clearClaimId: clearClaimId,
      requireUnattempted: requireUnattempted,
      expectedAttemptCount: expectedAttemptCount,
      expectedLastAttemptAt: expectedLastAttemptAt,
      expectedClaimId: expectedClaimId,
      executor: executor,
    );
    if (changed) {
      onTransition?.call(operationId, toStatus);
      if (toStatus != 'PROCESSING') {
        responseTransitions++;
        afterResponseTransition?.call(toStatus);
      }
    }
    return changed;
  }
}

Future<void> _activateSyncV2(Database db, {String cursor = '0'}) async {
  for (final entry in {
    'sync_contract_version': '2',
    'sync_bootstrap_proof': 'test-bootstrap-proof',
    'last_cursor': cursor,
  }.entries) {
    await db.insert(
      'sync_metadata',
      {'key': entry.key, 'value': entry.value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

Future<Database> _openRawSyncDatabase(String name) async {
  final db = await SqliteDatabase.openDatabaseByName(name);
  await _activateSyncV2(db);
  return db;
}

Future<void> _insertPushItem(
  Database db, {
  required String operationId,
  required String name,
  String entityType = 'CUSTOMER',
  Map<String, dynamic>? payload,
}) {
  return OutboxDao().insert(
    OutboxItem(
      operationId: operationId,
      entityType: entityType,
      entityId: 'entity-$operationId',
      operationType: 'CREATE',
      payload: payload ?? {'name': name},
      createdAt: DateTime.now().toIso8601String(),
    ),
    executor: db,
  );
}

SyncSessionBinding _sessionBinding({
  required BoundDatabaseHandle handle,
  required Future<String?> Function() resolveToken,
}) {
  final manager = AuthScopedDatabaseManager.instance;
  return SyncSessionBinding(
    scope: handle.authScope,
    sessionGeneration: handle.sessionGeneration,
    resolveBoundHandle: () async => handle,
    isHandleCurrent: manager.isCurrentHandle,
    resolveToken: resolveToken,
    isCurrentOnline: () => manager.isCurrentHandle(handle),
    isAuthHttpGenerationCurrent: (sessionGeneration) =>
        sessionGeneration == handle.sessionGeneration &&
        manager.isCurrentHandle(handle),
    onAuthorizationFailure: ({
      required int sessionGeneration,
      required int statusCode,
      required bool authorityRevalidation,
    }) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  var nextSessionGeneration = 0;

  Future<BoundDatabaseHandle> openScopedDatabase(AuthScope scope) async {
    final handle =
        await AuthScopedDatabaseManager.instance.openDatabaseForScope(
      scope,
      sessionGeneration: ++nextSessionGeneration,
    );
    await _activateSyncV2(handle.database);
    return handle;
  }

  Future<void> closeScopedDatabase() {
    return AuthScopedDatabaseManager.instance.closeCurrentDatabase(
      sessionGeneration: ++nextSessionGeneration,
    );
  }

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async {
        return tempDir.path;
      },
    );
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('sync_race_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await closeScopedDatabase();
    if (Hive.isBoxOpen('auth_box')) {
      final box = Hive.box('auth_box');
      await box.close();
    }
    await Hive.deleteBoxFromDisk('auth_box');
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Late Outbox Push Response Protection (Etapa 2)', () {
    test('late SYNCED response after lease cancellation preserves DB A claim',
        () async {
      final dbA = await _openRawSyncDatabase('e2_late_success_a.db');
      final dbB = await _openRawSyncDatabase('e2_late_success_b.db');
      const operationId = 'e2-late-success';
      const payload = {'name': 'Customer A'};
      await _insertPushItem(dbA,
          operationId: operationId, name: payload['name']!);

      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      final transport = _CapturingHttpClient((request) {
        if (request.url.path == '/sync/push') {
          requestStarted.complete();
          return responseGate.future;
        }
        return Future.value(http.Response('Not Found', 404));
      });
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
      );
      var valid = true;
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final push = engine.pushPendingOutbox(lease: lease);
      await requestStarted.future;
      expect(transport.recordedRequests, hasLength(1));
      expect(transport.recordedRequests.single.headers['authorization'],
          'Bearer TOKEN_A');
      final claimed = (await dbA.query('outbox',
              where: 'operation_id = ?', whereArgs: [operationId]))
          .single;
      expect(claimed['status'], 'PROCESSING');
      expect(claimed['remote_disposition'], 'AMBIGUOUS');
      expect(claimed['attempt_count'], 1);
      final attemptAt = claimed['last_attempt_at'];

      valid = false;
      responseGate.complete(http.Response(
        jsonEncode({
          'results': [
            {'operationId': operationId, 'status': 'SYNCED'}
          ]
        }),
        200,
      ));
      final summary = await push;

      final row = (await dbA.query('outbox',
              where: 'operation_id = ?', whereArgs: [operationId]))
          .single;
      expect(summary.syncedCount, 0);
      expect(row['operation_id'], operationId);
      expect(jsonDecode(row['payload'] as String), payload);
      expect(row['status'], 'PROCESSING');
      expect(row['remote_disposition'], 'AMBIGUOUS');
      expect(row['attempt_count'], 1);
      expect(row['last_attempt_at'], attemptAt);
      expect(await dbB.query('outbox'), isEmpty);
      expect(transport.recordedRequests, hasLength(1));

      await engine.pushPendingOutbox(lease: lease);
      expect(transport.recordedRequests, hasLength(1));
      await dbA.close();
      await dbB.close();
    });

    test('HTTP exception after cancellation performs no Outbox recovery writes',
        () async {
      final dbA = await _openRawSyncDatabase('e2_late_error_a.db');
      final dbB = await _openRawSyncDatabase('e2_late_error_b.db');
      const operationId = 'e2-late-error';
      await _insertPushItem(dbA, operationId: operationId, name: 'Customer A');
      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      final transport = _CapturingHttpClient((request) {
        if (request.url.path == '/sync/push') {
          requestStarted.complete();
          return responseGate.future;
        }
        return Future.value(http.Response('Not Found', 404));
      });
      final dao = _TrackingOutboxDao();
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: dao,
      );
      var valid = true;
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final push = engine.pushPendingOutbox(lease: lease);
      await requestStarted.future;
      expect(transport.recordedRequests.single.headers['authorization'],
          'Bearer TOKEN_A');
      final claimed = (await dbA.query('outbox',
              where: 'operation_id = ?', whereArgs: [operationId]))
          .single;
      final attemptAt = claimed['last_attempt_at'];
      valid = false;
      responseGate.completeError(StateError('late transport failure'));
      final summary = await push;

      final row = (await dbA.query('outbox',
              where: 'operation_id = ?', whereArgs: [operationId]))
          .single;
      expect(summary.totalProcessed, 1);
      expect(dao.responseTransitions, 0);
      expect(row['status'], 'PROCESSING');
      expect(row['remote_disposition'], 'AMBIGUOUS');
      expect(row['attempt_count'], 1);
      expect(row['last_attempt_at'], attemptAt);
      expect(await dbB.query('outbox'), isEmpty);
      expect(transport.recordedRequests, hasLength(1));
      await dbA.close();
      await dbB.close();
    });

    test('cancellation during a result batch rolls back earlier row updates',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_batch_rollback_a.db');
      final dbB = await _openRawSyncDatabase('e2_batch_rollback_b.db');
      const operationIds = ['e2-batch-first', 'e2-batch-second'];
      await _insertPushItem(dbA, operationId: operationIds[0], name: 'First');
      await _insertPushItem(dbA, operationId: operationIds[1], name: 'Second');
      final requestStarted = Completer<void>();
      final transport = _CapturingHttpClient((request) async {
        if (request.url.path == '/sync/push') {
          requestStarted.complete();
          return http.Response(
            jsonEncode({
              'results': [
                {'operationId': operationIds[0], 'status': 'SYNCED'},
                {'operationId': operationIds[1], 'status': 'SYNCED'},
              ]
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });
      final dao = _TrackingOutboxDao(
        afterResponseTransition: (status) {
          if (status == 'SYNCED') valid = false;
        },
      );
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: dao,
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final push = engine.pushPendingOutbox(lease: lease);
      await requestStarted.future;
      final summary = await push;
      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');

      expect(summary.syncedCount, 0);
      expect(dao.responseTransitions, 1);
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PROCESSING');
        expect(row['remote_disposition'], 'AMBIGUOUS');
        expect(row['attempt_count'], 1);
        expect(row['last_attempt_at'], isNotNull);
      }
      expect(await dbB.query('outbox'), isEmpty);
      expect(transport.recordedRequests, hasLength(1));
      await dbA.close();
      await dbB.close();
    });

    test('late result cannot overwrite a newer Outbox attempt identity',
        () async {
      final dbA = await _openRawSyncDatabase('e2_newer_attempt_a.db');
      final dbB = await _openRawSyncDatabase('e2_newer_attempt_b.db');
      const operationId = 'e2-newer-attempt';
      await _insertPushItem(dbA, operationId: operationId, name: 'Customer A');
      final requestStarted = Completer<void>();
      final responseGate = Completer<http.Response>();
      final transport = _CapturingHttpClient((request) {
        if (request.url.path == '/sync/push') {
          requestStarted.complete();
          return responseGate.future;
        }
        return Future.value(http.Response('Not Found', 404));
      });
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => false,
      );

      final push = engine.pushPendingOutbox(lease: lease);
      await requestStarted.future;
      await dbA.update(
        'outbox',
        {
          'status': 'REQUIRES_ATTENTION',
          'remote_disposition': 'AMBIGUOUS',
          'attempt_count': 9,
          'last_attempt_at': '2027-01-01T00:00:00.000Z',
          'last_error': 'newer concurrent state',
        },
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      responseGate.complete(http.Response(
        jsonEncode({
          'results': [
            {'operationId': operationId, 'status': 'SYNCED'}
          ]
        }),
        200,
      ));
      final summary = await push;
      final row = (await dbA.query('outbox',
              where: 'operation_id = ?', whereArgs: [operationId]))
          .single;

      expect(summary.syncedCount, 0);
      expect(row['status'], 'REQUIRES_ATTENTION');
      expect(row['remote_disposition'], 'AMBIGUOUS');
      expect(row['attempt_count'], 9);
      expect(row['last_attempt_at'], '2027-01-01T00:00:00.000Z');
      expect(row['last_error'], 'newer concurrent state');
      expect(await dbB.query('outbox'), isEmpty);
      expect(transport.recordedRequests, hasLength(1));
      await dbA.close();
      await dbB.close();
    });
  });

  group('E2-04: Lease Cancellation Guard before HTTP (Intercept and Claim)',
      () {
    test('cancellation during PART interception rolls back and performs 0 HTTP',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_part_cancel_a.db');
      final dbB = await _openRawSyncDatabase('e2_part_cancel_b.db');
      const op1 = 'e2-part-first';
      const op2 = 'e2-part-second';
      await _insertPushItem(dbA,
          operationId: op1, name: 'Part 1', entityType: 'PART');
      await _insertPushItem(dbA,
          operationId: op2, name: 'Part 2', entityType: 'PART');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(jsonEncode({'results': []}), 200);
      });

      final dao = _TrackingOutboxDao(
        onTransition: (operationId, toStatus) {
          if (operationId == op1) {
            valid = false;
          }
        },
      );
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: dao,
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final summary = await engine.pushPendingOutbox(lease: lease);

      expect(summary.syncedCount, 0);
      expect(summary.totalProcessed, 0);
      expect(transport.recordedRequests, isEmpty,
          reason: 'No HTTP must be issued when lease is cancelled');

      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PENDING',
            reason: 'Rollback must preserve original PENDING status');
        expect(row['remote_disposition'], 'UNSENT',
            reason: 'Rollback must preserve original UNSENT disposition');
        expect(row['attempt_count'], 0, reason: 'attempt_count must remain 0');
        expect(row['last_attempt_at'], isNull,
            reason: 'last_attempt_at must remain null');
      }

      await dbA.close();
      await dbB.close();
    });

    test(
        'cancellation during PAYMENT interception rolls back and performs 0 HTTP',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_pay_cancel_a.db');
      final dbB = await _openRawSyncDatabase('e2_pay_cancel_b.db');
      const op1 = 'e2-pay-first';
      const op2 = 'e2-pay-second';
      await _insertPushItem(dbA,
          operationId: op1, name: 'Pay 1', entityType: 'PAYMENT');
      await _insertPushItem(dbA,
          operationId: op2, name: 'Pay 2', entityType: 'PAYMENT');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(jsonEncode({'results': []}), 200);
      });

      final dao = _TrackingOutboxDao(
        onTransition: (operationId, toStatus) {
          if (operationId == op1) {
            valid = false;
          }
        },
      );
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: dao,
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final summary = await engine.pushPendingOutbox(lease: lease);

      expect(summary.syncedCount, 0);
      expect(summary.totalProcessed, 0);
      expect(transport.recordedRequests, isEmpty,
          reason: 'No HTTP must be issued when lease is cancelled');

      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PENDING',
            reason: 'Rollback must preserve original PENDING status');
        expect(row['remote_disposition'], 'UNSENT',
            reason: 'Rollback must preserve original UNSENT disposition');
        expect(row['attempt_count'], 0, reason: 'attempt_count must remain 0');
        expect(row['last_attempt_at'], isNull,
            reason: 'last_attempt_at must remain null');
      }

      await dbA.close();
      await dbB.close();
    });

    test(
        'cancellation during PRE_ACQUISITION interception rolls back and performs 0 HTTP',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_pre_cancel_a.db');
      final dbB = await _openRawSyncDatabase('e2_pre_cancel_b.db');
      const op1 = 'e2-pre-first';
      const op2 = 'e2-pre-second';
      await _insertPushItem(dbA,
          operationId: op1, name: 'Pre 1', entityType: 'PRE_ACQUISITION');
      await _insertPushItem(dbA,
          operationId: op2, name: 'Pre 2', entityType: 'PRE_ACQUISITION');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(jsonEncode({'results': []}), 200);
      });

      final dao = _TrackingOutboxDao(
        onTransition: (operationId, toStatus) {
          if (operationId == op1) {
            valid = false;
          }
        },
      );
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: dao,
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final summary = await engine.pushPendingOutbox(lease: lease);

      expect(summary.syncedCount, 0);
      expect(summary.totalProcessed, 0);
      expect(transport.recordedRequests, isEmpty,
          reason: 'No HTTP must be issued when lease is cancelled');

      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PENDING',
            reason: 'Rollback must preserve original PENDING status');
        expect(row['remote_disposition'], 'UNSENT',
            reason: 'Rollback must preserve original UNSENT disposition');
        expect(row['attempt_count'], 0, reason: 'attempt_count must remain 0');
        expect(row['last_attempt_at'], isNull,
            reason: 'last_attempt_at must remain null');
      }

      await dbA.close();
      await dbB.close();
    });

    test(
        'cancellation during claim of two operations rolls back both to PENDING/UNSENT and performs 0 HTTP',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_claim_cancel_a.db');
      final dbB = await _openRawSyncDatabase('e2_claim_cancel_b.db');
      const op1 = 'e2-claim-first';
      const op2 = 'e2-claim-second';
      await _insertPushItem(dbA, operationId: op1, name: 'First');
      await _insertPushItem(dbA, operationId: op2, name: 'Second');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(jsonEncode({'results': []}), 200);
      });

      final dao = _TrackingOutboxDao(
        onTransition: (operationId, toStatus) {
          if (operationId == op1 && toStatus == 'PROCESSING') {
            valid = false;
          }
        },
      );
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: dao,
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final summary = await engine.pushPendingOutbox(lease: lease);

      expect(summary.syncedCount, 0);
      expect(summary.totalProcessed, 0);
      expect(transport.recordedRequests, isEmpty,
          reason: 'No HTTP request must be sent when claim is cancelled');

      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PENDING',
            reason:
                'Rollback must preserve PENDING status for both operations');
        expect(row['remote_disposition'], 'UNSENT',
            reason: 'Unsent operations must NEVER be left as AMBIGUOUS');
        expect(row['attempt_count'], 0,
            reason:
                'attemptCount must remain 0 because operation was never sent');
        expect(row['last_attempt_at'], isNull,
            reason: 'lastAttemptAt must remain null');
      }

      await dbA.close();
      await dbB.close();
    });
  });

  group('E2-05: Coordinated Lease Validity and Transaction Commit', () {
    test(
        'HTTP 200: suspension immediately before commit detects invalid lease and rolls back all results',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_commit_200_a.db');
      final dbB = await _openRawSyncDatabase('e2_commit_200_b.db');
      const op1 = 'e2-c200-first';
      const op2 = 'e2-c200-second';
      await _insertPushItem(dbA, operationId: op1, name: 'First');
      await _insertPushItem(dbA, operationId: op2, name: 'Second');

      final transport = _CapturingHttpClient((request) async {
        if (request.url.path == '/sync/push') {
          return http.Response(
            jsonEncode({
              'results': [
                {'operationId': op1, 'status': 'SYNCED'},
                {'operationId': op2, 'status': 'SYNCED'},
              ]
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final processingFinished = Completer<void>();
      final resumeCommit = Completer<void>();

      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        onBeforeCommit: (stage) async {
          if (stage == 'push_http_200') {
            processingFinished.complete();
            await resumeCommit.future;
          }
        },
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final pushFuture = engine.pushPendingOutbox(lease: lease);

      await processingFinished.future;
      valid = false;
      resumeCommit.complete();

      final summary = await pushFuture;

      expect(summary.syncedCount, 0,
          reason: 'Cancelled summary must report 0 syncedCount');

      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PROCESSING',
            reason:
                'Rollback must prevent SYNCED commit; items remain in claimed state');
        expect(row['remote_disposition'], 'AMBIGUOUS',
            reason: 'Network request was sent, so items remain AMBIGUOUS');
      }

      await dbA.close();
      await dbB.close();
    });

    test(
        'HTTP non-200: suspension immediately before commit detects invalid lease and rolls back quarantine',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_commit_500_a.db');
      final dbB = await _openRawSyncDatabase('e2_commit_500_b.db');
      const op1 = 'e2-c500-first';
      const op2 = 'e2-c500-second';
      await _insertPushItem(dbA, operationId: op1, name: 'First');
      await _insertPushItem(dbA, operationId: op2, name: 'Second');

      final transport = _CapturingHttpClient((request) async {
        if (request.url.path == '/sync/push') {
          return http.Response('Server Error', 500);
        }
        return http.Response('Not Found', 404);
      });

      final processingFinished = Completer<void>();
      final resumeCommit = Completer<void>();

      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        onBeforeCommit: (stage) async {
          if (stage == 'push_http_non_200') {
            processingFinished.complete();
            await resumeCommit.future;
          }
        },
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final pushFuture = engine.pushPendingOutbox(lease: lease);

      await processingFinished.future;
      valid = false;
      resumeCommit.complete();

      final summary = await pushFuture;

      expect(summary.totalProcessed, 2);
      expect(summary.failedCount, 0);

      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PROCESSING',
            reason: 'Rollback must prevent non-200 transaction commit');
        expect(row['last_error'], isNull,
            reason: 'HTTP 500 error must not be persisted on cancelled cycle');
      }

      await dbA.close();
      await dbB.close();
    });

    test(
        'Catch recovery: suspension immediately before commit detects invalid lease and rolls back error quarantine',
        () async {
      var valid = true;
      final dbA = await _openRawSyncDatabase('e2_commit_catch_a.db');
      final dbB = await _openRawSyncDatabase('e2_commit_catch_b.db');
      const op1 = 'e2-catch-first';
      const op2 = 'e2-catch-second';
      await _insertPushItem(dbA, operationId: op1, name: 'First');
      await _insertPushItem(dbA, operationId: op2, name: 'Second');

      final transport = _CapturingHttpClient((request) async {
        if (request.url.path == '/sync/push') {
          throw http.ClientException('Simulated network drop');
        }
        return http.Response('Not Found', 404);
      });

      final processingFinished = Completer<void>();
      final resumeCommit = Completer<void>();

      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        onBeforeCommit: (stage) async {
          if (stage == 'push_catch_recovery') {
            processingFinished.complete();
            await resumeCommit.future;
          }
        },
      );
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => !valid,
      );

      final pushFuture = engine.pushPendingOutbox(lease: lease);

      await processingFinished.future;
      valid = false;
      resumeCommit.complete();

      final summary = await pushFuture;

      expect(summary.totalProcessed, 2);
      expect(summary.failedCount, 0);

      final rows = await dbA.query('outbox', orderBy: 'operation_id ASC');
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['status'], 'PROCESSING',
            reason: 'Rollback must prevent catch recovery transaction commit');
        expect(row['last_error'], isNull,
            reason:
                'Network drop error must not be persisted on cancelled cycle');
      }

      await dbA.close();
      await dbB.close();
    });
  });

  group(
      'Session-Bound Sync Lease & Cross-Scope Race Condition Security Tests (FE-01B)',
      () {
    const scopeA =
        ProfessionalAuthScope(userId: 'user_a', organizationId: 'org_a');
    const scopeB =
        ProfessionalAuthScope(userId: 'user_b', organizationId: 'org_b');

    test(
        'DETERMINISTIC SECURITY RACE: Stale Sync A never uses token B, never mutates DB B, and does not leak state',
        () async {
      // Step A: Establish Scope A and DB A
      final handleA = await openScopedDatabase(scopeA);
      final dbA = handleA.database;

      // Step B: Establish token A in Hive
      final authBox = await Hive.openBox('auth_box');
      await authBox.put('jwt_token', 'TOKEN_A_SECRET');

      // Step C: Place pending operation in DB A
      final outboxDao = OutboxDao();
      final itemA = OutboxItem(
        operationId: 'op_a_001',
        entityType: 'CUSTOMER',
        entityId: 'c_001',
        operationType: 'CREATE',
        payload: {'name': 'Client A'},
        createdAt: DateTime.now().toIso8601String(),
      );
      await outboxDao.insert(itemA, executor: dbA);

      // Step D & E: Deterministic barrier for HTTP request #1
      final request1Started = Completer<void>();
      final request1Unblock = Completer<http.Response>();

      final transport = _CapturingHttpClient((request) {
        if (request.url.path == '/sync/push') {
          if (!request1Started.isCompleted) {
            request1Started.complete();
          }
          return request1Unblock.future;
        }
        return Future.value(
            http.Response('{"nextCursor":null,"changes":[]}', 200));
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient, outboxDao: outboxDao);

      final coordinatorA = BackgroundSyncCoordinator(
        syncEngine: syncEngine,
        outboxDao: outboxDao,
        sessionBinding: _sessionBinding(
          handle: handleA,
          resolveToken: () async => 'TOKEN_A_SECRET',
        ),
      );

      // Trigger Sync A
      final syncAFuture = coordinatorA.requestSync(SyncTrigger.manual);

      // Wait deterministically until HTTP Request #1 reaches the network layer
      await request1Started.future;

      // Assertion 1: Request #1 strictly carried token A
      expect(transport.recordedRequests.length, 1);
      expect(transport.recordedRequests.first.headers['authorization'],
          'Bearer TOKEN_A_SECRET');

      // Step F: Invalidate/cancel Scope A lifecycle
      coordinatorA.cancelActiveSync();
      coordinatorA.dispose();

      // Step G: Close DB A
      await closeScopedDatabase();

      // Step H: Establish Scope B and DB B
      final handleB = await openScopedDatabase(scopeB);
      final dbB = handleB.database;

      // Step I: Replace current credential with token B
      await authBox.put('jwt_token', 'TOKEN_B_SECRET');

      // Step J: Unblock HTTP Request #1 response from stale Sync A
      request1Unblock.complete(http.Response(
        jsonEncode({
          'results': [
            {'operationId': 'op_a_001', 'status': 'SYNCED'}
          ]
        }),
        200,
      ));

      // Step K: Await stale Sync A completion
      await syncAFuture;

      // Mandatory Security Assertions:
      // 1. Request #1 used token A
      expect(transport.recordedRequests[0].headers['authorization'],
          'Bearer TOKEN_A_SECRET');

      // 2. No subsequent stale-A request used token B
      for (final req in transport.recordedRequests) {
        expect(req.headers['authorization'], isNot('Bearer TOKEN_B_SECRET'),
            reason:
                'Stale Sync A must never emit any HTTP request with token B');
      }

      // 3. No subsequent stale-A request was emitted at all (total requests emitted by stale A is exactly 1)
      expect(transport.recordedRequests.length, 1,
          reason:
              'Stale Sync A must immediately abort upon cancellation; pull phase must not start');

      // 4. DB B outbox is completely untouched
      final dbBPending = await outboxDao.getPendingEntries(executor: dbB);
      expect(dbBPending, isEmpty,
          reason: 'DB B outbox must not be modified by stale Sync A');

      // 5. DB B sync cursor is completely untouched
      final cursorB = await syncEngine.getLocalCursor(executor: dbB);
      expect(cursorB, '0',
          reason:
              'DB B must remain at its own bootstrap boundary after stale Sync A');

      // 6. Stale A result did not publish into Coordinator B
      final coordinatorB = BackgroundSyncCoordinator(
        syncEngine: syncEngine,
        outboxDao: outboxDao,
        sessionBinding: _sessionBinding(
          handle: handleB,
          resolveToken: () async => 'TOKEN_B_SECRET',
        ),
      );
      expect(coordinatorB.state.status, SyncStatus.idle);
      expect(coordinatorB.state.lastError, isNull);

      // 7. Scope B can subsequently execute its own normal Sync using token B
      await coordinatorB.requestSync(SyncTrigger.manual);
      // Wait for any microtasks
      await Future.delayed(const Duration(milliseconds: 20));

      expect(transport.recordedRequests.length, greaterThan(1));
      final requestFromB = transport.recordedRequests.last;
      expect(requestFromB.headers['authorization'], 'Bearer TOKEN_B_SECRET',
          reason: 'Scope B must legitimately use token B');

      // 8. Fail-closed database behavior: closing scope prevents activeDatabase access
      await closeScopedDatabase();
      expect(() => SqliteDatabase.instance, throwsA(isA<StateError>()));
    });

    test(
        'CANCELLATION LEASE: Multi-page pull immediately halts before page 2 when cancelled',
        () async {
      final dbA = (await openScopedDatabase(scopeA)).database;
      int pullPageCount = 0;

      final transport = _CapturingHttpClient((request) async {
        pullPageCount++;
        if (pullPageCount == 1) {
          return http.Response(
            jsonEncode({
              'nextCursor': '2',
              'changes': [
                {
                  'entityType': 'CUSTOMER',
                  'entityId': 'c_1',
                  'operationType': 'CREATE',
                  'data': {
                    'id': 'c_1',
                    'name': 'Client Page 1',
                    'updatedAt': '2026-01-01T00:00:00.000Z',
                  },
                }
              ],
            }),
            200,
          );
        } else {
          // Page 2 should never be reached if cancelled
          return http.Response(
              jsonEncode({'nextCursor': '3', 'changes': []}), 200);
        }
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);

      var cancelled = false;
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => cancelled,
      );
      syncEngine.onAfterPullPageCommit = () async => cancelled = true;

      final summary = await syncEngine.pullIncrementalChanges(lease: lease);

      // Page 1 was processed and committed, but Page 2 was never requested
      expect(pullPageCount, 1,
          reason:
              'Pull must halt between pages immediately when lease is cancelled');
      expect(transport.recordedRequests.length, 1);
      expect(summary.totalChanges, 1);

      // Verify page 1 data was committed to dbA
      final customers =
          await dbA.query('customers', where: 'id = ?', whereArgs: ['c_1']);
      expect(customers.length, 1);
      expect(customers.first['name'], 'Client Page 1');
    });

    test(
        'CANCELLATION LEASE: Cancelling between push and pull prevents pull phase from starting',
        () async {
      final handleA = await openScopedDatabase(scopeA);
      final dbA = handleA.database;
      final outboxDao = OutboxDao();

      // Insert pending entry so push phase runs an HTTP call
      await outboxDao.insert(
        OutboxItem(
          operationId: 'op_push_test',
          entityType: 'CUSTOMER',
          entityId: 'c_push',
          operationType: 'CREATE',
          payload: {'name': 'Push Test'},
          createdAt: DateTime.now().toIso8601String(),
        ),
        executor: dbA,
      );

      final pushStarted = Completer<void>();
      final pushUnblock = Completer<http.Response>();

      final transport = _CapturingHttpClient((request) {
        if (request.url.path == '/sync/push') {
          if (!pushStarted.isCompleted) {
            pushStarted.complete();
          }
          return pushUnblock.future;
        }
        return Future.value(http.Response(
            jsonEncode({'nextCursor': null, 'changes': []}), 200));
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient, outboxDao: outboxDao);

      final coordinator = BackgroundSyncCoordinator(
        syncEngine: syncEngine,
        outboxDao: outboxDao,
        sessionBinding: _sessionBinding(
          handle: handleA,
          resolveToken: () async => 'TOKEN_A',
        ),
      );

      // Start sync
      final syncFuture = coordinator.requestSync(SyncTrigger.manual);

      // Wait until push reaches network layer deterministically
      await pushStarted.future;

      // Cancel coordinator while push is in flight
      coordinator.cancelActiveSync();

      // Unblock push response
      pushUnblock.complete(http.Response(
        jsonEncode({
          'results': [
            {'operationId': 'op_push_test', 'status': 'SYNCED'}
          ]
        }),
        200,
      ));

      await syncFuture;

      // Only push was requested, pull was never dispatched
      expect(transport.recordedRequests.length, 1);
      expect(transport.recordedRequests.first.url.path, '/sync/push');
    });

    test(
        'EXPLICIT DB BINDING: SyncEngine with lease never falls back to SqliteDatabase.instance',
        () async {
      // Open dbA and dbB directly to test cross-database isolation
      final dbA = await SqliteDatabase.openDatabaseByName('db_a_explicit.db');
      await _activateSyncV2(dbA);
      final dbB = (await openScopedDatabase(scopeB)).database;

      final transport = _CapturingHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'nextCursor': null,
            'changes': [
              {
                'entityType': 'CUSTOMER',
                'entityId': 'c_bound',
                'operationType': 'CREATE',
                'data': {
                  'id': 'c_bound',
                  'name': 'Bound Client',
                  'updatedAt': '2026-01-01T00:00:00.000Z',
                },
              }
            ],
          }),
          200,
        );
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);

      // Create lease bound to DBA
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => false,
      );

      // Run pullIncrementalChanges with the lease bound to dbA while scopeB / dbB is active
      await syncEngine.pullIncrementalChanges(lease: lease);

      // Verify records were inserted into dbA, NOT dbB
      final resA =
          await dbA.query('customers', where: 'id = ?', whereArgs: ['c_bound']);
      expect(resA, isNotEmpty, reason: 'Record must be written to bound dbA');

      final resB =
          await dbB.query('customers', where: 'id = ?', whereArgs: ['c_bound']);
      expect(resB, isEmpty, reason: 'Record must NEVER be written to dbB');

      await dbA.close();
    });

    test(
        'CREDENTIAL PINNING: SyncLease pins auth token regardless of subsequent Hive changes',
        () async {
      final dbA = (await openScopedDatabase(scopeA)).database;

      final authBox = await Hive.openBox('auth_box');
      await authBox.put('jwt_token', 'INITIAL_TOKEN');

      late String observedHeader;
      final transport = _CapturingHttpClient((request) async {
        observedHeader = request.headers['authorization'] ?? '';
        return http.Response(
            jsonEncode({'nextCursor': null, 'changes': []}), 200);
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);

      // Capture lease with pinned token
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('PINNED_SESSION_TOKEN'),
        isCancelled: () => false,
      );

      // Modify Hive token to something else
      await authBox.put('jwt_token', 'CHANGED_HIVE_TOKEN');

      // Execute pullIncrementalChanges with the lease
      await syncEngine.pullIncrementalChanges(lease: lease);

      expect(observedHeader, 'Bearer PINNED_SESSION_TOKEN');
      expect(observedHeader, isNot('Bearer CHANGED_HIVE_TOKEN'));
    });

    test(
        'NORMAL OPERATION: Same-session multi-page pull succeeds completely when valid',
        () async {
      final dbA = (await openScopedDatabase(scopeA)).database;

      int pagesRequested = 0;
      final transport = _CapturingHttpClient((request) async {
        pagesRequested++;
        if (pagesRequested == 1) {
          return http.Response(
            jsonEncode({
              'nextCursor': '2',
              'changes': [
                {
                  'entityType': 'CUSTOMER',
                  'entityId': 'cust_1',
                  'operationType': 'CREATE',
                  'data': {
                    'id': 'cust_1',
                    'name': 'Customer 1',
                    'updatedAt': '2026-01-01T00:00:00.000Z',
                  },
                }
              ],
            }),
            200,
          );
        } else if (pagesRequested == 2) {
          return http.Response(
            jsonEncode({
              'nextCursor': '3',
              'changes': [
                {
                  'entityType': 'CUSTOMER',
                  'entityId': 'cust_2',
                  'operationType': 'CREATE',
                  'data': {
                    'id': 'cust_2',
                    'name': 'Customer 2',
                    'updatedAt': '2026-01-01T00:00:01.000Z',
                  },
                }
              ],
            }),
            200,
          );
        } else {
          // Cursor stabilized: no more changes
          return http.Response(
            jsonEncode({
              'nextCursor': '3',
              'changes': [],
            }),
            200,
          );
        }
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);

      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('VALID_TOKEN'),
        isCancelled: () => false,
      );

      final summary = await syncEngine.pullIncrementalChanges(lease: lease);

      expect(pagesRequested, 3);
      expect(summary.totalChanges, 2);
      expect(summary.nextCursor, '3');

      // Verify records are persisted in dbA
      final records = await dbA.query('customers', orderBy: 'id ASC');
      expect(records.length, 2);
      expect(records[0]['name'], 'Customer 1');
      expect(records[1]['name'], 'Customer 2');
    });

    // =========================================================
    // NULL CREDENTIAL SEMANTICS — FE-01B SECURITY HARDENING
    // =========================================================

    test(
        'NULL TOKEN SEMANTICS: SyncLease with explicit null token never issues any HTTP request',
        () async {
      final dbA = (await openScopedDatabase(scopeA)).database;

      // Hive contains a valid token that must NEVER be used by a leased cycle.
      final authBox = await Hive.openBox('auth_box');
      await authBox.put('jwt_token', 'TOKEN_B_HIVE_POISON');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(
            jsonEncode({'nextCursor': null, 'changes': []}), 200);
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);

      // Explicit null credential: the session had no valid token.
      // Must fail closed — zero HTTP requests.
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit(null),
        isCancelled: () => false,
      );

      await syncEngine.pushPendingOutbox(lease: lease);
      await syncEngine.pullIncrementalChanges(lease: lease);

      expect(
        transport.recordedRequests,
        isEmpty,
        reason:
            'Explicit null credential must prevent ALL HTTP requests; Hive token must not be used',
      );
    });

    test(
        'TOKEN RESOLVER FAILURE FAILS CLOSED: throws stops cycle before any HTTP',
        () async {
      final handleA = await openScopedDatabase(scopeA);

      // Hive contains a valid unrelated token — must never be used.
      final authBox = await Hive.openBox('auth_box');
      await authBox.put('jwt_token', 'UNRELATED_HIVE_TOKEN');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(
            jsonEncode({'nextCursor': null, 'changes': []}), 200);
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);
      final outboxDao = OutboxDao();

      // tokenResolver throws — coordinator must stop the cycle before any HTTP.
      final coordinator = BackgroundSyncCoordinator(
        syncEngine: syncEngine,
        outboxDao: outboxDao,
        sessionBinding: _sessionBinding(
          handle: handleA,
          resolveToken: () async =>
              throw Exception('credential store unavailable'),
        ),
      );

      await coordinator.requestSync(SyncTrigger.manual);
      // Allow microtasks to settle
      await Future.delayed(const Duration(milliseconds: 20));

      expect(
        transport.recordedRequests,
        isEmpty,
        reason:
            'tokenResolver throw must stop the cycle; unrelated Hive token must never be used',
      );

      coordinator.dispose();
    });

    test(
        'EMPTY TOKEN FAILS CLOSED: tokenResolver returns empty string stops cycle before any HTTP',
        () async {
      final handleA = await openScopedDatabase(scopeA);

      // Hive contains a valid token — must never be used.
      final authBox = await Hive.openBox('auth_box');
      await authBox.put('jwt_token', 'EXISTING_HIVE_TOKEN');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(
            jsonEncode({'nextCursor': null, 'changes': []}), 200);
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);
      final outboxDao = OutboxDao();

      // tokenResolver returns '' — coordinator must treat this as fail-closed.
      final coordinator = BackgroundSyncCoordinator(
        syncEngine: syncEngine,
        outboxDao: outboxDao,
        sessionBinding: _sessionBinding(
          handle: handleA,
          resolveToken: () async => '',
        ),
      );

      await coordinator.requestSync(SyncTrigger.manual);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(
        transport.recordedRequests,
        isEmpty,
        reason:
            'Empty credential must stop the sync cycle; existing Hive token must never be used',
      );

      coordinator.dispose();
    });

    test(
        'CREDENTIAL PINNING REGRESSION: lease tokenA remains pinned when Hive changes to tokenB',
        () async {
      final dbA = (await openScopedDatabase(scopeA)).database;

      final authBox = await Hive.openBox('auth_box');
      await authBox.put('jwt_token', 'INITIAL_TOKEN_REG');

      late String observedHeader;
      final transport = _CapturingHttpClient((request) async {
        observedHeader = request.headers['authorization'] ?? '';
        return http.Response(
            jsonEncode({'nextCursor': null, 'changes': []}), 200);
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);

      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('PINNED_TOKEN_REG'),
        isCancelled: () => false,
      );

      // Change Hive token after lease creation
      await authBox.put('jwt_token', 'CHANGED_HIVE_TOKEN_REG');

      await syncEngine.pullIncrementalChanges(lease: lease);

      expect(observedHeader, 'Bearer PINNED_TOKEN_REG',
          reason:
              'Lease credential must be pinned; Hive change must have no effect');
      expect(observedHeader, isNot('Bearer CHANGED_HIVE_TOKEN_REG'));
    });

    test('BoundCredential: whitespace token is invalid', () {
      expect(BoundCredential.explicit('   ').hasValidToken, isFalse);
      expect(BoundCredential.explicit(' \t\n ').hasValidToken, isFalse);
      expect(BoundCredential.explicit('').hasValidToken, isFalse);
      expect(BoundCredential.explicit(null).hasValidToken, isFalse);
      expect(BoundCredential.explicit('valid_token').hasValidToken, isTrue);
      expect(BoundCredential.absent.hasValidToken, isFalse);
    });

    test(
        'WHITESPACE TOKEN FAILS CLOSED: tokenResolver returns whitespace string stops cycle before any HTTP',
        () async {
      final handleA = await openScopedDatabase(scopeA);

      // Hive contains unrelated valid tokenB — must never be used.
      final authBox = await Hive.openBox('auth_box');
      await authBox.put('jwt_token', 'UNRELATED_VALID_TOKEN_B');

      final transport = _CapturingHttpClient((request) async {
        return http.Response(
            jsonEncode({'nextCursor': null, 'changes': []}), 200);
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);
      final outboxDao = OutboxDao();

      // tokenResolver returns '   ' — coordinator must treat this as fail-closed.
      final coordinator = BackgroundSyncCoordinator(
        syncEngine: syncEngine,
        outboxDao: outboxDao,
        sessionBinding: _sessionBinding(
          handle: handleA,
          resolveToken: () async => '   ',
        ),
      );

      await coordinator.requestSync(SyncTrigger.manual);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(
        transport.recordedRequests,
        isEmpty,
        reason:
            'Whitespace credential must stop the sync cycle; unrelated Hive token must never be used',
      );

      coordinator.dispose();
    });

    // =========================================================
    // INVARIANT: VALIDATE CREDENTIAL BEFORE OUTBOX MUTATION
    // =========================================================
    for (final invalidToken in [null, '', '   ']) {
      final tokenDesc = invalidToken == null
          ? 'null'
          : (invalidToken.isEmpty ? 'empty' : 'whitespace-only');

      test(
          'INVALID CREDENTIAL OUTBOX MUTATION ($tokenDesc): entries remain PENDING, 0 HTTP, no Hive fallback',
          () async {
        final dbA = (await openScopedDatabase(scopeA)).database;

        await dbA.delete('outbox');

        final outboxDao = OutboxDao();
        final opId = 'op-invalid-$tokenDesc';
        final item = OutboxItem(
          operationId: opId,
          entityType: 'CUSTOMER',
          entityId: 'cust-1',
          operationType: 'CREATE',
          payload: {'name': 'Pending Customer'},
          createdAt: DateTime.now().toIso8601String(),
          attemptCount: 0,
          status: 'PENDING',
        );
        await outboxDao.insert(item, executor: dbA);

        // Hive contains TOKEN_B — must NEVER be used
        final authBox = await Hive.openBox('auth_box');
        await authBox.put('jwt_token', 'TOKEN_B_POISON');

        final transport = _CapturingHttpClient((request) async {
          return http.Response(
              jsonEncode({
                'results': [
                  {'operationId': opId, 'status': 'SYNCED'}
                ]
              }),
              200);
        });

        final apiClient =
            ApiClient(baseUrl: 'http://fake.api', client: transport);
        final syncEngine =
            SyncEngine(apiClient: apiClient, outboxDao: outboxDao);

        final lease = SyncLease(
          db: dbA,
          credential: BoundCredential.explicit(invalidToken),
          isCancelled: () => false,
        );

        final summary = await syncEngine.pushPendingOutbox(lease: lease);

        // 1. ZERO HTTP requests issued
        expect(transport.recordedRequests, isEmpty,
            reason:
                'Invalid credential must fail closed before HTTP; zero requests');

        // 2. Summary indicates 0 processed
        expect(summary.totalProcessed, 0);
        expect(summary.syncedCount, 0);

        // 3. Outbox item remains PENDING, attemptCount unchanged (0), lastAttemptAt is null
        final rows = await dbA.query(
          'outbox',
          where: 'operation_id = ?',
          whereArgs: [opId],
        );
        expect(rows.length, 1);
        expect(rows.first['status'], 'PENDING',
            reason:
                'Outbox item must not be transitioned to PROCESSING when credential is invalid');
        expect(rows.first['attempt_count'], 0,
            reason: 'attemptCount must remain unchanged');
        expect(rows.first['last_attempt_at'], isNull,
            reason: 'last_attempt_at must not be mutated');
      });
    }
  });

  group(
      'Etapa 2 — Testes Específicos de Concorrência e Cancelamento (Categorias A a H)',
      () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute('''
        CREATE TABLE outbox (
          operation_id TEXT PRIMARY KEY,
          device_id TEXT,
          user_id TEXT,
          entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          operation_type TEXT NOT NULL,
          payload TEXT NOT NULL,
          created_at TEXT NOT NULL,
          attempt_count INTEGER NOT NULL DEFAULT 0,
          last_attempt_at TEXT,
          next_retry_at TEXT,
          last_error TEXT,
          remote_disposition TEXT NOT NULL DEFAULT 'UNSENT',
          status TEXT NOT NULL,
          claim_id TEXT
        )
      ''');
      await db.execute('''
        CREATE TABLE customers (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE sync_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      await db.insert(
          'sync_metadata', {'key': 'sync_contract_version', 'value': '2'});
      await db.insert('sync_metadata',
          {'key': 'sync_bootstrap_proof', 'value': 'proof-123'});
      await db.insert('sync_metadata', {'key': 'last_cursor', 'value': '10'});
    });

    tearDown(() async {
      await db.close();
    });

    test('E2-T01: Reversão integral via Unclaim CAS restaura snapshot completo',
        () async {
      final outboxDao = OutboxDao();
      final item = OutboxItem(
        operationId: 'op-unclaim-1',
        entityType: 'CUSTOMER',
        entityId: 'c-1',
        operationType: 'CREATE',
        payload: {'name': 'Client 1'},
        createdAt: '2026-01-01T00:00:00.000Z',
        attemptCount: 0,
        lastAttemptAt: null,
        nextRetryAt: '2026-01-01T01:00:00.000Z',
        lastError: 'PREVIOUS_ERROR',
        status: 'PENDING',
        remoteDisposition: RemoteDisposition.unsent,
      );
      await outboxDao.insert(item, executor: db);

      var transportInvoked = false;
      final transport = _CapturingHttpClient((req) async {
        transportInvoked = true;
        return http.Response('{"contractVersion":2,"results":[]}', 200);
      });

      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: outboxDao,
      );

      var cancelRequested = false;
      final lease = SyncLease(
        db: db,
        credential: BoundCredential.explicit('TOKEN_1'),
        isCancelled: () => cancelRequested,
      );

      engine.onAfterClaimCommit = () async {
        cancelRequested = true;
        lease.barrier.requestCancellation();
      };

      final summary = await engine.pushPendingOutbox(lease: lease);

      expect(summary.syncedCount, 0);
      expect(transportInvoked, isFalse,
          reason: 'Transport must never be invoked');

      final row = (await db.query('outbox',
              where: 'operation_id = ?', whereArgs: ['op-unclaim-1']))
          .first;
      expect(row['status'], 'PENDING');
      expect(row['remote_disposition'], 'UNSENT');
      expect(row['attempt_count'], 0);
      expect(row['last_attempt_at'], isNull);
      expect(row['next_retry_at'], '2026-01-01T01:00:00.000Z');
      expect(row['last_error'], 'PREVIOUS_ERROR');
      expect(row['claim_id'], isNull);
    });

    test('E2-T02: Requisição despachada em voo nunca sofre Unclaim', () async {
      final outboxDao = OutboxDao();
      final item = OutboxItem(
        operationId: 'op-inflight-1',
        entityType: 'CUSTOMER',
        entityId: 'c-2',
        operationType: 'CREATE',
        payload: {'name': 'Client 2'},
        createdAt: '2026-01-01T00:00:00.000Z',
        attemptCount: 0,
        lastAttemptAt: null,
        status: 'PENDING',
        remoteDisposition: RemoteDisposition.unsent,
      );
      await outboxDao.insert(item, executor: db);

      var cancelRequested = false;
      final transportStarted = Completer<void>();
      final transportResume = Completer<http.Response>();

      final transport = _CapturingHttpClient((req) async {
        transportStarted.complete();
        return await transportResume.future;
      });

      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://fake.api', client: transport),
        outboxDao: outboxDao,
      );

      final lease = SyncLease(
        db: db,
        credential: BoundCredential.explicit('TOKEN_1'),
        isCancelled: () => cancelRequested,
      );

      final future = engine.pushPendingOutbox(lease: lease);
      await transportStarted.future;

      // Now client.send has already been invoked. Request cancellation!
      cancelRequested = true;
      lease.barrier.requestCancellation();

      transportResume.complete(http.Response(
          '{"contractVersion":2,"results":[{"operationId":"op-inflight-1","status":"SYNCED"}]}',
          200));
      await future;

      final row = (await db.query('outbox',
              where: 'operation_id = ?', whereArgs: ['op-inflight-1']))
          .first;
      expect(row['status'], 'PROCESSING',
          reason:
              'Must remain in PROCESSING/AMBIGUOUS because lease was cancelled');
      expect(row['remote_disposition'], 'AMBIGUOUS');
      expect(row['attempt_count'], 1);
      expect(row['last_attempt_at'], isNotNull);
      expect(row['claim_id'], isNotNull);
      expect(
        row['claim_id'],
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        )),
      );
      expect(
        DateTime.tryParse(row['last_attempt_at'] as String),
        isNotNull,
      );
    });

    test('E2-T02a: cancelamento durante preparação de headers faz Unclaim',
        () async {
      final outboxDao = OutboxDao();
      await outboxDao.insert(
        OutboxItem(
          operationId: 'op-header-cancel',
          entityType: 'CUSTOMER',
          entityId: 'c-header',
          operationType: 'CREATE',
          payload: {'name': 'Header cancel'},
          createdAt: '2026-01-01T00:00:00.000Z',
          status: 'PENDING',
          remoteDisposition: RemoteDisposition.unsent,
        ),
        executor: db,
      );

      var cancelRequested = false;
      var transportInvoked = false;
      late final SyncLease lease;
      final transport = _CapturingHttpClient((request) async {
        transportInvoked = true;
        return http.Response('unexpected', 500);
      });
      final api = ApiClient(
        baseUrl: 'http://fake.api',
        client: transport,
        beforeDispatch: () async {
          cancelRequested = true;
          lease.barrier.requestCancellation();
        },
      );
      lease = SyncLease(
        db: db,
        credential: BoundCredential.explicit('TOKEN_HEADERS'),
        isCancelled: () => cancelRequested,
      );

      await SyncEngine(apiClient: api, outboxDao: outboxDao)
          .pushPendingOutbox(lease: lease);

      final row = (await db.query('outbox',
              where: 'operation_id = ?', whereArgs: ['op-header-cancel']))
          .single;
      expect(transportInvoked, isFalse);
      expect(row['status'], 'PENDING');
      expect(row['remote_disposition'], 'UNSENT');
      expect(row['attempt_count'], 0);
      expect(row['last_attempt_at'], isNull);
      expect(row['claim_id'], isNull);
      expect(lease.barrier.isCancelled, isTrue);
    });

    test('E2-T03: Drenagem aguarda transação e requisições HTTP em andamento',
        () async {
      final barrier = LeaseCommitBarrier();
      final txStarted = Completer<void>();
      final txResume = Completer<void>();

      expect(barrier.state, BarrierState.active);

      final txFuture = barrier.runWorkTransaction(
        db: db,
        stage: 'test_stage',
        action: (txn) async {
          txStarted.complete();
          await txResume.future;
        },
      );

      await txStarted.future;
      barrier.requestCancellation();

      expect(barrier.isDraining, isTrue);
      expect(barrier.isCancelled, isFalse);

      var effectiveFired = false;
      unawaited(barrier.whenEffective.then((_) => effectiveFired = true));

      expect(effectiveFired, isFalse);

      txResume.complete();
      expect(txFuture, throwsA(isA<SyncLeaseInvalidatedException>()));
      try {
        await txFuture;
      } catch (_) {}

      await barrier.whenEffective;
      expect(barrier.isCancelled, isTrue);
      expect(effectiveFired, isTrue);
    });

    test(
        'E2-T04: Isolamento absoluto e proteção de claim_id contra respostas tardias de ciclos anteriores',
        () async {
      final outboxDao = OutboxDao();
      final item = OutboxItem(
        operationId: 'op-stale-1',
        entityType: 'CUSTOMER',
        entityId: 'c-3',
        operationType: 'CREATE',
        payload: {'name': 'Client 3'},
        createdAt: '2026-01-01T00:00:00.000Z',
        attemptCount: 1,
        lastAttemptAt: '2026-01-01T10:00:00.000Z',
        status: 'PROCESSING',
        remoteDisposition: RemoteDisposition.ambiguous,
        claimId: 'claim-token-NEW',
      );
      await outboxDao.insert(item, executor: db);

      // Attempt to confirm with OLD claim_id
      final successOld = await outboxDao.transition(
        operationId: 'op-stale-1',
        fromStatus: 'PROCESSING',
        fromDisposition: RemoteDisposition.ambiguous,
        toStatus: 'SYNCED',
        toDisposition: RemoteDisposition.confirmed,
        expectedAttemptCount: 1,
        expectedLastAttemptAt: '2026-01-01T10:00:00.000Z',
        expectedClaimId: 'claim-token-OLD',
        executor: db,
      );

      expect(successOld, isFalse,
          reason: 'Transition with stale claim_id must fail compare-and-set');

      final row = (await db.query('outbox',
              where: 'operation_id = ?', whereArgs: ['op-stale-1']))
          .first;
      expect(row['status'], 'PROCESSING');
      expect(row['remote_disposition'], 'AMBIGUOUS');
      expect(row['claim_id'], 'claim-token-NEW');
    });

    test(
        'E2-08-R1: both Unclaim destinations reject missing and null claim IDs',
        () async {
      final outboxDao = OutboxDao();
      for (final destination in ['PENDING', 'FAILED_TRANSIENT']) {
        for (final explicitNull in [false, true]) {
          final operationId = 'unclaim-missing-$destination-$explicitNull';
          await outboxDao.insert(
            OutboxItem(
              operationId: operationId,
              entityType: 'CUSTOMER',
              entityId: operationId,
              operationType: 'CREATE',
              payload: {'name': operationId},
              createdAt: '2026-01-01T00:00:00.000Z',
              attemptCount: 4,
              lastAttemptAt: '2026-01-01T01:00:00.000Z',
              status: 'PROCESSING',
              remoteDisposition: RemoteDisposition.ambiguous,
              claimId: 'claim-current-$operationId',
            ),
            executor: db,
          );
          final before = (await db.query(
            'outbox',
            where: 'operation_id = ?',
            whereArgs: [operationId],
          ))
              .single;

          final arguments = {
            'operationId': operationId,
            'fromStatus': 'PROCESSING',
            'fromDisposition': RemoteDisposition.ambiguous,
            'toStatus': destination,
            'toDisposition': RemoteDisposition.unsent,
            'attemptCount': 0,
            'clearLastAttemptAt': true,
            'clearNextRetryAt': true,
            'clearLastError': true,
            'clearClaimId': true,
            'executor': db,
          };
          Future<bool> unclaim() => explicitNull
              ? outboxDao.transition(
                  operationId: arguments['operationId'] as String,
                  fromStatus: arguments['fromStatus'] as String,
                  fromDisposition:
                      arguments['fromDisposition'] as RemoteDisposition,
                  toStatus: arguments['toStatus'] as String,
                  toDisposition:
                      arguments['toDisposition'] as RemoteDisposition,
                  attemptCount: arguments['attemptCount'] as int,
                  clearLastAttemptAt: arguments['clearLastAttemptAt'] as bool,
                  clearNextRetryAt: arguments['clearNextRetryAt'] as bool,
                  clearLastError: arguments['clearLastError'] as bool,
                  clearClaimId: arguments['clearClaimId'] as bool,
                  expectedClaimId: null,
                  executor: arguments['executor'] as DatabaseExecutor,
                )
              : outboxDao.transition(
                  operationId: arguments['operationId'] as String,
                  fromStatus: arguments['fromStatus'] as String,
                  fromDisposition:
                      arguments['fromDisposition'] as RemoteDisposition,
                  toStatus: arguments['toStatus'] as String,
                  toDisposition:
                      arguments['toDisposition'] as RemoteDisposition,
                  attemptCount: arguments['attemptCount'] as int,
                  clearLastAttemptAt: arguments['clearLastAttemptAt'] as bool,
                  clearNextRetryAt: arguments['clearNextRetryAt'] as bool,
                  clearLastError: arguments['clearLastError'] as bool,
                  clearClaimId: arguments['clearClaimId'] as bool,
                  executor: arguments['executor'] as DatabaseExecutor,
                );

          await expectLater(
            unclaim(),
            throwsA(isA<OutboxTransitionException>()),
          );
          expect(
            (await db.query(
              'outbox',
              where: 'operation_id = ?',
              whereArgs: [operationId],
            ))
                .single,
            before,
          );
        }
      }
    });

    test('E2-08-R1: stale Unclaim cannot revert a newer claim', () async {
      final outboxDao = OutboxDao();
      for (final destination in ['PENDING', 'FAILED_TRANSIENT']) {
        final operationId = 'unclaim-stale-$destination';
        await outboxDao.insert(
          OutboxItem(
            operationId: operationId,
            entityType: 'CUSTOMER',
            entityId: operationId,
            operationType: 'CREATE',
            payload: {'name': operationId},
            createdAt: '2026-01-01T00:00:00.000Z',
            attemptCount: 9,
            lastAttemptAt: '2026-01-02T01:00:00.000Z',
            nextRetryAt: '2026-01-03T01:00:00.000Z',
            lastError: 'new claim history',
            status: 'PROCESSING',
            remoteDisposition: RemoteDisposition.ambiguous,
            claimId: 'claim-new-$operationId',
          ),
          executor: db,
        );
        final before = (await db.query(
          'outbox',
          where: 'operation_id = ?',
          whereArgs: [operationId],
        ))
            .single;

        final changed = await outboxDao.transition(
          operationId: operationId,
          fromStatus: 'PROCESSING',
          fromDisposition: RemoteDisposition.ambiguous,
          toStatus: destination,
          toDisposition: RemoteDisposition.unsent,
          attemptCount: 0,
          clearLastAttemptAt: true,
          clearNextRetryAt: true,
          clearLastError: true,
          clearClaimId: true,
          expectedClaimId: 'claim-old-$operationId',
          executor: db,
        );

        expect(changed, isFalse);
        expect(
          (await db.query(
            'outbox',
            where: 'operation_id = ?',
            whereArgs: [operationId],
          ))
              .single,
          before,
        );
      }
    });

    test(
        'E2-08-R1: current claim restores both snapshots including null fields',
        () async {
      final outboxDao = OutboxDao();
      final snapshots = <({
        String status,
        int attemptCount,
        String? lastAttemptAt,
        String? nextRetryAt,
        String? lastError,
      })>[
        (
          status: 'PENDING',
          attemptCount: 0,
          lastAttemptAt: null,
          nextRetryAt: null,
          lastError: null,
        ),
        (
          status: 'FAILED_TRANSIENT',
          attemptCount: 3,
          lastAttemptAt: '2026-01-01T01:00:00.000Z',
          nextRetryAt: '2026-01-01T02:00:00.000Z',
          lastError: 'prior retry error',
        ),
      ];

      for (final snapshot in snapshots) {
        final operationId = 'unclaim-current-${snapshot.status}';
        final claimId = 'claim-current-$operationId';
        final payload = {'name': operationId};
        await outboxDao.insert(
          OutboxItem(
            operationId: operationId,
            entityType: 'CUSTOMER',
            entityId: operationId,
            operationType: 'CREATE',
            payload: payload,
            createdAt: '2026-01-01T00:00:00.000Z',
            attemptCount: snapshot.attemptCount + 1,
            lastAttemptAt: '2026-01-04T01:00:00.000Z',
            nextRetryAt: snapshot.nextRetryAt,
            lastError: snapshot.lastError,
            status: 'PROCESSING',
            remoteDisposition: RemoteDisposition.ambiguous,
            claimId: claimId,
          ),
          executor: db,
        );

        final changed = await outboxDao.transition(
          operationId: operationId,
          fromStatus: 'PROCESSING',
          fromDisposition: RemoteDisposition.ambiguous,
          toStatus: snapshot.status,
          toDisposition: RemoteDisposition.unsent,
          attemptCount: snapshot.attemptCount,
          lastAttemptAt: snapshot.lastAttemptAt,
          clearLastAttemptAt: snapshot.lastAttemptAt == null,
          nextRetryAt: snapshot.nextRetryAt,
          clearNextRetryAt: snapshot.nextRetryAt == null,
          lastError: snapshot.lastError,
          clearLastError: snapshot.lastError == null,
          clearClaimId: true,
          expectedClaimId: claimId,
          executor: db,
        );
        expect(changed, isTrue);

        final row = (await db.query(
          'outbox',
          where: 'operation_id = ?',
          whereArgs: [operationId],
        ))
            .single;
        expect(row['status'], snapshot.status);
        expect(row['remote_disposition'], 'UNSENT');
        expect(row['attempt_count'], snapshot.attemptCount);
        expect(row['last_attempt_at'], snapshot.lastAttemptAt);
        expect(row['next_retry_at'], snapshot.nextRetryAt);
        expect(row['last_error'], snapshot.lastError);
        expect(row['claim_id'], isNull);
        expect(jsonDecode(row['payload'] as String), payload);
      }
    });

    test(
        'E2-T05: Bootstrap preserva zero escritas em caso de cancelamento durante paginação',
        () async {
      var callCount = 0;
      var cancelRequested = false;

      final transport = _CapturingHttpClient((req) async {
        callCount++;
        if (callCount == 1) {
          return http.Response(
            jsonEncode({
              'contractVersion': 2,
              'complete': false,
              'continuationToken': 'page-2-token',
              'bootstrapCursor': '100',
              'records': [
                {
                  'entityType': 'CUSTOMER',
                  'data': {
                    'id': 'boot-1',
                    'name': 'Boot 1',
                    'updated_at': '2026-01-01'
                  }
                }
              ]
            }),
            200,
          );
        } else {
          return http.Response(
            jsonEncode({
              'contractVersion': 2,
              'complete': true,
              'bootstrapProof': 'proof-final',
              'bootstrapCursor': '100',
              'records': [
                {
                  'entityType': 'CUSTOMER',
                  'data': {
                    'id': 'boot-2',
                    'name': 'Boot 2',
                    'updated_at': '2026-01-01'
                  }
                }
              ]
            }),
            200,
          );
        }
      });

      final lease = SyncLease(
        db: db,
        credential: BoundCredential.explicit('TOKEN_BOOT'),
        isCancelled: () => cancelRequested,
      );

      // We clear sync_metadata so bootstrap is needed
      await db.delete('sync_metadata');

      // Cancel between page 1 and page 2
      // We can intercept by wrapping transport or checking callCount
      final origHandler = transport.handler;
      final wrappedTransport = _CapturingHttpClient((req) async {
        final res = await origHandler(req);
        if (callCount == 1) {
          cancelRequested = true;
        }
        return res;
      });

      final engineWithCancel = SyncEngine(
        apiClient:
            ApiClient(baseUrl: 'http://fake.api', client: wrappedTransport),
      );

      await engineWithCancel.ensureV2Bootstrap(lease: lease);

      // Verify ZERO records written to customers
      final custRows = await db.query('customers');
      expect(custRows, isEmpty,
          reason:
              'Zero writes to projection during interrupted bootstrap pagination');

      // Verify bootstrap proof not written
      final metaRows = await db.query('sync_metadata');
      expect(metaRows, isEmpty);
    });

    test('E2-T06: Timeout de HTTP não cancela transporte e não executa Unclaim',
        () async {
      final outboxDao = OutboxDao();
      final item = OutboxItem(
        operationId: 'op-timeout-1',
        entityType: 'CUSTOMER',
        entityId: 'c-4',
        operationType: 'CREATE',
        payload: {'name': 'Client 4'},
        createdAt: '2026-01-01T00:00:00.000Z',
        attemptCount: 0,
        lastAttemptAt: null,
        status: 'PENDING',
        remoteDisposition: RemoteDisposition.unsent,
      );
      await outboxDao.insert(item, executor: db);

      final lease = SyncLease(
        db: db,
        credential: BoundCredential.explicit('TOKEN_TIMEOUT'),
        isCancelled: () => false,
      );

      // We do not wait for the 15s real timer; we verify that upon TimeoutException
      // the catch recovery moves entry to REQUIRES_ATTENTION/AMBIGUOUS, NEVER UNSENT.
      // We simulate timeout by throwing TimeoutException directly via mock client:
      final timeoutTransport = _CapturingHttpClient((req) async {
        throw TimeoutException('Simulated HTTP timeout');
      });

      final timeoutEngine = SyncEngine(
        apiClient:
            ApiClient(baseUrl: 'http://fake.api', client: timeoutTransport),
        outboxDao: outboxDao,
      );

      try {
        await timeoutEngine.pushPendingOutbox(lease: lease);
      } catch (_) {}

      final row = (await db.query('outbox',
              where: 'operation_id = ?', whereArgs: ['op-timeout-1']))
          .first;
      expect(row['status'], 'REQUIRES_ATTENTION');
      expect(row['remote_disposition'], 'AMBIGUOUS');
      expect(row['attempt_count'], 1);
      expect(row['last_attempt_at'], isNotNull);
      expect(row['last_error'], contains('Simulated HTTP timeout'));
    });
  });
}
