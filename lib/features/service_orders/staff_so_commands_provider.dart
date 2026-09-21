import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/commands/command_intent.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../../core/database/service_order_repository.dart';
import '../auth/application/auth_provider.dart';
import '../auth/application/session_api_client.dart';
import '../auth/domain/entities/session_state.dart';
import 'service_order_entity.dart';
import 'service_orders_provider.dart';
import 'staff_so_command_executor.dart';
import 'staff_so_command_gateway.dart';

// ---------------------------------------------------------------------------
// Binding type alias (session + database handle captured together)
// ---------------------------------------------------------------------------

typedef _StaffSoBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
});

// ---------------------------------------------------------------------------
// Riverpod infrastructure providers
// ---------------------------------------------------------------------------

final staffSoCommandGatewayProvider = Provider<StaffSoCommandGateway>(
  (ref) => StaffSoHttpCommandGateway(ref.watch(sessionApiClientProvider)),
);

final staffSoCommandIntentRepositoryProvider =
    Provider<CommandIntentRepository>(
  (ref) => CommandIntentLocalDataSource(),
);

final staffSoOperationIdFactoryProvider = Provider<String Function()>(
  (ref) => const Uuid().v4,
);

final staffSoDatabaseManagerProvider = Provider<AuthScopedDatabaseManager>(
  (ref) => AuthScopedDatabaseManager.instance,
);

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

