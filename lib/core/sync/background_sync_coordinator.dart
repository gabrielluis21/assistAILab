import 'dart:async';
import 'package:flutter/foundation.dart';
import '../database/outbox_dao.dart';
import 'sync_engine.dart';
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
/// - Expose [lastCycleDidWork] so the Scheduler can make accurate IDLE decisions.
class BackgroundSyncCoordinator {
  final SyncEngine syncEngine;
  final OutboxDao outboxDao;

  final ValueNotifier<SyncState> _stateNotifier =
      ValueNotifier<SyncState>(SyncState.initial());
  final StreamController<SyncState> _stateController =
      StreamController<SyncState>.broadcast();

  bool _isSyncing = false;
  bool _hasPendingCatchUp = false;
  SyncTrigger? _pendingCatchUpTrigger;
  Timer? _debounceTimer;

  /// Whether the last completed sync cycle performed any real work.
  ///
  /// True when at least one Outbox entry was pushed OR at least one remote
  /// change was pulled during the cycle. Used by [SyncScheduler] to decide
  /// whether to increment [consecutiveEmptyCycles].
  bool lastCycleDidWork = false;

  BackgroundSyncCoordinator({
    required this.syncEngine,
    OutboxDao? outboxDao,
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
      final recovered = await outboxDao.recoverProcessingEntries();
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
    if (_isSyncing) {
      _hasPendingCatchUp = true;
      _pendingCatchUpTrigger = trigger;
      return;
    }

    _isSyncing = true;
    final pendingCount = await _getPendingOutboxCount();

    _emitState(state.copyWith(
      status: SyncStatus.syncing,
      isSyncing: true,
      lastTrigger: trigger,
      pendingOutboxCount: pendingCount,
    ));

    try {
      // 1. Push Phase: process pending Outbox entries
      final pushSummary = await syncEngine.pushPendingOutbox();

      // 2. Pull Phase: fetch incremental updates from server
      final pullSummary = await syncEngine.pullIncrementalChanges();

      // Determine whether this cycle performed any real work.
      // Push counts as work if at least one entry was processed.
      // Pull counts as work if at least one change was applied.
      lastCycleDidWork =
          pushSummary.totalProcessed > 0 || pullSummary.totalChanges > 0;

      final remainingPending = await _getPendingOutboxCount();
      final now = DateTime.now();

      _emitState(state.copyWith(
        status: SyncStatus.idle,
        isSyncing: false,
        lastSyncAt: now,
        pendingOutboxCount: remainingPending,
        clearLastError: true,
      ));
    } catch (e) {
      debugPrint('❌ BackgroundSyncCoordinator Sync Error: $e');
      lastCycleDidWork = false;
      final remainingPending = await _getPendingOutboxCount();

      _emitState(state.copyWith(
        status: SyncStatus.error,
        isSyncing: false,
        lastError: e.toString(),
        pendingOutboxCount: remainingPending,
      ));
    } finally {
      _isSyncing = false;

      // Handle catch-up if triggers were enqueued while syncing
      if (_hasPendingCatchUp) {
        final nextTrigger =
            _pendingCatchUpTrigger ?? SyncTrigger.scheduledConsolidation;
        _hasPendingCatchUp = false;
        _pendingCatchUpTrigger = null;
        // Run next cycle asynchronously without blocking
        scheduleMicrotask(() => _dispatchSync(nextTrigger));
      }
    }
  }

  Future<int> _getPendingOutboxCount() async {
    try {
      return await outboxDao.getPendingCount();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _refreshPendingCount() async {
    final count = await _getPendingOutboxCount();
    _emitState(state.copyWith(pendingOutboxCount: count));
  }

  void _emitState(SyncState newState) {
    _stateNotifier.value = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void dispose() {
    _debounceTimer?.cancel();
    _stateController.close();
    _stateNotifier.dispose();
  }
}
