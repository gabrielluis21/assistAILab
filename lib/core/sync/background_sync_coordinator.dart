import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../features/auth/domain/entities/auth_scope.dart';
import '../database/auth_scoped_database_manager.dart';
import '../database/outbox_dao.dart';
import 'sync_engine.dart';
import 'sync_lease.dart';
import 'sync_state.dart';
import 'sync_trigger.dart';

typedef BoundDatabaseHandleResolver = Future<BoundDatabaseHandle?> Function();
typedef BoundDatabaseHandleValidator = bool Function(
  BoundDatabaseHandle handle,
);
typedef BoundTokenResolver = Future<String?> Function();
typedef CurrentOnlinePredicate = bool Function();
typedef AuthHttpGenerationPredicate = bool Function(int sessionGeneration);
typedef SyncAuthorizationFailureHandler = FutureOr<void> Function({
  required int sessionGeneration,
  required int statusCode,
  required bool authorityRevalidation,
});

/// Complete proof needed to start authenticated synchronization for a session.
///
/// The binding is immutable. Its callbacks must resolve and validate state only
/// for [scope] and [sessionGeneration], never whichever session happens to be
/// globally active when a callback runs.
final class SyncSessionBinding {
  final AuthScope scope;
  final int sessionGeneration;
  final BoundDatabaseHandleResolver resolveBoundHandle;
  final BoundDatabaseHandleValidator isHandleCurrent;
  final BoundTokenResolver resolveToken;
  final CurrentOnlinePredicate isCurrentOnline;
  final AuthHttpGenerationPredicate isAuthHttpGenerationCurrent;
  final SyncAuthorizationFailureHandler onAuthorizationFailure;

  const SyncSessionBinding({
    required this.scope,
    required this.sessionGeneration,
    required this.resolveBoundHandle,
    required this.isHandleCurrent,
    required this.resolveToken,
    required this.isCurrentOnline,
    required this.isAuthHttpGenerationCurrent,
    required this.onAuthorizationFailure,
  });
}

/// Coordinator for Background Synchronization.
///
/// A cycle is allowed to touch the Outbox or authenticated HTTP only after a
/// complete [SyncSessionBinding] proves its scope, session generation, online
/// authority and current database handle. Missing or stale proof fails closed.
class BackgroundSyncCoordinator {
  final SyncEngine syncEngine;
  final OutboxDao outboxDao;
  final SyncSessionBinding? sessionBinding;

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

  /// Whether the last completed sync cycle performed any real work.
  bool lastCycleDidWork = false;

  BackgroundSyncCoordinator({
    required this.syncEngine,
    OutboxDao? outboxDao,
    this.sessionBinding,
    @Deprecated(
      'Use sessionBinding. Legacy resolvers do not provide scope/generation proof and are ignored.',
    )
    Future<Database?> Function()? databaseResolver,
    @Deprecated(
      'Use sessionBinding. Legacy resolvers do not provide scope/generation proof and are ignored.',
    )
    Future<String?> Function()? tokenResolver,
  }) : outboxDao = outboxDao ?? OutboxDao();

  /// Cancels any active or scheduled sync cycle.
  void cancelActiveSync() {
    _currentGeneration++;
    _isSyncing = false;
    _hasPendingCatchUp = false;
    _pendingCatchUpTrigger = null;
    _debounceTimer?.cancel();
  }

  /// Current synchronization state snapshot.
  SyncState get state => _stateNotifier.value;

  /// ValueListenable for UI components to listen directly.
  ValueListenable<SyncState> get stateListenable => _stateNotifier;

  /// Stream of synchronization state transitions.
  Stream<SyncState> get stateStream => _stateController.stream;

  bool _isInitialized = false;
  Future<bool>? _initFuture;

  /// Initializes coordinator and recovers interrupted operations for the bound
  /// session. A missing/stale binding performs no database access and remains
  /// retryable rather than becoming initialized.
  Future<void> initialize() async {
    if (_isInitialized || _isDisposed) return;
    final existing = _initFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = _performInitialization();
    _initFuture = future;
    try {
      final initialized = await future;
      if (initialized && !_isDisposed) {
        _isInitialized = true;
      }
    } finally {
      if (identical(_initFuture, future)) {
        _initFuture = null;
      }
    }
  }

