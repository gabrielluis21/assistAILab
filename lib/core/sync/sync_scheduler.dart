import 'dart:async';
import 'package:flutter/widgets.dart';
import 'background_sync_coordinator.dart';
import 'sync_trigger.dart';

/// Cadence of the adaptive synchronization scheduler.
enum SyncCadence {
  hot(Duration(seconds: 15)),
  normal(Duration(seconds: 45)),
  idle(Duration(minutes: 3));

  final Duration interval;
  const SyncCadence(this.interval);
}

/// Decides WHEN to request synchronization using an adaptive scheduler.
///
/// Cadence rules:
/// - HOT (15s): Pending Outbox entries or recent local mutation.
/// - NORMAL (45s): Active normal operation with periodic checks.
/// - IDLE (3min): After consecutive empty cycles without changes.
/// - Any local mutation immediately resets cadence to HOT and triggers sync.
class SyncScheduler with WidgetsBindingObserver {
  final BackgroundSyncCoordinator coordinator;

  SyncCadence _currentCadence = SyncCadence.normal;
  int _consecutiveEmptyCycles = 0;
  Timer? _adaptiveTimer;
  bool _isStarted = false;

  SyncScheduler({
    required this.coordinator,
  });

  SyncCadence get currentCadence => _currentCadence;
  int get consecutiveEmptyCycles => _consecutiveEmptyCycles;

  /// Starts adaptive scheduler timer and registers lifecycle observer.
  void start() {
    if (_isStarted) return;
    _isStarted = true;

    WidgetsBinding.instance.addObserver(this);
    _scheduleNextTick();
  }

  /// Stops adaptive scheduler and removes lifecycle observer.
  void stop() {
    if (!_isStarted) return;
    _isStarted = false;

    WidgetsBinding.instance.removeObserver(this);
    _adaptiveTimer?.cancel();
    _adaptiveTimer = null;
  }

  void _scheduleNextTick() {
    _adaptiveTimer?.cancel();
    if (!_isStarted) return;

    _adaptiveTimer = Timer(_currentCadence.interval, _onAdaptiveTick);
  }

  Future<void> _onAdaptiveTick() async {
    if (!_isStarted) return;

    await coordinator.requestSync(SyncTrigger.periodic);

    // Evaluate state after cycle to adapt cadence.
    // Only count a cycle as "empty" (eligible for IDLE promotion) when:
    //   push = 0 AND pull = 0 AND pendingOutbox = 0.
    final state = coordinator.state;
    if (state.hasPendingMutations) {
      // Still has pending work — stay HOT.
      _currentCadence = SyncCadence.hot;
      _consecutiveEmptyCycles = 0;
    } else if (!coordinator.lastCycleDidWork && state.isHealthy) {
      // No push, no pull, nothing pending: genuinely idle cycle.
      _consecutiveEmptyCycles++;
      if (_consecutiveEmptyCycles >= 3) {
        _currentCadence = SyncCadence.idle;
      } else {
        _currentCadence = SyncCadence.normal;
      }
    } else {
      // Cycle did real work (push or pull) but outbox is clear — stay NORMAL.
      _consecutiveEmptyCycles = 0;
      _currentCadence = SyncCadence.normal;
    }

    _scheduleNextTick();
  }

  /// Dispatches a sync trigger to the coordinator.
  ///
  /// Local mutations immediately exit IDLE mode and set cadence to HOT.
  Future<void> requestSync(SyncTrigger trigger) async {
    if (trigger == SyncTrigger.localMutation) {
      _currentCadence = SyncCadence.hot;
      _consecutiveEmptyCycles = 0;
      _scheduleNextTick();
    }
    await coordinator.requestSync(trigger);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _currentCadence = SyncCadence.normal;
      _consecutiveEmptyCycles = 0;
      _scheduleNextTick();
      requestSync(SyncTrigger.appResumed);
    }
  }

  void dispose() {
    stop();
  }
}
