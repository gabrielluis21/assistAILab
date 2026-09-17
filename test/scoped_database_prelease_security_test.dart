import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:assistailab/core/database/scope_hash_generator.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:assistailab/core/network/api_client.dart';
import 'package:assistailab/core/sync/background_sync_coordinator.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/sync/sync_lease.dart';
import 'package:assistailab/core/sync/sync_trigger.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _ControlledOpener {
  final Map<String, Completer<void>> _entered = {};
  final Map<String, Completer<void>> _release = {};
  final Map<String, Database> opened = {};

  Future<Database> call(String fileName) async {
    _entered.putIfAbsent(fileName, Completer<void>.new).complete();
    await _release.putIfAbsent(fileName, Completer<void>.new).future;
    final database = await SqliteDatabase.openDatabaseByName(fileName);
    opened[fileName] = database;
    return database;
  }

  Future<void> waitUntilEntered(String fileName) =>
      _entered.putIfAbsent(fileName, Completer<void>.new).future;

  void release(String fileName) {
    final completer = _release.putIfAbsent(fileName, Completer<void>.new);
    if (!completer.isCompleted) completer.complete();
  }
}

final class _SequencedSameFileOpener {
  final List<Completer<void>> entered = [Completer<void>(), Completer<void>()];
  final List<Completer<void>> release = [Completer<void>(), Completer<void>()];
  int calls = 0;