  Future<bool> _performInitialization() async {
    final operationGeneration = _currentGeneration;
    final handle = await _resolveCurrentHandle(operationGeneration);
    if (handle == null) return false;

    await _recoverInterruptedOperations(
      handle: handle,
      operationGeneration: operationGeneration,
    );
    if (!_isBoundContextCurrent(operationGeneration, handle)) return false;

    final count = await _getPendingOutboxCount(
      handle: handle,
      operationGeneration: operationGeneration,
    );
    if (!_isBoundContextCurrent(operationGeneration, handle)) return false;

    _emitState(state.copyWith(pendingOutboxCount: count));
    return true;
  }

  /// Recovers stale PROCESSING rows only in the explicitly bound database.
  Future<void> recoverInterruptedOperations() async {
    final operationGeneration = _currentGeneration;
    final handle = await _resolveCurrentHandle(operationGeneration);
    if (handle == null) return;
    await _recoverInterruptedOperations(
      handle: handle,
      operationGeneration: operationGeneration,
    );
  }

  Future<void> _recoverInterruptedOperations({
    required BoundDatabaseHandle handle,
    required int operationGeneration,
  }) async {
    if (!_isBoundContextCurrent(operationGeneration, handle)) return;
    try {
      final recovered = await outboxDao.recoverProcessingEntries(
        executor: handle.database,
      );
      if (!_isBoundContextCurrent(operationGeneration, handle)) return;
      if (recovered > 0) {
        debugPrint(
          'BackgroundSyncCoordinator: Recovered $recovered stale PROCESSING entries to FAILED.',
        );
      }
    } catch (error) {
      debugPrint(
        'BackgroundSyncCoordinator: Error recovering interrupted operations: $error',
      );
    }
  }

  /// Requests a synchronization run.
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
    lastCycleDidWork = false;

    final binding = sessionBinding;
    if (binding == null) {
      _finishUnstartedCycle(cycleGeneration);
      return;
    }

    final handle = await _resolveCurrentHandle(cycleGeneration);
    if (handle == null) {
      _finishUnstartedCycle(cycleGeneration);
      return;
    }

    String? token;
    try {
      token = await binding.resolveToken();
    } catch (_) {
      _finishUnstartedCycle(cycleGeneration);
      return;
    }

    // Re-prove the full session after credential resolution. This prevents a
    // resolver started by A from consuming the token installed later by B.
    if (!_isBoundContextCurrent(cycleGeneration, handle) ||
        token == null ||
        token.trim().isEmpty) {
      _finishUnstartedCycle(cycleGeneration);
      return;
    }

    final lease = SyncLease(
      db: handle.database,
      credential: BoundCredential.explicit(token),
      isCancelled: () => !_isBoundContextCurrent(cycleGeneration, handle),
    );

    final pendingCount = await _getPendingOutboxCount(
      handle: handle,
      operationGeneration: cycleGeneration,
    );
    if (!lease.isStillValid) {
      _finishUnstartedCycle(cycleGeneration);
      return;
    }

    _emitState(state.copyWith(
      status: SyncStatus.syncing,
      isSyncing: true,
      lastTrigger: trigger,
      pendingOutboxCount: pendingCount,
    ));

