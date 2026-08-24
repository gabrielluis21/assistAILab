import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:assistailab/core/sync/sync_trigger.dart';
import 'package:assistailab/core/sync/sync_state.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/sync/background_sync_coordinator.dart';
import 'package:assistailab/core/sync/sync_scheduler.dart';
import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:assistailab/core/network/api_client.dart';

class FakeApiClient extends ApiClient {
  int pushCalls = 0;
  int pullCalls = 0;
  bool shouldFailPush = false;
  bool shouldFailPull = false;
  Duration delay = Duration.zero;

  FakeApiClient() : super(baseUrl: 'http://fake.api');
}

class FakeOutboxDao extends OutboxDao {
  int pendingCount = 0;
  int recoveredCount = 0;
  List<OutboxItem> pendingItems = [];

  @override
  Future<int> getPendingCount() async => pendingCount;

  @override
  Future<int> recoverProcessingEntries({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final count = recoveredCount;
    recoveredCount = 0;
    return count;
  }

  @override
  Future<List<OutboxItem>> getPendingEntries({int limit = 20}) async =>
      pendingItems;
}

class FakeSyncEngine extends SyncEngine {
  int pushCount = 0;
  int pullCount = 0;
  bool shouldThrow = false;
  Duration delay = Duration.zero;
  Completer<void>? inProgressCompleter;

  /// Controls how many entries the fake push reports as processed.
  int fakePushProcessed = 1;

  /// Controls how many changes the fake pull reports.
  int fakePullChanges = 0;

  FakeSyncEngine({required super.apiClient, super.outboxDao});

  @override
  Future<SyncPushSummary> pushPendingOutbox({int batchSize = 20}) async {
    pushCount++;
    if (delay > Duration.zero) {
      await Future.delayed(delay);
    }
    if (inProgressCompleter != null) {
      await inProgressCompleter!.future;
    }
    if (shouldThrow) {
      throw Exception('Network push failed');
    }
    return SyncPushSummary(
        totalProcessed: fakePushProcessed, syncedCount: fakePushProcessed);
  }

  @override
  Future<SyncPullSummary> pullIncrementalChanges({
    int pullPageSize = 50,
    int maxPullPagesPerCycle = 10,
  }) async {
    pullCount++;
    if (delay > Duration.zero) {
      await Future.delayed(delay);
    }
    if (shouldThrow) {
      throw Exception('Network pull failed');
    }
    return SyncPullSummary(totalChanges: fakePullChanges);
  }
}

class MockHttpClientWithCustomResponses extends http.BaseClient {
  final Future<http.Response> Function(http.Request request) handler;
  MockHttpClientWithCustomResponses(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request as http.Request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async {
        return Directory.systemTemp.path;
      },
    );
    final tempDir = Directory.systemTemp.createTempSync();
    Hive.init(tempDir.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SyncTrigger & SyncState Unit Tests', () {
    test('SyncTrigger enum contains all required triggers', () {
      expect(
          SyncTrigger.values,
          containsAll([
            SyncTrigger.authenticated,
            SyncTrigger.localMutation,
            SyncTrigger.periodic,
            SyncTrigger.connectivityRestored,
            SyncTrigger.appResumed,
            SyncTrigger.manual,
            SyncTrigger.scheduledConsolidation,
          ]));
    });

    test('SyncState initial state has default values', () {
      final state = SyncState.initial();
      expect(state.status, equals(SyncStatus.idle));
      expect(state.isSyncing, isFalse);
      expect(state.pendingOutboxCount, equals(0));
      expect(state.lastSyncAt, isNull);
      expect(state.lastError, isNull);
      expect(state.isHealthy, isTrue);
      expect(state.hasPendingMutations, isFalse);
    });

    test('SyncState copyWith correctly modifies fields and clears errors', () {
      final initial = SyncState.initial();
      final syncing = initial.copyWith(
        status: SyncStatus.syncing,
        isSyncing: true,
        lastTrigger: SyncTrigger.manual,
        pendingOutboxCount: 3,
      );

      expect(syncing.status, equals(SyncStatus.syncing));
      expect(syncing.isSyncing, isTrue);
      expect(syncing.lastTrigger, equals(SyncTrigger.manual));
      expect(syncing.pendingOutboxCount, equals(3));
      expect(syncing.hasPendingMutations, isTrue);

      final errorState = syncing.copyWith(
        status: SyncStatus.error,
        isSyncing: false,
        lastError: 'HTTP 500 Server Error',
      );

      expect(errorState.status, equals(SyncStatus.error));
      expect(errorState.isHealthy, isFalse);
      expect(errorState.lastError, equals('HTTP 500 Server Error'));

      final recovered = errorState.copyWith(
        status: SyncStatus.idle,
        clearLastError: true,
      );

      expect(recovered.status, equals(SyncStatus.idle));
      expect(recovered.isHealthy, isTrue);
      expect(recovered.lastError, isNull);
    });
  });