  Future<Database> call(String fileName) async {
    final index = calls++;
    entered[index].complete();
    await release[index].future;
    return SqliteDatabase.openDatabaseByName(fileName);
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

final class _RecordingOutboxDao extends OutboxDao {
  int recoveryCalls = 0;
  int countCalls = 0;
  final List<DatabaseExecutor?> executors = [];

  @override
  Future<int> recoverProcessingEntries({
    Duration timeout = const Duration(minutes: 5),
    DatabaseExecutor? executor,
  }) async {
    recoveryCalls++;
    executors.add(executor);
    return 0;
  }

  @override
  Future<int> getPendingCount({DatabaseExecutor? executor}) async {
    countCalls++;
    executors.add(executor);
    return 0;
  }
}

final class _RecordingSyncEngine extends SyncEngine {
  int pushCalls = 0;
  int pullCalls = 0;
  SyncLease? observedLease;

  _RecordingSyncEngine({
    required super.apiClient,
    required super.outboxDao,
  });

  @override
  Future<SyncPushSummary> pushPendingOutbox({
    int batchSize = 20,
    Database? db,
    SyncLease? lease,
  }) async {
    pushCalls++;
    observedLease = lease;
    return const SyncPushSummary();
  }

  @override
  Future<SyncPullSummary> pullIncrementalChanges({
    int pullPageSize = 50,
    int maxPullPagesPerCycle = 10,
    Database? db,
    SyncLease? lease,
  }) async {
    pullCalls++;
    observedLease = lease;
    return const SyncPullSummary();
  }
}

final class _Barrier401SyncEngine extends SyncEngine {
  final Completer<void> requestEntered = Completer<void>();
  final Completer<void> releaseResponse = Completer<void>();
  int pullCalls = 0;

  _Barrier401SyncEngine({
    required super.apiClient,
    required super.outboxDao,
  });

  @override
  Future<SyncPushSummary> pushPendingOutbox({
    int batchSize = 20,
    Database? db,
    SyncLease? lease,
  }) async {
    requestEntered.complete();
    await releaseResponse.future;
    throw const SyncHttpException(
      statusCode: 401,
      operation: 'push',
      responseBody: 'unauthorized',
    );
  }

  @override
  Future<SyncPullSummary> pullIncrementalChanges({
    int pullPageSize = 50,
    int maxPullPagesPerCycle = 10,
    Database? db,
    SyncLease? lease,
  }) async {
    pullCalls++;
    return const SyncPullSummary();
  }
}

final class _RecordingHttpClient extends http.BaseClient {
  final int statusCode;
  final String body;
  int calls = 0;

  _RecordingHttpClient({this.statusCode = 200, this.body = '{}'});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      statusCode,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scopeA =
      ProfessionalAuthScope(userId: 'user-a', organizationId: 'org-a');
  const scopeB =
      ProfessionalAuthScope(userId: 'user-b', organizationId: 'org-b');

  late Directory tempDirectory;
  final databasesToClose = <Database>[];

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tempDirectory.path,
    );
  });

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('scoped_prelease_');
    databasesToClose.clear();
  });

  tearDown(() async {
    for (final database in databasesToClose) {
      if (database.isOpen) await database.close();
    }
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  group('AuthScopedDatabaseManager deterministic lifecycle', () {
    test('open A, logout, open B, then late A cannot resurrect A', () async {
      final opener = _ControlledOpener();
      final manager = AuthScopedDatabaseManager.forTesting(
        opener: (fileName) async {
          final database = await opener.call(fileName);
          databasesToClose.add(database);
          return database;
        },
      );
      final fileA = ScopeHashGenerator.databaseFileName(scopeA);
      final fileB = ScopeHashGenerator.databaseFileName(scopeB);

      final openA = manager.openDatabaseForScope(
        scopeA,
        sessionGeneration: 1,
      );
      final staleA = expectLater(openA, throwsA(isA<StateError>()));
      await opener.waitUntilEntered(fileA);

      await manager.closeCurrentDatabase(sessionGeneration: 2);
      final openB = manager.openDatabaseForScope(
        scopeB,
        sessionGeneration: 3,
      );
      await opener.waitUntilEntered(fileB);
      opener.release(fileB);
      final handleB = await openB;

      opener.release(fileA);
      await staleA;

      expect(manager.currentHandle, same(handleB));
      expect(manager.activeHandle, same(handleB));
      expect(manager.isCurrentHandle(handleB), isTrue);
      expect(handleB.authScope, scopeB);
      expect(handleB.sessionGeneration, 3);
      expect(handleB.fileName, fileB);
      expect(handleB.lifecycleEpoch, greaterThan(0));
      expect(opener.opened[fileA]!.isOpen, isFalse);
      expect(handleB.database.isOpen, isTrue);

      // A close issued by the older session is strictly a no-op.
      await manager.closeCurrentDatabase(sessionGeneration: 2);
      expect(manager.currentHandle, same(handleB));
      expect(handleB.database.isOpen, isTrue);

      await manager.closeCurrentDatabase(sessionGeneration: 4);
      expect(manager.currentHandle, isNull);
      expect(manager.isCurrentHandle(handleB), isFalse);
    });

    test('same filename physical opens are serialized', () async {
      final opener = _SequencedSameFileOpener();
      final manager = AuthScopedDatabaseManager.forTesting(
        opener: (fileName) async {
          final database = await opener.call(fileName);
          databasesToClose.add(database);
          return database;
        },
      );

      final first = manager.openDatabaseForScope(
        scopeA,
        sessionGeneration: 1,
      );
      final staleFirst = expectLater(first, throwsA(isA<StateError>()));
      await opener.entered[0].future;

      final second = manager.openDatabaseForScope(
        scopeA,
        sessionGeneration: 1,
      );
      await Future<void>.value();
      expect(opener.calls, 1);

      opener.release[0].complete();
      await staleFirst;
      await opener.entered[1].future;
      opener.release[1].complete();

      final handle = await second;
      expect(opener.calls, 2);
      expect(manager.currentHandle, same(handle));
      expect(manager.isCurrentHandle(handle), isTrue);

      await manager.closeCurrentDatabase(sessionGeneration: 1);
    });
  });

  group('Coordinator pre-lease proof', () {
    late AuthScopedDatabaseManager manager;
    late BoundDatabaseHandle handleA;

    setUp(() async {
      manager = AuthScopedDatabaseManager.forTesting(
        opener: (fileName) async {
          final database = await SqliteDatabase.openDatabaseByName(fileName);
          databasesToClose.add(database);
          return database;
        },
      );
      handleA = await manager.openDatabaseForScope(
        scopeA,
        sessionGeneration: 7,
      );
    });

    tearDown(() async {
      await manager.closeCurrentDatabase(sessionGeneration: 100);
    });

    _RecordingSyncEngine buildEngine(_RecordingOutboxDao dao) =>
        _RecordingSyncEngine(
          apiClient: ApiClient(baseUrl: 'http://unused.invalid'),
          outboxDao: dao,
        );

    test('current binding produces a lease pinned to its DB and token',
        () async {
      final dao = _RecordingOutboxDao();
      final engine = buildEngine(dao);
      final coordinator = BackgroundSyncCoordinator(
        syncEngine: engine,
        outboxDao: dao,
        sessionBinding: SyncSessionBinding(
          scope: scopeA,
          sessionGeneration: 7,
          resolveBoundHandle: () async => manager.currentHandle,
          isHandleCurrent: manager.isCurrentHandle,
          resolveToken: () async => 'TOKEN_A',
          isCurrentOnline: () => true,
          isAuthHttpGenerationCurrent: (generation) => generation == 7,
          onAuthorizationFailure: ({
            required sessionGeneration,
            required statusCode,
            required authorityRevalidation,
          }) {},
        ),
      );

      await coordinator.requestSync(SyncTrigger.manual);

      expect(engine.pushCalls, 1);
      expect(engine.pullCalls, 1);
      expect(engine.observedLease!.db, same(handleA.database));
      expect(engine.observedLease!.authToken, 'TOKEN_A');
      expect(dao.executors, isNotEmpty);
      expect(
          dao.executors
              .every((executor) => identical(executor, handleA.database)),
          isTrue);
      coordinator.dispose();
    });

    test('scope and session-generation mismatches fail before token or DAO',
        () async {
      for (final mismatch in <({AuthScope scope, int generation})>[
        (scope: scopeB, generation: 7),
        (scope: scopeA, generation: 8),
      ]) {
        final dao = _RecordingOutboxDao();
        final engine = buildEngine(dao);
        var tokenReads = 0;
        final coordinator = BackgroundSyncCoordinator(
          syncEngine: engine,
          outboxDao: dao,
          sessionBinding: SyncSessionBinding(
            scope: mismatch.scope,
            sessionGeneration: mismatch.generation,
            resolveBoundHandle: () async => handleA,
            isHandleCurrent: (_) => true,
            resolveToken: () async {
              tokenReads++;
              return 'MUST_NOT_BE_READ';
            },
            isCurrentOnline: () => true,
            isAuthHttpGenerationCurrent: (_) => true,
            onAuthorizationFailure: ({
              required sessionGeneration,
              required statusCode,
              required authorityRevalidation,
            }) {},
          ),
        );

        await coordinator.requestSync(SyncTrigger.manual);

        expect(tokenReads, 0);
        expect(dao.countCalls, 0);
        expect(engine.pushCalls, 0);
        expect(engine.pullCalls, 0);
        coordinator.dispose();
      }
    });

    test('missing database and missing binding are fail-closed', () async {
      for (final binding in <SyncSessionBinding?>[
        null,
        SyncSessionBinding(
          scope: scopeA,
          sessionGeneration: 7,
          resolveBoundHandle: () async => null,
          isHandleCurrent: (_) => true,
          resolveToken: () async => 'TOKEN_B_POISON',
          isCurrentOnline: () => true,
          isAuthHttpGenerationCurrent: (_) => true,
          onAuthorizationFailure: ({
            required sessionGeneration,
            required statusCode,
            required authorityRevalidation,
          }) {},
        ),
      ]) {
        final dao = _RecordingOutboxDao();
        final engine = buildEngine(dao);
        final coordinator = BackgroundSyncCoordinator(
          syncEngine: engine,
          outboxDao: dao,
          sessionBinding: binding,
        );

        await coordinator.initialize();
        await coordinator.requestSync(SyncTrigger.manual);

        expect(dao.recoveryCalls, 0);
        expect(dao.countCalls, 0);
        expect(engine.pushCalls, 0);
        expect(engine.pullCalls, 0);
        coordinator.dispose();
      }
    });

    test(
        'OFFLINE LIMITED BOUNDARY: Sync Push is blocked before token, DAO, push, or pull',
        () async {
      final dao = _RecordingOutboxDao();
      final engine = buildEngine(dao);
      var handleReads = 0;
      var tokenReads = 0;
      final coordinator = BackgroundSyncCoordinator(
        syncEngine: engine,
        outboxDao: dao,
        sessionBinding: SyncSessionBinding(
          scope: scopeA,
          sessionGeneration: 7,
          resolveBoundHandle: () async {
            handleReads++;
            return handleA;
          },
          isHandleCurrent: manager.isCurrentHandle,
          resolveToken: () async {
            tokenReads++;
            return 'MUST_NOT_BE_READ';
          },
          isCurrentOnline: () => false,
          isAuthHttpGenerationCurrent: (generation) => generation == 7,
          onAuthorizationFailure: ({
            required sessionGeneration,
            required statusCode,
            required authorityRevalidation,
          }) {},
        ),
      );

      await coordinator.initialize();
      await coordinator.requestSync(SyncTrigger.manual);

      expect(handleReads, 0);
      expect(tokenReads, 0);
      expect(dao.recoveryCalls, 0);
      expect(dao.countCalls, 0);
      expect(engine.pushCalls, 0);
      expect(engine.pullCalls, 0);
      coordinator.dispose();
    });

    test('token resolved after generation changes is never leased as token B',
        () async {
      final dao = _RecordingOutboxDao();
      final engine = buildEngine(dao);
      final tokenEntered = Completer<void>();
      final tokenRelease = Completer<String?>();
      var currentSessionGeneration = 7;

      final coordinator = BackgroundSyncCoordinator(
        syncEngine: engine,
        outboxDao: dao,
        sessionBinding: SyncSessionBinding(
          scope: scopeA,
          sessionGeneration: 7,
          resolveBoundHandle: () async => handleA,
          isHandleCurrent: manager.isCurrentHandle,
          resolveToken: () {
            tokenEntered.complete();
            return tokenRelease.future;
          },
          isCurrentOnline: () => true,
          isAuthHttpGenerationCurrent: (generation) =>
              generation == currentSessionGeneration,
          onAuthorizationFailure: ({
            required sessionGeneration,
            required statusCode,
            required authorityRevalidation,
          }) {},
        ),
      );

      final sync = coordinator.requestSync(SyncTrigger.manual);
      await tokenEntered.future;
      currentSessionGeneration = 8;
      tokenRelease.complete('TOKEN_B_POISON');
      await sync;

      expect(dao.countCalls, 0);
      expect(engine.pushCalls, 0);
      expect(engine.pullCalls, 0);
      expect(engine.observedLease, isNull);
      coordinator.dispose();
    });

    test('current Sync 401 invokes the generation-bound auth handler',
        () async {
      final dao = _RecordingOutboxDao();
      final engine = _Barrier401SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://unused.invalid'),
        outboxDao: dao,
      );
      final callbacks = <({
        int sessionGeneration,
        int statusCode,
        bool authorityRevalidation,
      })>[];

      final coordinator = BackgroundSyncCoordinator(
        syncEngine: engine,
        outboxDao: dao,
        sessionBinding: SyncSessionBinding(
          scope: scopeA,
          sessionGeneration: 7,
          resolveBoundHandle: () async => handleA,
          isHandleCurrent: manager.isCurrentHandle,
          resolveToken: () async => 'TOKEN_A',
          isCurrentOnline: () => true,
          isAuthHttpGenerationCurrent: (generation) => generation == 7,
          onAuthorizationFailure: ({
            required sessionGeneration,
            required statusCode,
            required authorityRevalidation,
          }) {
            callbacks.add((
              sessionGeneration: sessionGeneration,
              statusCode: statusCode,
              authorityRevalidation: authorityRevalidation,
            ));
          },
        ),
      );

      final sync = coordinator.requestSync(SyncTrigger.manual);
      await engine.requestEntered.future;
      engine.releaseResponse.complete();
      await sync;

      expect(callbacks, [
        (
          sessionGeneration: 7,
          statusCode: 401,
          authorityRevalidation: false,
        ),
      ]);
      expect(engine.pullCalls, 0);
      coordinator.dispose();
    });

    test('Sync 401 released after binding becomes stale invokes no handler',
        () async {
      final dao = _RecordingOutboxDao();
      final engine = _Barrier401SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://unused.invalid'),
        outboxDao: dao,
      );
      var currentSessionGeneration = 7;
      var callbackCalls = 0;

      final coordinator = BackgroundSyncCoordinator(
        syncEngine: engine,
        outboxDao: dao,
        sessionBinding: SyncSessionBinding(
          scope: scopeA,
          sessionGeneration: 7,
          resolveBoundHandle: () async => handleA,
          isHandleCurrent: manager.isCurrentHandle,
          resolveToken: () async => 'TOKEN_A',
          isCurrentOnline: () => true,
          isAuthHttpGenerationCurrent: (generation) =>
              generation == currentSessionGeneration,
          onAuthorizationFailure: ({
            required sessionGeneration,
            required statusCode,
            required authorityRevalidation,
          }) {
            callbackCalls++;
          },
        ),
      );

      final sync = coordinator.requestSync(SyncTrigger.manual);
      await engine.requestEntered.future;
      currentSessionGeneration = 8;
      engine.releaseResponse.complete();
      await sync;

      expect(callbackCalls, 0);
      expect(engine.pullCalls, 0);
      coordinator.dispose();
    });
  });

  group('SyncEngine leased fail-closed behavior', () {
    test('lease with null DB never falls back to a global database', () async {
      final dao = _RecordingOutboxDao();
      final transport = _RecordingHttpClient();
      final engine = SyncEngine(
        apiClient: ApiClient(
          baseUrl: 'http://unused.invalid',
          client: transport,
        ),
        outboxDao: dao,
      );
      final lease = SyncLease(
        db: null,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => false,
      );

      final push = await engine.pushPendingOutbox(lease: lease);
      final pull = await engine.pullIncrementalChanges(lease: lease);

      expect(push.totalProcessed, 0);
      expect(pull.totalChanges, 0);
      expect(dao.countCalls, 0);
      expect(transport.calls, 0);
    });

    test('non-success HTTP exposes typed status without changing SyncLease',
        () async {
      final database = await SqliteDatabase.openDatabaseByName(
        'typed_http_exception.db',
      );
      databasesToClose.add(database);
      await _activateSyncV2(database);
      final transport = _RecordingHttpClient(
        statusCode: 503,
        body: 'temporarily unavailable',
      );
      final engine = SyncEngine(
        apiClient: ApiClient(baseUrl: 'http://sync.invalid', client: transport),
      );
      final lease = SyncLease(
        db: database,
        credential: BoundCredential.explicit('TOKEN_A'),
        isCancelled: () => false,
      );

      await expectLater(
        engine.pullIncrementalChanges(lease: lease),
        throwsA(
          isA<SyncHttpException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having((error) => error.operation, 'operation', 'pull'),
        ),
      );
      expect(transport.calls, 1);
    });
  });
}
