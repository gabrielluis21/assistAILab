import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../database/outbox_dao.dart';
import 'sync_engine.dart';
import 'sync_lease.dart';
import 'sync_state.dart';
import 'sync_trigger.dart';

/// Coordinator for Background Synchronization.
///
/// Responsibilities:
/// - Coordinate push and pull sync cycles;
/// - Enforce concurrency locks so only one cycle runs at a time;
/// - Queue catch-up cycles when triggers occur during an active sync;
/// - Debounce high-frequency triggers (like repeated local mutations);
/// - Recover interrupted operations on initialization;
/// - Expose reactive SyncState;
/// - Expose [lastCycleDidWork] so the Scheduler can make accurate IDLE decisions;
/// - Provide SessionBoundSyncLease per logical cycle with database and credential binding.
class BackgroundSyncCoordinator {
  final SyncEngine syncEngine;
  final OutboxDao outboxDao;
  final Future<Database?> Function()? databaseResolver;
  final Future<String?> Function()? tokenResolver;

  final ValueNotifier<SyncState> _stateNotifier =
      ValueNotifier<SyncState>(SyncState.initial());
  final StreamController<SyncState> _stateController =
      StreamController<SyncState>.broadcast();

  bool _isSyncing = false;
  bool _hasPendingCatchUp = false;
  SyncTrigger? _pendingCatchUpTrigger;
  Timer? _debounceTimer;
  int _currentGeneration = 0;
  bool _isDisposed = false;

  /// Cancels any active or scheduled sync cycle.
  ///
  /// Increments [_currentGeneration] to invalidate any in-flight async operations
  /// and clears pending catch-ups.
  void cancelActiveSync() {
    _currentGeneration++;
    _isSyncing = false;
    _hasPendingCatchUp = false;
    _pendingCatchUpTrigger = null;
    _debounceTimer?.cancel();
  }

  /// Whether the last completed sync cycle performed any real work.
  ///
  /// True when at least one Outbox entry was pushed OR at least one remote
  /// change was pulled during the cycle. Used by [SyncScheduler] to decide
  /// whether to increment [consecutiveEmptyCycles].
  bool lastCycleDidWork = false;

  BackgroundSyncCoordinator({
    required this.syncEngine,
    OutboxDao? outboxDao,
    this.databaseResolver,
    this.tokenResolver,
  }) : outboxDao = outboxDao ?? OutboxDao();

  /// Current synchronization state snapshot.
  SyncState get state => _stateNotifier.value;

  /// ValueListenable for UI components to listen directly.
  ValueListenable<SyncState> get stateListenable => _stateNotifier;

  /// Stream of synchronization state transitions.
  Stream<SyncState> get stateStream => _stateController.stream;

  bool _isInitialized = false;
  Future<void>? _initFuture;

  /// Initializes coordinator and recovers any interrupted operations from prior sessions.
  /// Idempotent: repeated or concurrent invocations do not duplicate recovery or state calls.
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (_initFuture != null) return _initFuture;