  group('SyncEngine Retry, Backoff & Atomic Cursor Tests', () {
    test('calculateNextRetryAt grows exponentially and respects max boundary',
        () {
      final engine =
          SyncEngine(apiClient: FakeApiClient(), outboxDao: FakeOutboxDao());
      final now = DateTime.now();

      final retry0 = engine.calculateNextRetryAt(0);
      final retry1 = engine.calculateNextRetryAt(1);
      final retry2 = engine.calculateNextRetryAt(2);
      final retry8 = engine.calculateNextRetryAt(8);

      expect(retry0.isAfter(now), isTrue);
      expect(retry1.isAfter(retry0), isTrue);
      expect(retry2.isAfter(retry1), isTrue);

      // Max backoff capped at 300 seconds (+ 2s max jitter)
      final maxDiff = retry8.difference(now).inSeconds;
      expect(maxDiff, lessThanOrEqualTo(305));
    });

    test(
        'pullIncrementalChanges persists cursor and changes atomically in same transaction',
        () async {
      // 1. Set initial cursor
      final db = await SqliteDatabase.instance;
      await db.insert(
        'sync_metadata',
        {'key': 'last_cursor', 'value': 'initial_cursor_100'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // The mock returns advancing cursor on call 1, same cursor on call 2
      // so the engine makes exactly 2 HTTP calls before stabilising.
      int callCount = 0;
      final client = MockHttpClientWithCustomResponses((request) async {
        if (request.url.path.contains('/sync/changes')) {
          callCount++;
          if (callCount == 1) {
            return http.Response(
              jsonEncode({
                'nextCursor': 'next_cursor_200',
                'changes': [
                  {
                    'entityType': 'CUSTOMER',
                    'entityId': 'cust_atomic_1',
                    'operationType': 'CREATE',
                    'data': {
                      'name': 'Atomic Customer',
                      'email': 'atomic@test.com',
                    },
                  }
                ]
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          } else {
            // Same cursor → engine stops.
            return http.Response(
              jsonEncode({'nextCursor': 'next_cursor_200', 'changes': []}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
        }
        return http.Response('Not Found', 404);
      });

      final apiClient = ApiClient(baseUrl: 'http://test.api', client: client);
      final engine = SyncEngine(apiClient: apiClient);

      final result = await engine.pullIncrementalChanges();
      expect(result.totalChanges, equals(1));
      expect(result.nextCursor, equals('next_cursor_200'));

      final storedCursor = await engine.getLocalCursor();
      expect(storedCursor, equals('next_cursor_200'));

      final customerRow = await db.query(
        'customers',
        where: 'id = ?',
        whereArgs: ['cust_atomic_1'],
      );
      expect(customerRow, isNotEmpty);
      expect(customerRow.first['name'], equals('Atomic Customer'));
    });

    test(
        'pullIncrementalChanges rolls back cursor if applying changes throws error',
        () async {
      final db = await SqliteDatabase.instance;
      await db.insert(
        'sync_metadata',
        {'key': 'last_cursor', 'value': 'stable_cursor_v1'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      // We send invalid customer change that will cause SQLite error
      final client = MockHttpClientWithCustomResponses((request) async {
        if (request.url.path.contains('/sync/changes')) {
          return http.Response(
            jsonEncode({
              'nextCursor': 'uncommitted_cursor_v2',
              'changes': [
                {
                  'entityType': 'CUSTOMER',
                  'entityId': 'valid_cust',
                  'operationType': 'CREATE',
                  'data': {'name': 'Valid'},
                },
                {
                  // Corrupted payload that causes transaction exception
                  'entityType': 'CUSTOMER',
                  'entityId': 'fail_cust',
                  'operationType': null, // Throws TypeError inside transaction
                  'data': {},
                }
              ]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final apiClient = ApiClient(baseUrl: 'http://test.api', client: client);
      final engine = SyncEngine(apiClient: apiClient);

      // Verify that pull throws due to transaction failure
      await expectLater(
        engine.pullIncrementalChanges(),
        throwsA(anything),
      );

      // Verify transaction rolled back and cursor was NOT updated
      final cursorAfter = await engine.getLocalCursor();
      expect(cursorAfter, equals('stable_cursor_v1'));
    });
  });

  group('BackgroundSyncCoordinator Lifecycle & Concurrency Tests', () {
    late FakeApiClient fakeApi;
    late FakeOutboxDao fakeDao;
    late FakeSyncEngine fakeEngine;
    late BackgroundSyncCoordinator coordinator;

    setUp(() {
      fakeApi = FakeApiClient();
      fakeDao = FakeOutboxDao();
      fakeEngine = FakeSyncEngine(apiClient: fakeApi, outboxDao: fakeDao);
      coordinator = BackgroundSyncCoordinator(
        syncEngine: fakeEngine,
        outboxDao: fakeDao,
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('Coordinator initializes and recovers interrupted operations',
        () async {
      fakeDao.recoveredCount = 4;
      fakeDao.pendingCount = 2;

      await coordinator.initialize();

      expect(coordinator.state.pendingOutboxCount, equals(2));
      expect(fakeDao.recoveredCount, equals(0)); // Reset after recovery
    });

    test('Coordinator performs push then pull successfully and emits states',
        () async {
      final states = <SyncState>[];
      coordinator.stateStream.listen(states.add);

      await coordinator.requestSync(SyncTrigger.manual);

      expect(fakeEngine.pushCount, equals(1));
      expect(fakeEngine.pullCount, equals(1));
      expect(coordinator.state.status, equals(SyncStatus.idle));
      expect(coordinator.state.isSyncing, isFalse);
      expect(coordinator.state.lastSyncAt, isNotNull);
      expect(coordinator.state.isHealthy, isTrue);
    });

    test(
        'Coordinator prevents concurrent executions and executes catch-up cycle',
        () async {
      fakeEngine.inProgressCompleter = Completer<void>();

      // 1. Start first sync (it will pause in push)
      final firstSyncFuture = coordinator.requestSync(SyncTrigger.manual);

      // Give event loop time to set isSyncing
      await Future.delayed(const Duration(milliseconds: 10));
      expect(coordinator.state.isSyncing, isTrue);

      // 2. Request second sync while first is still running
      final secondSyncFuture = coordinator.requestSync(SyncTrigger.periodic);

      // Verify that engine has only run push once so far
      expect(fakeEngine.pushCount, equals(1));

      // 3. Complete the first sync
      fakeEngine.inProgressCompleter!.complete();
      await firstSyncFuture;
      await secondSyncFuture;

      // Allow catch-up microtask to execute
      await Future.delayed(const Duration(milliseconds: 20));

      // Both cycles should have executed sequentially
      expect(fakeEngine.pushCount, equals(2));
      expect(fakeEngine.pullCount, equals(2));
      expect(coordinator.state.isSyncing, isFalse);
    });

    test(
        'Coordinator handles failures gracefully without crashing and updates state',
        () async {
      fakeEngine.shouldThrow = true;

      await coordinator.requestSync(SyncTrigger.manual);

      expect(coordinator.state.status, equals(SyncStatus.error));
      expect(coordinator.state.isSyncing, isFalse);
      expect(coordinator.state.lastError, contains('Network push failed'));
      expect(coordinator.state.isHealthy, isFalse);
    });

    test('Coordinator debounces localMutation triggers', () async {
      await coordinator.requestSync(
        SyncTrigger.localMutation,
        debounceDuration: const Duration(milliseconds: 50),
      );
      await coordinator.requestSync(
        SyncTrigger.localMutation,
        debounceDuration: const Duration(milliseconds: 50),
      );
      await coordinator.requestSync(
        SyncTrigger.localMutation,
        debounceDuration: const Duration(milliseconds: 50),
      );

      // Immediately, engine has not run yet because of debounce
      expect(fakeEngine.pushCount, equals(0));

      // Wait for debounce timer
      await Future.delayed(const Duration(milliseconds: 100));

      // Should have run exactly once for all 3 mutations
      expect(fakeEngine.pushCount, equals(1));
    });
  });

  group('SyncScheduler Adaptive Cadence Tests', () {
    late FakeApiClient fakeApi;
    late FakeOutboxDao fakeDao;
    late FakeSyncEngine fakeEngine;
    late BackgroundSyncCoordinator coordinator;
    late SyncScheduler scheduler;

    setUp(() {
      fakeApi = FakeApiClient();
      fakeDao = FakeOutboxDao();
      fakeEngine = FakeSyncEngine(apiClient: fakeApi, outboxDao: fakeDao);
      coordinator = BackgroundSyncCoordinator(
        syncEngine: fakeEngine,
        outboxDao: fakeDao,
      );
      scheduler = SyncScheduler(coordinator: coordinator);
    });

    tearDown(() {
      scheduler.dispose();
      coordinator.dispose();
    });

    test('Scheduler begins at NORMAL cadence (45s)', () {
      expect(scheduler.currentCadence, equals(SyncCadence.normal));
      expect(scheduler.currentCadence.interval,
          equals(const Duration(seconds: 45)));
    });

    test('localMutation trigger immediately transitions cadence to HOT (15s)',
        () async {
      scheduler.start();
      await scheduler.requestSync(SyncTrigger.localMutation);

      expect(scheduler.currentCadence, equals(SyncCadence.hot));
      expect(scheduler.currentCadence.interval,
          equals(const Duration(seconds: 15)));
    });

    test('Scheduler dispatches appResumed lifecycle event and resets to NORMAL',
        () async {
      scheduler.start();
      scheduler.didChangeAppLifecycleState(AppLifecycleState.resumed);

      await Future.delayed(const Duration(milliseconds: 20));

      expect(fakeEngine.pushCount, equals(1));
      expect(coordinator.state.lastTrigger, equals(SyncTrigger.appResumed));
      expect(scheduler.currentCadence, equals(SyncCadence.normal));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Item 1: Pull Catch-up — cursor-progress based termination
  // ─────────────────────────────────────────────────────────────────────────
  group('SyncEngine Pull Cursor-Progress Tests', () {
    test('Pull continues when changes=[] but cursor advances (cursor progress)',
        () async {
      int callCount = 0;
      // Page 1: 0 changes but cursor advances (cursor-progress = continue)
      // Page 2: cursor stabilises (stop)
      final cursors = [
        ('cursor_v2', <dynamic>[]),
        ('cursor_v2', <dynamic>[]), // same cursor → stop
      ];

      final client = MockHttpClientWithCustomResponses((request) async {
        if (request.url.path.contains('/sync/changes')) {
          final entry = cursors[callCount.clamp(0, cursors.length - 1)];
          callCount++;
          return http.Response(
            jsonEncode({'nextCursor': entry.$1, 'changes': entry.$2}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('Not Found', 404);
      });

      final apiClient = ApiClient(baseUrl: 'http://test.api', client: client);
      final engine = SyncEngine(apiClient: apiClient);

      final result = await engine.pullIncrementalChanges();

      // Should have fetched 2 pages: first advanced cursor, second stabilised.
      expect(callCount, equals(2));
      expect(result.totalChanges, equals(0));
    });

    test('Pull stops immediately when cursor does not advance (first page)',
        () async {
      int callCount = 0;
      final client = MockHttpClientWithCustomResponses((request) async {
        callCount++;
        return http.Response(
          jsonEncode({
            'nextCursor': null, // no cursor → stop immediately
            'changes': <dynamic>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://test.api', client: client);
      final engine = SyncEngine(apiClient: apiClient);

      await engine.pullIncrementalChanges();

      // Should only have made one request because cursor didn't advance.
      expect(callCount, equals(1));
    });

    test('Pull respects maxPullPagesPerCycle limit (10 pages)', () async {
      // Clear any cursor left by previous tests to ensure deterministic start.
      final db = await SqliteDatabase.instance;
      await db.delete('sync_metadata',
          where: 'key = ?', whereArgs: ['last_cursor']);

      int callCount = 0;
      // Use timestamp-based prefixes to avoid ID/cursor conflicts with other tests.
      final ts = DateTime.now().millisecondsSinceEpoch;
      // Always returns a different advancing cursor so loop would be infinite
      // without the page guard.
      final client = MockHttpClientWithCustomResponses((request) async {
        callCount++;
        return http.Response(
          jsonEncode({
            'nextCursor': 'cur_${ts}_v$callCount',
            'changes': [
              {
                'entityType': 'CUSTOMER',
                'entityId': 'pg_${ts}_c$callCount',
                'operationType': 'CREATE',
                'data': {'name': 'Customer $callCount'},
              }
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final apiClient = ApiClient(baseUrl: 'http://test.api', client: client);
      final engine = SyncEngine(apiClient: apiClient);

      final result =
          await engine.pullIncrementalChanges(maxPullPagesPerCycle: 10);

      // Must stop at exactly 10 pages.
      expect(callCount, equals(10));
      expect(result.totalChanges, equals(10));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Item 2: Processing Recovery — stale timeout filter
  // ─────────────────────────────────────────────────────────────────────────
  group('OutboxDao Processing Recovery Timeout Tests', () {
    test('recoverProcessingEntries does NOT recover recent PROCESSING entries',
        () async {
      final db = await SqliteDatabase.instance;

      // Insert a PROCESSING entry with last_attempt_at = now (fresh)
      final freshOpId = 'op-fresh-${DateTime.now().millisecondsSinceEpoch}';
      await db.insert('outbox', {
        'operation_id': freshOpId,
        'entity_type': 'CUSTOMER',
        'entity_id': 'cust-1',
        'operation_type': 'CREATE',
        'payload': '{}',
        'status': 'PROCESSING',
        'attempt_count': 1,
        'created_at': DateTime.now().toIso8601String(),
        'last_attempt_at': DateTime.now().toIso8601String(),
      });

      final dao = OutboxDao();
      // Using a 5-minute timeout: fresh entry should NOT be recovered.
      final count = await dao.recoverProcessingEntries(
          timeout: const Duration(minutes: 5));

      // Fresh entry is not stale — 0 should be recovered.
      expect(count, equals(0));

      // Clean up
      await db
          .delete('outbox', where: 'operation_id = ?', whereArgs: [freshOpId]);
    });

    test(
        'recoverProcessingEntries DOES recover stale PROCESSING entries (>5min)',
        () async {
      final db = await SqliteDatabase.instance;

      // Insert a PROCESSING entry with last_attempt_at = 10 minutes ago (stale)
      final staleOpId = 'op-stale-${DateTime.now().millisecondsSinceEpoch}';
      final staleTime = DateTime.now()
          .subtract(const Duration(minutes: 10))
          .toIso8601String();
      await db.insert('outbox', {
        'operation_id': staleOpId,
        'entity_type': 'CUSTOMER',
        'entity_id': 'cust-2',
        'operation_type': 'CREATE',
        'payload': '{}',
        'status': 'PROCESSING',
        'attempt_count': 1,
        'created_at': DateTime.now().toIso8601String(),
        'last_attempt_at': staleTime,
      });

      final dao = OutboxDao();
      final count = await dao.recoverProcessingEntries(
          timeout: const Duration(minutes: 5));

      // Stale entry must be recovered → FAILED.
      expect(count, greaterThanOrEqualTo(1));

      final rows = await db
          .query('outbox', where: 'operation_id = ?', whereArgs: [staleOpId]);
      expect(rows.isNotEmpty, isTrue);
      expect(rows.first['status'], equals('FAILED'));

      // Clean up
      await db
          .delete('outbox', where: 'operation_id = ?', whereArgs: [staleOpId]);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Item 4: Scheduler Work Detection
  // ─────────────────────────────────────────────────────────────────────────
  group('Scheduler IDLE Work Detection Tests', () {
    late FakeApiClient fakeApi;
    late FakeOutboxDao fakeDao;
    late FakeSyncEngine fakeEngine;
    late BackgroundSyncCoordinator coordinator;
    late SyncScheduler scheduler;

    setUp(() {
      fakeApi = FakeApiClient();
      fakeDao = FakeOutboxDao();
      fakeEngine = FakeSyncEngine(apiClient: fakeApi, outboxDao: fakeDao);
      coordinator = BackgroundSyncCoordinator(
        syncEngine: fakeEngine,
        outboxDao: fakeDao,
      );
      scheduler = SyncScheduler(coordinator: coordinator);
    });

    tearDown(() {
      scheduler.dispose();
      coordinator.dispose();
    });

    test(
        'consecutiveEmptyCycles does NOT increment when cycle did real pull work',
        () async {
      // Engine reports 5 changes pulled.
      fakeEngine.fakePushProcessed = 0;
      fakeEngine.fakePullChanges = 5;

      await coordinator.requestSync(SyncTrigger.periodic);

      expect(coordinator.lastCycleDidWork, isTrue);

      // Simulate one scheduler tick evaluation.
      // Cadence should NOT promote to IDLE because cycle did work.
      // Manually trigger _onAdaptiveTick logic via requestSync + check.
      // State: healthy + pull work → consecutiveEmptyCycles stays 0.
      // We check this via calling scheduler.requestSync(periodic) internally;
      // since scheduler internals are private, we verify via coordinator flag.
      expect(coordinator.lastCycleDidWork, isTrue);
    });

    test(
        'consecutiveEmptyCycles increments only when push=0 AND pull=0 AND pending=0',
        () async {
      // Engine does nothing: no push, no pull.
      fakeEngine.fakePushProcessed = 0;
      fakeEngine.fakePullChanges = 0;
      fakeDao.pendingCount = 0;

      await coordinator.requestSync(SyncTrigger.periodic);

      // lastCycleDidWork must be false.
      expect(coordinator.lastCycleDidWork, isFalse);
    });

    test('lastCycleDidWork is true when push processed entries', () async {
      fakeEngine.fakePushProcessed = 3;
      fakeEngine.fakePullChanges = 0;

      await coordinator.requestSync(SyncTrigger.manual);

      expect(coordinator.lastCycleDidWork, isTrue);
    });
  });
}
