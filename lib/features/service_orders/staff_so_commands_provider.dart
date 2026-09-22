import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/commands/command_intent.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../auth/application/auth_provider.dart';
import '../auth/application/session_api_client.dart';
import '../auth/domain/entities/auth_scope.dart';
import '../auth/domain/entities/session_state.dart';
import 'service_orders_provider.dart';
import 'staff_so_command_executor.dart';
import 'staff_so_command_gateway.dart';

export 'staff_so_command_executor.dart'
    show
        StaffSoCommandIdentity,
        StaffSoCommandIntentExecutor,
        StaffSoMarkDeliveredIdentity,
        StaffSoMarkReadyIdentity,
        StaffSoProjectionUncertaintyException,
        StaffSoPublishQuoteIdentity,
        StaffSoResumeScopeIdentity,
        StaffSoReviseQuoteIdentity,
        staffSoMarkDeliveredCommandType,
        staffSoMarkReadyCommandType,
        staffSoOwnedCommandTypes,
        staffSoQuotePublishCommandType,
        staffSoQuoteReviseCommandType,
        staffSoResumeApprovedScopeCommandType;
export 'staff_so_command_gateway.dart'
    show
        StaffServiceOrderProjection,
        StaffSoCommandException,
        StaffSoCommandGateway,
        StaffSoHttpCommandGateway,
        StaffSoQuoteRevisionItem,
        normalizeDiagnosis,
        normalizeNotes,
        normalizeReason;

// ---------------------------------------------------------------------------
// Binding type alias (session + professional scope + database handle)
// ---------------------------------------------------------------------------

typedef _StaffSoBinding = ({
  AuthenticatedSessionKey sessionKey,
  ProfessionalAuthScope scope,
  BoundDatabaseHandle databaseHandle,
});

// ---------------------------------------------------------------------------
// Infrastructure providers
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
// Stable Professional Recovery Owner Notifier (NOT auto-dispose!)
// ---------------------------------------------------------------------------

class StaffSoCommandsNotifier extends AsyncNotifier<void> {
  bool _isInFlight = false;

  @override
  Future<void> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    _ensureBindingCurrent(binding);
    await ref
        .read(staffSoCommandIntentRepositoryProvider)
        .recoverInterruptedSending(
          ownedCommandTypes: staffSoOwnedCommandTypes,
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
  }

  // ── 5 Cyber-approved mutation commands ───────────────────────────────────

  Future<StaffServiceOrderProjection> publishInitialQuote({
    required String serviceOrderId,
    String? changeReason,
  }) async {
    return _executeWithIdentityResolution(
      commandType: staffSoQuotePublishCommandType,
      serviceOrderId: serviceOrderId,
      resolveIdentity: (unresolved) {
        final normalizedReason = normalizeReason(changeReason);
        final matching = <({
          CommandIntent intent,
          StaffSoPublishQuoteIdentity identity,
        })>[];
        for (final intent in unresolved) {
          final identity = StaffSoPublishQuoteIdentity.fromIntent(intent);
          if (identity.matchesRequestedAction(
            requestedChangeReason: normalizedReason,
          )) {
            matching.add((intent: intent, identity: identity));
          }
        }
        if (matching.length > 1) {
          throw StateError('Ambiguous unresolved STAFF command intent.');
        }
        if (matching.length == 1) {
          final replay = matching.single;
          if (replay.intent.lifecycle == CommandIntentLifecycle.sending) {
            throw StateError('A matching STAFF command is in flight.');
          }
          return replay.identity;
        }
        return StaffSoPublishQuoteIdentity(
          serviceOrderId: serviceOrderId,
          changeReason: normalizedReason,
        );
      },
    );
  }