    _initFuture = _performInitialization();
    try {
      await _initFuture;
      _isInitialized = true;
    } finally {
      _initFuture = null;
    }
  }

  Future<void> _performInitialization() async {
    await recoverInterruptedOperations();
    await _refreshPendingCount();
  }

  /// Recovers operations stuck in PROCESSING status (e.g. app terminated during push).
  /// Only recovers entries stale for more than 5 minutes.
  Future<void> recoverInterruptedOperations() async {
    try {
      DatabaseExecutor? targetDb;
      if (databaseResolver != null) {
        targetDb = await databaseResolver!();
      }
      final recovered =
          await outboxDao.recoverProcessingEntries(executor: targetDb);
      if (recovered > 0) {
        debugPrint(
            '🔄 BackgroundSyncCoordinator: Recovered $recovered stale PROCESSING entries → FAILED.');
      }
    } catch (e) {
      debugPrint(
          '⚠️ BackgroundSyncCoordinator: Error recovering interrupted operations: $e');
    }
  }

  /// Requests a synchronization run.
  ///
  /// For high-frequency triggers (like local mutations), applies debouncing.
  /// If another sync cycle is already active, queues a catch-up execution.
  Future<void> requestSync(
    SyncTrigger trigger, {
    Duration debounceDuration = const Duration(milliseconds: 400),
  }) async {
    if (_isDisposed) return;
    if (trigger == SyncTrigger.localMutation) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(debounceDuration, () {
        _dispatchSync(trigger);
      });
      return;
    }

    _debounceTimer?.cancel();
    return _dispatchSync(trigger);
  }

  Future<void> _dispatchSync(SyncTrigger trigger) async {
    if (_isDisposed) return;
    if (_isSyncing) {
      _hasPendingCatchUp = true;
      _pendingCatchUpTrigger = trigger;
      return;
    }

    final cycleGeneration = ++_currentGeneration;
    _isSyncing = true;

    // Resolve bound database for initiating scope
    Database? boundDb;
    if (databaseResolver != null) {
      try {
        boundDb = await databaseResolver!();
      } catch (_) {
        _isSyncing = false;
        return;
      }
    }

    // Re-check generation validity after async DB resolution before token fetch.
    if (cycleGeneration != _currentGeneration || _isDisposed) {
      _isSyncing = false;
      return;
    }

    // Resolve bound auth token for initiating session.
    // FAIL-CLOSED SEMANTICS: if the resolver throws, returns null, or returns an
    // empty string, the cycle MUST stop. A leased sync operation must never fall
    // back to dynamic Hive credential resolution.
    String? boundToken;
    if (tokenResolver != null) {
      try {
        boundToken = await tokenResolver!();
      } catch (_) {
        // Resolver threw — stop the cycle before any HTTP.
        _isSyncing = false;
        return;
      }
      if (boundToken == null || boundToken.isEmpty) {
        // Null or empty credential — stop the cycle before any HTTP.
        _isSyncing = false;
        return;
      }
    }

    // Re-check generation after async credential resolution.
    if (cycleGeneration != _currentGeneration || _isDisposed) {
      _isSyncing = false;
      return;
    }

    // Bind operational sync lease with explicit session credential.
    // BoundCredential.explicit ensures SyncEngine never falls back to Hive.
    final credential = tokenResolver != null
        ? BoundCredential.explicit(boundToken)
        : BoundCredential.absent;
    final lease = SyncLease(
      db: boundDb,
      credential: credential,
      isCancelled: () => cycleGeneration != _currentGeneration || _isDisposed,
    );

    final pendingCount = await _getPendingOutboxCount(executor: boundDb);

    if (cycleGeneration != _currentGeneration || _isDisposed) return;

    _emitState(state.copyWith(
      status: SyncStatus.syncing,
      isSyncing: true,
      lastTrigger: trigger,
      pendingOutboxCount: pendingCount,
    ));

    try {
      if (cycleGeneration != _currentGeneration || _isDisposed) return;

      // 1. Push Phase: process pending Outbox entries
      final pushSummary = await syncEngine.pushPendingOutbox(lease: lease);

      if (cycleGeneration != _currentGeneration || _isDisposed) return;

      // 2. Pull Phase: fetch incremental updates from server
      final pullSummary = await syncEngine.pullIncrementalChanges(lease: lease);

      if (cycleGeneration != _currentGeneration || _isDisposed) return;

      // Determine whether this cycle performed any real work.
      // Push counts as work if at least one entry was processed.
      // Pull counts as work if at least one change was applied.
      lastCycleDidWork =
          pushSummary.totalProcessed > 0 || pullSummary.totalChanges > 0;

      final remainingPending = await _getPendingOutboxCount(executor: boundDb);
      final now = DateTime.now();

      if (cycleGeneration != _currentGeneration || _isDisposed) return;

      _emitState(state.copyWith(
        status: SyncStatus.idle,
        isSyncing: false,
        lastSyncAt: now,
        pendingOutboxCount: remainingPending,
        clearLastError: true,
      ));
    } catch (e) {
      if (cycleGeneration != _currentGeneration || _isDisposed) return;

      debugPrint('❌ BackgroundSyncCoordinator Sync Error: $e');
      lastCycleDidWork = false;
      final remainingPending = await _getPendingOutboxCount(executor: boundDb);

      if (cycleGeneration != _currentGeneration || _isDisposed) return;

      _emitState(state.copyWith(
        status: SyncStatus.error,
        isSyncing: false,
        lastError: e.toString(),
        pendingOutboxCount: remainingPending,
      ));
    } finally {
      if (cycleGeneration == _currentGeneration) {
        _isSyncing = false;

        // Handle catch-up if triggers were enqueued while syncing
        if (_hasPendingCatchUp && !_isDisposed) {
          final nextTrigger =
              _pendingCatchUpTrigger ?? SyncTrigger.scheduledConsolidation;
          _hasPendingCatchUp = false;
          _pendingCatchUpTrigger = null;
          // Run next cycle asynchronously without blocking
          scheduleMicrotask(() => _dispatchSync(nextTrigger));
        }
      }
    }
  }

  Future<int> _getPendingOutboxCount({DatabaseExecutor? executor}) async {
    try {
      DatabaseExecutor? targetExecutor = executor;
      if (targetExecutor == null && databaseResolver != null) {
        targetExecutor = await databaseResolver!();
      }
      return await outboxDao.getPendingCount(executor: targetExecutor);
    } catch (_) {
      return 0;
    }
  }

  Future<void> _refreshPendingCount() async {
    final count = await _getPendingOutboxCount();
    _emitState(state.copyWith(pendingOutboxCount: count));
  }

  void _emitState(SyncState newState) {
    if (_isDisposed) return;
    _stateNotifier.value = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void dispose() {
    _isDisposed = true;
    cancelActiveSync();
    _stateController.close();
    _stateNotifier.dispose();
  }
}