    try {
      if (!lease.isStillValid) return;

      final pushSummary = await syncEngine.pushPendingOutbox(lease: lease);
      if (!lease.isStillValid) return;

      final pullSummary = await syncEngine.pullIncrementalChanges(lease: lease);
      if (!lease.isStillValid) return;

      lastCycleDidWork =
          pushSummary.totalProcessed > 0 || pullSummary.totalChanges > 0;

      final remainingPending = await _getPendingOutboxCount(
        handle: handle,
        operationGeneration: cycleGeneration,
      );
      if (!lease.isStillValid) return;

      _emitState(state.copyWith(
        status: SyncStatus.idle,
        isSyncing: false,
        lastSyncAt: DateTime.now(),
        pendingOutboxCount: remainingPending,
        clearLastError: true,
      ));
    } catch (error) {
      if (!lease.isStillValid) return;

      // Only a 401 from the still-current, generation-bound Sync request may
      // terminate the session. Resource 403 is intentionally not global auth
      // failure, and stale HTTP completions are discarded by the lease gate.
      if (error is SyncHttpException && error.statusCode == 401) {
        await binding.onAuthorizationFailure(
          sessionGeneration: binding.sessionGeneration,
          statusCode: error.statusCode,
          authorityRevalidation: false,
        );
        if (!lease.isStillValid) return;
      }

      debugPrint('BackgroundSyncCoordinator Sync Error: $error');
      lastCycleDidWork = false;
      final remainingPending = await _getPendingOutboxCount(
        handle: handle,
        operationGeneration: cycleGeneration,
      );
      if (!lease.isStillValid) return;

      _emitState(state.copyWith(
        status: SyncStatus.error,
        isSyncing: false,
        lastError: error.toString(),
        pendingOutboxCount: remainingPending,
      ));
    } finally {
      if (cycleGeneration == _currentGeneration) {
        _isSyncing = false;
        if (_hasPendingCatchUp && !_isDisposed) {
          final nextTrigger =
              _pendingCatchUpTrigger ?? SyncTrigger.scheduledConsolidation;
          _hasPendingCatchUp = false;
          _pendingCatchUpTrigger = null;
          scheduleMicrotask(() => _dispatchSync(nextTrigger));
        }
      }
    }
  }

  Future<BoundDatabaseHandle?> _resolveCurrentHandle(
    int operationGeneration,
  ) async {
    final binding = sessionBinding;
    if (binding == null ||
        !_isCoordinatorGenerationCurrent(operationGeneration) ||
        !_isBindingAuthorityCurrent(binding)) {
      return null;
    }

    BoundDatabaseHandle? handle;
    try {
      handle = await binding.resolveBoundHandle();
    } catch (_) {
      return null;
    }

    if (handle == null ||
        !_isCoordinatorGenerationCurrent(operationGeneration) ||
        !_isBindingAuthorityCurrent(binding) ||
        !_isHandleProofCurrent(binding, handle)) {
      return null;
    }
    return handle;
  }

  bool _isCoordinatorGenerationCurrent(int operationGeneration) =>
      !_isDisposed && operationGeneration == _currentGeneration;

  bool _isBindingAuthorityCurrent(SyncSessionBinding binding) {
    try {
      return binding.isCurrentOnline() &&
          binding.isAuthHttpGenerationCurrent(binding.sessionGeneration);
    } catch (_) {
      return false;
    }
  }

  bool _isHandleProofCurrent(
    SyncSessionBinding binding,
    BoundDatabaseHandle handle,
  ) {
    if (handle.authScope != binding.scope ||
        handle.sessionGeneration != binding.sessionGeneration ||
        !handle.database.isOpen) {
      return false;
    }
    try {
      return binding.isHandleCurrent(handle);
    } catch (_) {
      return false;
    }
  }

  bool _isBoundContextCurrent(
    int operationGeneration,
    BoundDatabaseHandle handle,
  ) {
    final binding = sessionBinding;
    return binding != null &&
        _isCoordinatorGenerationCurrent(operationGeneration) &&
        _isBindingAuthorityCurrent(binding) &&
        _isHandleProofCurrent(binding, handle);
  }

  Future<int> _getPendingOutboxCount({
    required BoundDatabaseHandle handle,
    required int operationGeneration,
  }) async {
    if (!_isBoundContextCurrent(operationGeneration, handle)) return 0;
    try {
      final count = await outboxDao.getPendingCount(executor: handle.database);
      return _isBoundContextCurrent(operationGeneration, handle) ? count : 0;
    } catch (_) {
      return 0;
    }
  }

  void _finishUnstartedCycle(int cycleGeneration) {
    if (cycleGeneration == _currentGeneration) {
      _isSyncing = false;
    }
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
