import 'dart:async';
import 'package:flutter/widgets.dart';
import 'background_sync_coordinator.dart';
import 'sync_trigger.dart';

/// Decides WHEN to request synchronization.
///
/// Responsibilities:
/// - Listens to application lifecycle events (e.g. appResumed);
/// - Schedules periodic synchronization timers;
/// - Schedules periodic consolidation timers;
/// - Dispatches triggers to the BackgroundSyncCoordinator;
/// - Does NOT access HTTP or SQLite directly.
class SyncScheduler with WidgetsBindingObserver {
  final BackgroundSyncCoordinator coordinator;
  final Duration periodicInterval;
  final Duration consolidationInterval;

  Timer? _periodicTimer;
  Timer? _consolidationTimer;
  bool _isStarted = false;

  SyncScheduler({
    required this.coordinator,
    this.periodicInterval = const Duration(seconds: 60),
    this.consolidationInterval = const Duration(minutes: 15),
  });

  /// Starts scheduler timers and registers lifecycle observer.
  void start() {
    if (_isStarted) return;
    _isStarted = true;

    WidgetsBinding.instance.addObserver(this);
    _startTimers();
  }

  /// Stops scheduler timers and removes lifecycle observer.
  void stop() {
    if (!_isStarted) return;
    _isStarted = false;

    WidgetsBinding.instance.removeObserver(this);
    _stopTimers();
  }

  void _startTimers() {
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(periodicInterval, (_) {
      requestSync(SyncTrigger.periodic);
    });

    _consolidationTimer?.cancel();
    _consolidationTimer = Timer.periodic(consolidationInterval, (_) {
      requestSync(SyncTrigger.scheduledConsolidation);
    });
  }

  void _stopTimers() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _consolidationTimer?.cancel();
    _consolidationTimer = null;
  }

  /// Dispatches a sync trigger to the coordinator.
  Future<void> requestSync(SyncTrigger trigger) async {
    await coordinator.requestSync(trigger);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      requestSync(SyncTrigger.appResumed);
    }
  }

  void dispose() {
    stop();
  }
}
