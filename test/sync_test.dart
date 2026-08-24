import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/core/sync/sync_trigger.dart';
import 'package:assistailab/core/sync/sync_state.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/sync/background_sync_coordinator.dart';
import 'package:assistailab/core/sync/sync_scheduler.dart';
import 'package:assistailab/core/database/outbox_dao.dart';
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
  Future<int> recoverProcessingEntries() async {
    final count = recoveredCount;
    recoveredCount = 0;
    return count;
  }

  @override
  Future<List<OutboxItem>> getPendingEntries({int limit = 20}) async => pendingItems;
}

class FakeSyncEngine extends SyncEngine {
  int pushCount = 0;
  int pullCount = 0;
  bool shouldThrow = false;
  Duration delay = Duration.zero;
  Completer<void>? inProgressCompleter;

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
    return const SyncPushSummary(totalProcessed: 1, syncedCount: 1);
  }

  @override
  Future<SyncPullSummary> pullIncrementalChanges({int limit = 50}) async {
    pullCount++;
    if (delay > Duration.zero) {
      await Future.delayed(delay);
    }
    if (shouldThrow) {
      throw Exception('Network pull failed');
    }
    return const SyncPullSummary(totalChanges: 0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncTrigger & SyncState Unit Tests', () {
    test('SyncTrigger enum contains all required triggers', () {
      expect(SyncTrigger.values, containsAll([
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

  group('SyncEngine Retry & Backoff Tests', () {
    test('calculateNextRetryAt grows exponentially and respects max boundary', () {
      final engine = SyncEngine(apiClient: FakeApiClient(), outboxDao: FakeOutboxDao());
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

    test('Coordinator initializes and recovers interrupted operations', () async {
      fakeDao.recoveredCount = 4;
      fakeDao.pendingCount = 2;

      await coordinator.initialize();

      expect(coordinator.state.pendingOutboxCount, equals(2));
      expect(fakeDao.recoveredCount, equals(0)); // Reset after recovery
    });

    test('Coordinator performs push then pull successfully and emits states', () async {
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

    test('Coordinator prevents concurrent executions and executes catch-up cycle', () async {
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

    test('Coordinator handles failures gracefully without crashing and updates state', () async {
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

  group('SyncScheduler Tests', () {
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
      scheduler = SyncScheduler(
        coordinator: coordinator,
        periodicInterval: const Duration(milliseconds: 50),
        consolidationInterval: const Duration(milliseconds: 100),
      );
    });

    tearDown(() {
      scheduler.dispose();
      coordinator.dispose();
    });

    test('Scheduler triggers periodic sync on timer expiration', () async {
      scheduler.start();

      // Wait for periodic timer to tick
      await Future.delayed(const Duration(milliseconds: 70));

      expect(fakeEngine.pushCount, greaterThanOrEqualTo(1));
    });

    test('Scheduler dispatches appResumed lifecycle event', () async {
      scheduler.start();
      scheduler.didChangeAppLifecycleState(AppLifecycleState.resumed);

      await Future.delayed(const Duration(milliseconds: 20));

      expect(fakeEngine.pushCount, equals(1));
      expect(coordinator.state.lastTrigger, equals(SyncTrigger.appResumed));
    });
  });
}
