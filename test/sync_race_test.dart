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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

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
    await AuthScopedDatabaseManager.instance.closeCurrentDatabase();
    if (Hive.isBoxOpen('auth_box')) {
      final box = Hive.box('auth_box');
      await box.close();
    }
    await Hive.deleteBoxFromDisk('auth_box');
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
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
      final dbA =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

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
        databaseResolver: () async =>
            AuthScopedDatabaseManager.instance.activeDatabase,
        tokenResolver: () async => apiClient.getAuthToken(),
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
      await AuthScopedDatabaseManager.instance.closeCurrentDatabase();

      // Step H: Establish Scope B and DB B
      final dbB =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeB);

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
      expect(cursorB, isNull,
          reason: 'DB B metadata/cursor must not be modified by stale Sync A');

      // 6. Stale A result did not publish into Coordinator B
      final coordinatorB = BackgroundSyncCoordinator(
        syncEngine: syncEngine,
        outboxDao: outboxDao,
        databaseResolver: () async =>
            AuthScopedDatabaseManager.instance.activeDatabase,
        tokenResolver: () async => apiClient.getAuthToken(),
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
      await AuthScopedDatabaseManager.instance.closeCurrentDatabase();
      expect(() => SqliteDatabase.instance, throwsA(isA<StateError>()));
    });

    test(
        'CANCELLATION LEASE: Multi-page pull immediately halts before page 2 when cancelled',
        () async {
      final dbA =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);
      int pullPageCount = 0;

      final transport = _CapturingHttpClient((request) async {
        pullPageCount++;
        if (pullPageCount == 1) {
          return http.Response(
            jsonEncode({
              'nextCursor': 'cur_page_2',
              'changes': [
                {
                  'entityType': 'CUSTOMER',
                  'entityId': 'c_1',
                  'operationType': 'CREATE',
                  'data': {'name': 'Client Page 1'},
                }
              ],
            }),
            200,
          );
        } else {
          // Page 2 should never be reached if cancelled
          return http.Response(
              jsonEncode({'nextCursor': 'cur_page_3', 'changes': []}), 200);
        }
      });

      final apiClient =
          ApiClient(baseUrl: 'http://fake.api', client: transport);
      final syncEngine = SyncEngine(apiClient: apiClient);

      int cancelChecks = 0;
      final lease = SyncLease(
        db: dbA,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () {
          cancelChecks++;
          // Checks 1-3 occur for page 1 (entry, before HTTP 1, before DB write 1).
          // Check 4 occurs between page 1 and page 2 (before HTTP 2).
          return cancelChecks >= 4;
        },
      );

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
      final dbA =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);
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
        databaseResolver: () async => dbA,
        tokenResolver: () async => 'TOKEN_A',
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
      final dbB =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeB);

      final transport = _CapturingHttpClient((request) async {
        return http.Response(
          jsonEncode({
            'nextCursor': null,
            'changes': [
              {
                'entityType': 'CUSTOMER',
                'entityId': 'c_bound',
                'operationType': 'CREATE',
                'data': {'name': 'Bound Client'},
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
      final dbA =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

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
      final dbA =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

      int pagesRequested = 0;
      final transport = _CapturingHttpClient((request) async {
        pagesRequested++;
        if (pagesRequested == 1) {
          return http.Response(
            jsonEncode({
              'nextCursor': 'cursor_page_2',
              'changes': [
                {
                  'entityType': 'CUSTOMER',
                  'entityId': 'cust_1',
                  'operationType': 'CREATE',
                  'data': {'name': 'Customer 1'},
                }
              ],
            }),
            200,
          );
        } else if (pagesRequested == 2) {
          return http.Response(
            jsonEncode({
              'nextCursor': 'cursor_page_3',
              'changes': [
                {
                  'entityType': 'CUSTOMER',
                  'entityId': 'cust_2',
                  'operationType': 'CREATE',
                  'data': {'name': 'Customer 2'},
                }
              ],
            }),
            200,
          );
        } else {
          // Cursor stabilized: no more changes
          return http.Response(
            jsonEncode({
              'nextCursor': 'cursor_page_3',
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
      expect(summary.nextCursor, 'cursor_page_3');

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
      final dbA =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

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
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

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
        databaseResolver: () async =>
            AuthScopedDatabaseManager.instance.activeDatabase,
        tokenResolver: () async =>
            throw Exception('credential store unavailable'),
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
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

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
        databaseResolver: () async =>
            AuthScopedDatabaseManager.instance.activeDatabase,
        tokenResolver: () async => '',
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
      final dbA =
          await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

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
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(scopeA);

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
        databaseResolver: () async =>
            AuthScopedDatabaseManager.instance.activeDatabase,
        tokenResolver: () async => '   ',
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
        final dbA = await AuthScopedDatabaseManager.instance
            .openDatabaseForScope(scopeA);

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
}