/// Staff-side Service Order command notifier.
///
/// Exposes all protected SO mutations available to ADMIN / TECHNICIAN users.
/// Wraps [StaffSoCommandIntentExecutor] with:
///
/// - **Session binding guard** — each operation captures the session at call
///   time and refuses to commit responses that arrive after a logout or
///   session rotation.
/// - **Interrupted-sending recovery** — on boot, any SO intents that were
///   stuck in SENDING (e.g. app crash during a network request) are promoted
///   to UNKNOWN so they can be replayed on next user action.
/// - **Authoritative list refresh** — after every successful command the
///   provider reloads the list from the gateway (online) or local DB
///   (offline), then invalidates [serviceOrdersProvider] so other UI
///   subscribers stay in sync.
class StaffSoCommandsNotifier
    extends AutoDisposeAsyncNotifier<List<ServiceOrderEntity>> {
  @override
  Future<List<ServiceOrderEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    ref.watch(isOnlineSessionProvider);
    final binding = _captureBinding(sessionKey);
    _ensureBindingCurrent(binding);
    await ref
        .read(staffSoCommandIntentRepositoryProvider)
        .recoverInterruptedSending(
          ownedCommandTypes: staffSoOwnedCommandTypes,
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
    return _loadFromRepository(binding);
  }

  // ── public command surface ───────────────────────────────────────────────

  Future<ServiceOrderEntity> updateStatus({
    required String serviceOrderId,
    required ServiceOrderStatusEnum status,
  }) async {
    return _runCommand(
      (executor) => executor.updateStatus(
        serviceOrderId: serviceOrderId,
        status: status,
      ),
    );
  }

  Future<ServiceOrderEntity> publishInitialQuote({
    required String serviceOrderId,
    String? changeReason,
  }) async {
    return _runCommand(
      (executor) => executor.publishInitialQuote(
        serviceOrderId: serviceOrderId,
        changeReason: changeReason,
      ),
    );
  }

  Future<ServiceOrderEntity> publishCommercialRevision({
    required String serviceOrderId,
    String? changeReason,
  }) async {
    return _runCommand(
      (executor) => executor.publishCommercialRevision(
        serviceOrderId: serviceOrderId,
        changeReason: changeReason,
      ),
    );
  }

  Future<ServiceOrderEntity> resumeApprovedScope({
    required String serviceOrderId,
  }) async {
    return _runCommand(
      (executor) => executor.resumeApprovedScope(
        serviceOrderId: serviceOrderId,
      ),
    );
  }

  Future<ServiceOrderEntity> markReady({
    required String serviceOrderId,
    String? notes,
  }) async {
    return _runCommand(
      (executor) => executor.markReady(
        serviceOrderId: serviceOrderId,
        notes: notes,
      ),
    );
  }

  Future<ServiceOrderEntity> markDelivered({
    required String serviceOrderId,
  }) async {
    return _runCommand(
      (executor) => executor.markDelivered(
        serviceOrderId: serviceOrderId,
      ),
    );
  }

  Future<ServiceOrderEntity> recordNotApproved({
    required String serviceOrderId,
  }) async {
    return _runCommand(
      (executor) => executor.recordNotApproved(
        serviceOrderId: serviceOrderId,
      ),
    );
  }

  // ── shared command runner ────────────────────────────────────────────────

  Future<ServiceOrderEntity> _runCommand(
    Future<ServiceOrderEntity> Function(StaffSoCommandIntentExecutor) fn,
  ) async {
    final binding = _captureBinding(ref.read(authenticatedSessionKeyProvider));
    final result = await fn(_executor(binding));
    _ensureBindingCurrent(binding);
    final orders = await _loadFromRepository(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(orders);
    // Notify the general list provider so other screens stay in sync.
    ref.invalidate(serviceOrdersProvider);
    return result;
  }

  // ── local list load ──────────────────────────────────────────────────────

  Future<List<ServiceOrderEntity>> _loadFromRepository(
    _StaffSoBinding binding,
  ) async {
    final repo = ref.read(staffSoServiceOrderRepositoryProvider);
    final orders = await repo.listAll(
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    return orders;
  }

  // ── executor factory ─────────────────────────────────────────────────────

  StaffSoCommandIntentExecutor _executor(_StaffSoBinding binding) {
    return StaffSoCommandIntentExecutor(
      gateway: ref.read(staffSoCommandGatewayProvider),
      serviceOrderRepository: ref.read(staffSoServiceOrderRepositoryProvider),
      intentRepository: ref.read(staffSoCommandIntentRepositoryProvider),
      database: binding.databaseHandle.database,
      isBindingCurrent: () => _isBindingCurrent(binding),
      operationIdFactory: ref.read(staffSoOperationIdFactoryProvider),
    );
  }

  // ── session binding helpers ──────────────────────────────────────────────

  _StaffSoBinding _captureBinding(AuthenticatedSessionKey? sessionKey) {
    if (sessionKey == null) {
      throw StateError(
        'An authenticated session is required for staff SO commands.',
      );
    }
    final manager = ref.read(staffSoDatabaseManagerProvider);
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated staff SO session.',
      );
    }
    return (sessionKey: sessionKey, databaseHandle: handle);
  }

  bool _isBindingCurrent(_StaffSoBinding binding) {
    final manager = ref.read(staffSoDatabaseManagerProvider);
    return ref.read(authenticatedSessionKeyProvider) == binding.sessionKey &&
        binding.databaseHandle.authScope == binding.sessionKey.scope &&
        binding.databaseHandle.sessionGeneration ==
            binding.sessionKey.sessionGeneration &&
        manager.isCurrentHandle(binding.databaseHandle);
  }

  void _ensureBindingCurrent(_StaffSoBinding binding) {
    if (!_isBindingCurrent(binding)) {
      throw StateError(
        'The staff SO command belongs to a stale authenticated session.',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Exposes the current session's service order list as managed by the staff
/// command notifier.  Consumers call `.notifier` to dispatch mutations.
final staffSoCommandsProvider = AutoDisposeAsyncNotifierProvider<
    StaffSoCommandsNotifier, List<ServiceOrderEntity>>(
  StaffSoCommandsNotifier.new,
);

/// Dedicated repository provider so the staff commands layer can share the
/// same [ServiceOrderLocalDataSource] instance without coupling itself to the
/// older [serviceOrderRepositoryProvider].
final staffSoServiceOrderRepositoryProvider =
    Provider<ServiceOrderRepository>(
  (ref) => ServiceOrderLocalDataSource(),
);
