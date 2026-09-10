import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_provider.dart';
import '../../features/auth/domain/entities/session_state.dart';
import '../database/auth_scoped_database_manager.dart';
import '../database/outbox_dao.dart';
import 'background_sync_coordinator.dart';
import 'sync_engine.dart';
import 'sync_scheduler.dart';
import 'sync_state.dart';
import 'sync_trigger.dart';

/// Read-only projection of the database handle already activated by the
/// authoritative AuthNotifier lifecycle. This provider never opens a global or
/// unbound database as a fallback.
final scopedDatabaseProvider = Provider<BoundDatabaseHandle?>((ref) {
  if (kIsWeb) return null;
  final session = ref.watch(authStateProvider);
  if (session is! AuthenticatedSession) return null;

  final handle = AuthScopedDatabaseManager.instance.currentHandle;
  if (handle == null ||
      handle.authScope != session.scope ||
      handle.sessionGeneration != session.generation ||
      !AuthScopedDatabaseManager.instance.isCurrentHandle(handle)) {
    return null;
  }
  return handle;
});

final outboxDaoProvider = Provider<OutboxDao>((ref) => OutboxDao());

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    apiClient: ref.watch(apiClientProvider),
    outboxDao: ref.watch(outboxDaoProvider),
  );
});

/// A coordinator is recreated for every explicit SessionState transition.
/// Only AuthenticatedOnline receives a complete pre-lease binding.
final backgroundSyncCoordinatorProvider =
    Provider<BackgroundSyncCoordinator>((ref) {
  final session = ref.watch(authStateProvider);
  final authNotifier = ref.read(authStateProvider.notifier);
  final manager = AuthScopedDatabaseManager.instance;

  SyncSessionBinding? binding;
  if (session is AuthenticatedOnline && !kIsWeb) {
    final scope = session.scope;
    final generation = session.generation;
    binding = SyncSessionBinding(
      scope: scope,
      sessionGeneration: generation,
      resolveBoundHandle: () async {
        final handle = manager.currentHandle;
        if (handle == null ||
            handle.authScope != scope ||
            handle.sessionGeneration != generation ||
            !manager.isCurrentHandle(handle)) {
          return null;
        }
        return handle;
      },
      isHandleCurrent: (handle) =>
          handle.authScope == scope &&
          handle.sessionGeneration == generation &&
          manager.isCurrentHandle(handle),
      resolveToken: () async {
        final request = await authNotifier.acquireOnlineRequestCredential();
        if (request.sessionGeneration != generation) return null;
        return request.accessToken;
      },
      isCurrentOnline: () => authNotifier.isCurrentOnlineGeneration(generation),
      isAuthHttpGenerationCurrent: authNotifier.isGenerationCurrent,
      onAuthorizationFailure: ({
        required sessionGeneration,
        required statusCode,
        required authorityRevalidation,
      }) {
        return authNotifier.handleAuthorizationFailure(
          sessionGeneration: sessionGeneration,
          statusCode: statusCode,
          authorityRevalidation: authorityRevalidation,
        );
      },
    );
  }

  final coordinator = BackgroundSyncCoordinator(
    syncEngine: ref.watch(syncEngineProvider),
    outboxDao: ref.watch(outboxDaoProvider),
    sessionBinding: binding,
  );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});

final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  final session = ref.watch(authStateProvider);
  final authNotifier = ref.read(authStateProvider.notifier);
  final coordinator = ref.watch(backgroundSyncCoordinatorProvider);
  final scheduler = SyncScheduler(coordinator: coordinator);
  var disposed = false;

  if (session is AuthenticatedOnline && !kIsWeb) {
    final generation = session.generation;
    unawaited(() async {
      await coordinator.initialize();
      if (disposed ||
          !authNotifier.isCurrentOnlineGeneration(generation) ||
          coordinator.sessionBinding?.sessionGeneration != generation) {
        return;
      }

      final handle = AuthScopedDatabaseManager.instance.currentHandle;
      if (handle == null ||
          handle.authScope != session.scope ||
          handle.sessionGeneration != generation ||
          !AuthScopedDatabaseManager.instance.isCurrentHandle(handle)) {
        return;
      }

      scheduler.start();
      await scheduler.requestSync(SyncTrigger.authenticated);
    }());
  }

  ref.onDispose(() {
    disposed = true;
    coordinator.cancelActiveSync();
    scheduler.dispose();
  });
  return scheduler;
});

class SyncStateNotifier extends StateNotifier<SyncState> {
  SyncStateNotifier(this._coordinator) : super(_coordinator.state) {
    _coordinator.stateListenable.addListener(_onStateChanged);
  }

  final BackgroundSyncCoordinator _coordinator;

  void _onStateChanged() {
    state = _coordinator.state;
  }

  @override
  void dispose() {
    _coordinator.stateListenable.removeListener(_onStateChanged);
    super.dispose();
  }
}

final syncStateProvider =
    StateNotifierProvider<SyncStateNotifier, SyncState>((ref) {
  final coordinator = ref.watch(backgroundSyncCoordinatorProvider);
  ref.watch(syncSchedulerProvider);
  return SyncStateNotifier(coordinator);
});