  Future<StaffServiceOrderProjection> publishCommercialRevision({
    required String serviceOrderId,
    required String? diagnosis,
    required List<StaffSoQuoteRevisionItem> items,
    required String changeReason,
  }) async {
    return _executeWithIdentityResolution(
      commandType: staffSoQuoteReviseCommandType,
      serviceOrderId: serviceOrderId,
      resolveIdentity: (unresolved) {
        final normalizedDiagnosis = normalizeDiagnosis(diagnosis);
        final normalizedReason = normalizeReason(changeReason);
        if (normalizedReason == null) {
          throw ArgumentError.value(
            changeReason,
            'changeReason',
            'changeReason is required for quote revision.',
          );
        }
        final matching = <({
          CommandIntent intent,
          StaffSoReviseQuoteIdentity identity,
        })>[];
        for (final intent in unresolved) {
          final identity = StaffSoReviseQuoteIdentity.fromIntent(intent);
          if (identity.matchesRequestedAction(
            requestedDiagnosis: normalizedDiagnosis,
            requestedItems: items,
            requestedChangeReason: normalizedReason,
          )) {
            matching.add((intent: intent, identity: identity));
          }
        }
        if (matching.length > 1) {
          throw StateError('Ambiguous unresolved STAFF command intent.');
        }
        if (matching.length == 1) {
          final replay = matching.single;
          if (replay.intent.lifecycle == CommandIntentLifecycle.sending) {
            throw StateError('A matching STAFF command is in flight.');
          }
          return replay.identity;
        }
        return StaffSoReviseQuoteIdentity(
          serviceOrderId: serviceOrderId,
          diagnosis: normalizedDiagnosis,
          items: List.unmodifiable(items),
          changeReason: normalizedReason,
        );
      },
    );
  }

  Future<StaffServiceOrderProjection> resumeApprovedScope({
    required String serviceOrderId,
    required String reason,
  }) async {
    return _executeWithIdentityResolution(
      commandType: staffSoResumeApprovedScopeCommandType,
      serviceOrderId: serviceOrderId,
      resolveIdentity: (unresolved) {
        final normalizedReason = normalizeReason(reason);
        if (normalizedReason == null) {
          throw ArgumentError.value(
            reason,
            'reason',
            'reason is required to resume approved scope.',
          );
        }
        final matching = <({
          CommandIntent intent,
          StaffSoResumeScopeIdentity identity,
        })>[];
        for (final intent in unresolved) {
          final identity = StaffSoResumeScopeIdentity.fromIntent(intent);
          if (identity.matchesRequestedAction(
            requestedReason: normalizedReason,
          )) {
            matching.add((intent: intent, identity: identity));
          }
        }
        if (matching.length > 1) {
          throw StateError('Ambiguous unresolved STAFF command intent.');
        }
        if (matching.length == 1) {
          final replay = matching.single;
          if (replay.intent.lifecycle == CommandIntentLifecycle.sending) {
            throw StateError('A matching STAFF command is in flight.');
          }
          return replay.identity;
        }
        return StaffSoResumeScopeIdentity(
          serviceOrderId: serviceOrderId,
          reason: normalizedReason,
        );
      },
    );
  }

  Future<StaffServiceOrderProjection> markReady({
    required String serviceOrderId,
    String? notes,
  }) async {
    return _executeWithIdentityResolution(
      commandType: staffSoMarkReadyCommandType,
      serviceOrderId: serviceOrderId,
      resolveIdentity: (unresolved) {
        final normalizedNotes = normalizeNotes(notes);
        final matching = <({
          CommandIntent intent,
          StaffSoMarkReadyIdentity identity,
        })>[];
        for (final intent in unresolved) {
          final identity = StaffSoMarkReadyIdentity.fromIntent(intent);
          if (identity.matchesRequestedAction(
            requestedNotes: normalizedNotes,
          )) {
            matching.add((intent: intent, identity: identity));
          }
        }
        if (matching.length > 1) {
          throw StateError('Ambiguous unresolved STAFF command intent.');
        }
        if (matching.length == 1) {
          final replay = matching.single;
          if (replay.intent.lifecycle == CommandIntentLifecycle.sending) {
            throw StateError('A matching STAFF command is in flight.');
          }
          return replay.identity;
        }
        return StaffSoMarkReadyIdentity(
          serviceOrderId: serviceOrderId,
          notes: normalizedNotes,
        );
      },
    );
  }

