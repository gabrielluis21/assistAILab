import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';
import '../../features/auth/application/auth_provider.dart';
import '../../features/auth/domain/entities/auth_scope.dart';
import '../database/auth_scoped_database_manager.dart';
import '../database/outbox_dao.dart';
import 'background_sync_coordinator.dart';
import 'sync_engine.dart';
import 'sync_scheduler.dart';
import 'sync_state.dart';
import 'sync_trigger.dart';

/// Provider for active scoped SQLite database.
final scopedDatabaseProvider = FutureProvider<Database?>((ref) async {
  final scope = ref.watch(authScopeProvider);
  if (kIsWeb || scope == null || scope is InvalidAuthScope) {
    await AuthScopedDatabaseManager.instance.closeCurrentDatabase();
    return null;
  }
  return await AuthScopedDatabaseManager.instance.openDatabaseForScope(scope);
});

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
  // Invalidate and recreate coordinator when auth scope changes to isolate sync state per scope.
  ref.watch(authScopeProvider);
  final syncEngine = ref.watch(syncEngineProvider);
  final outboxDao = ref.watch(outboxDaoProvider);

  final coordinator = BackgroundSyncCoordinator(
    syncEngine: syncEngine,
    outboxDao: outboxDao,
  );

  ref.onDispose(() {
    coordinator.dispose();
  });

  return coordinator;
});

/// Provider for SyncScheduler.
final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  final coordinator = ref.watch(backgroundSyncCoordinatorProvider);
  final scheduler = SyncScheduler(coordinator: coordinator);

  // Listen to auth scope state to manage database opening and sync lifecycle
  ref.listen<AuthScope?>(authScopeProvider, (previous, nextScope) async {
    if (kIsWeb) return;

    // Invalidate any in-flight sync operations from previous scope immediately
    coordinator.cancelActiveSync();

    if (nextScope is ProfessionalAuthScope || nextScope is CustomerAuthScope) {
      try {
        await AuthScopedDatabaseManager.instance
            .openDatabaseForScope(nextScope);
        await coordinator.initialize();
        scheduler.start();
        scheduler.requestSync(SyncTrigger.authenticated);
      } catch (_) {
        scheduler.stop();
      }
    } else {
      // InvalidAuthScope or null unauthenticated: fail closed
      scheduler.stop();
      await AuthScopedDatabaseManager.instance.closeCurrentDatabase();
    }
  }, fireImmediately: true);

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
