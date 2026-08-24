import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/application/auth_provider.dart';
import '../database/outbox_dao.dart';
import 'background_sync_coordinator.dart';
import 'sync_engine.dart';
import 'sync_scheduler.dart';
import 'sync_state.dart';
import 'sync_trigger.dart';

/// Provider for OutboxDao.
final outboxDaoProvider = Provider<OutboxDao>((ref) {
  return OutboxDao();
});

/// Provider for SyncEngine.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final outboxDao = ref.watch(outboxDaoProvider);
  return SyncEngine(apiClient: apiClient, outboxDao: outboxDao);
});

/// Provider for BackgroundSyncCoordinator.
final backgroundSyncCoordinatorProvider =
    Provider<BackgroundSyncCoordinator>((ref) {
  final syncEngine = ref.watch(syncEngineProvider);
  final outboxDao = ref.watch(outboxDaoProvider);

  final coordinator = BackgroundSyncCoordinator(
    syncEngine: syncEngine,
    outboxDao: outboxDao,
  );

  // Initialize and recover interrupted operations asynchronously
  coordinator.initialize();

  ref.onDispose(() {
    coordinator.dispose();
  });

  return coordinator;
});

/// Provider for SyncScheduler.
final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  final coordinator = ref.watch(backgroundSyncCoordinatorProvider);
  final scheduler = SyncScheduler(coordinator: coordinator);

  scheduler.start();

  // Listen to auth state to trigger sync on authentication
  ref.listen(authStateProvider, (previous, next) {
    next.whenData((user) {
      if (user != null) {
        scheduler.requestSync(SyncTrigger.authenticated);
      }
    });
  });

  ref.onDispose(() {
    scheduler.dispose();
  });

  return scheduler;
});

/// Reactive StateNotifier for UI consumption of SyncState.
class SyncStateNotifier extends StateNotifier<SyncState> {
  final BackgroundSyncCoordinator _coordinator;

  SyncStateNotifier(this._coordinator) : super(_coordinator.state) {
    _coordinator.stateListenable.addListener(_onStateChanged);
  }

  void _onStateChanged() {
    state = _coordinator.state;
  }

  @override
  void dispose() {
    _coordinator.stateListenable.removeListener(_onStateChanged);
    super.dispose();
  }
}

/// Provider for reactive SyncState.
final syncStateProvider =
    StateNotifierProvider<SyncStateNotifier, SyncState>((ref) {
  final coordinator = ref.watch(backgroundSyncCoordinatorProvider);
  // Ensure scheduler is active whenever state is consumed
  ref.watch(syncSchedulerProvider);
  return SyncStateNotifier(coordinator);
});