  Future<StaffServiceOrderProjection> markDelivered({
    required String serviceOrderId,
    String? notes,
  }) async {
    return _executeWithIdentityResolution(
      commandType: staffSoMarkDeliveredCommandType,
      serviceOrderId: serviceOrderId,
      resolveIdentity: (unresolved) {
        final normalizedNotes = normalizeNotes(notes);
        final matching = <({
          CommandIntent intent,
          StaffSoMarkDeliveredIdentity identity,
        })>[];
        for (final intent in unresolved) {
          final identity = StaffSoMarkDeliveredIdentity.fromIntent(intent);
          if (identity.matchesRequestedAction(
            requestedNotes: normalizedNotes,
          )) {
            matching.add((intent: intent, identity: identity));
          }
        }
        if (matching.length > 1) {
          throw StateError('Ambiguous unresolved STAFF command intent.');
        }
        if (matching.length == 1) {
          final replay = matching.single;
          if (replay.intent.lifecycle == CommandIntentLifecycle.sending) {
            throw StateError('A matching STAFF command is in flight.');
          }
          return replay.identity;
        }
        return StaffSoMarkDeliveredIdentity(
          serviceOrderId: serviceOrderId,
          notes: normalizedNotes,
        );
      },
    );
  }

  // ── Shared execution with identity resolution ────────────────────────────

  Future<StaffServiceOrderProjection> _executeWithIdentityResolution({
    required String commandType,
    required String serviceOrderId,
    required StaffSoCommandIdentity Function(List<CommandIntent> unresolved)
        resolveIdentity,
  }) async {
    if (_isInFlight) {
      throw StateError('A staff SO command is already being processed.');
    }
    if (!ref.read(isOnlineSessionProvider)) {
      throw const StaffSoCommandException(
        503,
        'STAFF_COMMAND_REQUIRES_ONLINE_SESSION',
        safeMessage: 'Conecte-se à internet para executar esta operação.',
      );
    }
    final binding = _captureBinding(ref.read(authenticatedSessionKeyProvider));
    _ensureBindingCurrent(binding);
    _isInFlight = true;
    state = const AsyncLoading();

    try {
      final unresolved = await ref
          .read(staffSoCommandIntentRepositoryProvider)
          .findUnresolved(
            commandType: commandType,
            targetId: serviceOrderId,
            executor: binding.databaseHandle.database,
          );
      _ensureBindingCurrent(binding);

      final identity = resolveIdentity(unresolved);

      final executor = StaffSoCommandIntentExecutor(
        gateway: ref.read(staffSoCommandGatewayProvider),
        intentRepository: ref.read(staffSoCommandIntentRepositoryProvider),
        database: binding.databaseHandle.database,
        isBindingCurrent: () => _isBindingCurrent(binding),
        operationIdFactory: ref.read(staffSoOperationIdFactoryProvider),
      );

      final projection = await executor.execute(identity: identity);
      _ensureBindingCurrent(binding);
      ref.invalidate(serviceOrdersProvider);
      _ensureBindingCurrent(binding);
      state = const AsyncData(null);
      return projection;
    } catch (error, stackTrace) {
      if (_isBindingCurrent(binding)) {
        state = AsyncError(error, stackTrace);
      }
      rethrow;
    } finally {
      _isInFlight = false;
    }
  }

  // ── Session and role validation ──────────────────────────────────────────

  _StaffSoBinding _captureBinding(AuthenticatedSessionKey? sessionKey) {
    if (sessionKey == null) {
      throw const StaffSoCommandException(
        401,
        'STAFF_UNAUTHENTICATED',
        safeMessage: 'Autenticação necessária para executar esta operação.',
      );
    }
    if (sessionKey.scope is! ProfessionalAuthScope) {
      throw const StaffSoCommandException(
        403,
        'STAFF_CONTEXT_REQUIRED',
        safeMessage: 'Apenas equipe autorizada pode executar esta operação.',
      );
    }
    final professionalScope = sessionKey.scope as ProfessionalAuthScope;
    final user = ref.read(currentUserProvider);
    if (user == null || (user.role != 'ADMIN' && user.role != 'TECHNICIAN')) {
      throw const StaffSoCommandException(
        403,
        'STAFF_ROLE_REQUIRED',
        safeMessage:
            'Apenas administradores e técnicos podem executar esta operação.',
      );
    }
    final manager = ref.read(staffSoDatabaseManagerProvider);
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated STAFF session.',
      );
    }
    return (
      sessionKey: sessionKey,
      scope: professionalScope,
      databaseHandle: handle,
    );
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
// Main Provider (Non-auto-dispose!)
// ---------------------------------------------------------------------------

final staffSoCommandsProvider =
    AsyncNotifierProvider<StaffSoCommandsNotifier, void>(
  StaffSoCommandsNotifier.new,
);
