import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/auth_scoped_database_manager.dart';
import '../../../core/network/api_client.dart';
import '../../../core/security/credential_storage.dart';
import '../../../core/security/hive_credential_storage.dart';
import '../data/datasources/auth_remote_datasource.dart';
import '../data/datasources/hive_offline_authority_store.dart';
import '../data/datasources/hive_user_profile_cache.dart';
import '../data/repositories/auth_repository_impl.dart';
import '../domain/entities/offline_authority_record.dart';
import '../domain/entities/auth_scope.dart';
import '../domain/entities/session_state.dart';
import '../domain/entities/user.dart';
import '../domain/repositories/auth_repository.dart';
import '../domain/repositories/offline_authority_store.dart';
import '../domain/repositories/user_profile_cache.dart';
import '../domain/services/session_security_validator.dart';

final credentialStorageProvider = Provider<CredentialStorage>((ref) {
  return HiveCredentialStorage();
});

final userProfileCacheProvider = Provider<UserProfileCache>((ref) {
  return HiveUserProfileCache();
});

final offlineAuthorityStoreProvider = Provider<OfflineAuthorityStore>((ref) {
  return HiveOfflineAuthorityStore();
});

final sessionSecurityValidatorProvider = Provider<SessionSecurityValidator>(
  (ref) => const SessionSecurityValidator(),
);

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    credentialStorage: ref.watch(credentialStorageProvider),
  );
});

final authRemoteDataSourceProvider = Provider<AuthRemoteDataSource>((ref) {
  return AuthRemoteDataSource(ref.watch(apiClientProvider));
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositoryImpl(ref.watch(authRemoteDataSourceProvider));
});

final authStateProvider = StateNotifierProvider<AuthNotifier, SessionState>(
  (ref) {
    return AuthNotifier(
      repository: ref.watch(authRepositoryProvider),
      credentialStorage: ref.watch(credentialStorageProvider),
      profileCache: ref.watch(userProfileCacheProvider),
      offlineAuthorityStore: ref.watch(offlineAuthorityStoreProvider),
      securityValidator: ref.watch(sessionSecurityValidatorProvider),
      databaseManager: AuthScopedDatabaseManager.instance,
    );
  },
);

final currentUserProvider = Provider<User?>((ref) {
  return ref.watch(authStateProvider).authenticatedUser;
});

final authScopeProvider = Provider<AuthScope?>((ref) {
  return ref.watch(authStateProvider).authenticatedScope;
});

final sessionGenerationProvider = Provider<int>((ref) {
  return ref.watch(authStateProvider).generation;
});

final authenticatedSessionKeyProvider =
    Provider<AuthenticatedSessionKey?>((ref) {
  final session = ref.watch(authStateProvider);
  if (session is! AuthenticatedSession) return null;
  return AuthenticatedSessionKey(
    scope: session.scope,
    sessionGeneration: session.generation,
  );
});

final isOnlineSessionProvider = Provider<bool>((ref) {
  return ref.watch(authStateProvider) is AuthenticatedOnline;
});

final class SessionRequestCredential {
  const SessionRequestCredential({
    required this.sessionGeneration,
    required this.accessToken,
    required this.credentialBindingId,
  });

  final int sessionGeneration;
  final String accessToken;
  final String credentialBindingId;
}

final class SessionRequestBlockedException implements Exception {
  const SessionRequestBlockedException(this.message);

  final String message;

  @override
  String toString() => 'SessionRequestBlockedException: $message';
}

final class LogoutResult {
  const LogoutResult({
    required this.completed,
    required this.cleanupPending,
    this.diagnostic,
  });

  final bool completed;
  final bool cleanupPending;
  final String? diagnostic;
}

/// Authoritative frontend session lifecycle.
///
/// Only [AuthenticatedOnline] and [AuthenticatedOfflineLimited] expose User
/// and AuthScope. Every asynchronous operation is generation-bound, while all
/// persistent mutations pass through a serialized commit gate.
class AuthNotifier extends StateNotifier<SessionState> {
  AuthNotifier({
    required AuthRepository repository,
    required CredentialStorage credentialStorage,
    required UserProfileCache profileCache,
    required OfflineAuthorityStore offlineAuthorityStore,
    required SessionSecurityValidator securityValidator,
    required AuthScopedDatabaseManager databaseManager,
    DateTime Function()? nowUtc,
    String Function()? credentialBindingIdFactory,
    bool autoBootstrap = true,
  })  : _repository = repository,
        _credentialStorage = credentialStorage,
        _profileCache = profileCache,
        _offlineAuthorityStore = offlineAuthorityStore,
        _securityValidator = securityValidator,
        _databaseManager = databaseManager,
        _nowUtc = nowUtc ?? (() => DateTime.now().toUtc()),
        _credentialBindingIdFactory =
            credentialBindingIdFactory ?? (() => const Uuid().v4()),
        super(const SessionBootstrapping(0)) {
    if (autoBootstrap) {
      unawaited(bootstrap());
    }
  }

  final AuthRepository _repository;
  final CredentialStorage _credentialStorage;
  final UserProfileCache _profileCache;
  final OfflineAuthorityStore _offlineAuthorityStore;
  final SessionSecurityValidator _securityValidator;
  final AuthScopedDatabaseManager _databaseManager;
  final DateTime Function() _nowUtc;
  final String Function() _credentialBindingIdFactory;

  int _currentGeneration = 0;
  Future<void> _persistenceTail = Future<void>.value();

  int get currentGeneration => _currentGeneration;

  bool isGenerationCurrent(int generation) =>
      mounted && generation == _currentGeneration;

  bool isCurrentOnlineGeneration(int generation) =>
      isGenerationCurrent(generation) &&
      state is AuthenticatedOnline &&
      state.generation == generation;

  Future<void> bootstrap() async {
    final generation = _begin(
      (next) => SessionBootstrapping(next),
    );

    // Bootstrap is also a lifecycle transition when invoked again in-process.
    // Detach any older bound DB before reading credentials so a missing or
    // rejected credential cannot leave the previous scope reachable.
    await _closeDatabaseBestEffort(generation);
    if (!isGenerationCurrent(generation)) return;

    String? legacyCleanupDiagnostic;
    try {
      final purge = await _serializeForGeneration<void>(
        generation,
        _credentialStorage.purgeLegacyCredentials,
      );
      if (!purge.applied) return;
    } catch (error) {
      // Legacy values are never read or promoted even when physical cleanup
      // fails. Keep a non-secret diagnostic for observability.
      legacyCleanupDiagnostic = 'Legacy credential cleanup failed: $error';
    }

    if (!isGenerationCurrent(generation)) return;

    late _BootstrapSnapshot snapshot;
    try {
      final result = await _serializeForGeneration<_BootstrapSnapshot>(
        generation,
        () async => _BootstrapSnapshot(
          credential: await _credentialStorage.read(),
          cleanupPendingBindingId:
              await _credentialStorage.readCleanupPendingBindingId(),
        ),
      );
      if (!result.applied || result.value == null) return;
      snapshot = result.value!;
    } catch (error, stackTrace) {
      await _failClosedForCurrentGeneration(
        generation,
        operation: SessionOperation.bootstrap,
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }

    final credential = snapshot.credential;
    if (credential == null) {
      _publishIfCurrent(
        generation,
        SessionUnauthenticated(
          generation,
          diagnostic: legacyCleanupDiagnostic,
        ),
      );
      return;
    }

    if (snapshot.cleanupPendingBindingId == credential.bindingId) {
      await _terminateGeneration(
        generation,
        operation: SessionOperation.bootstrap,
        diagnostic: 'Residual credential was blocked by a logout tombstone.',
      );
      return;
    }

    if (snapshot.cleanupPendingBindingId != null) {
      try {
        await _serializeForGeneration<void>(
          generation,
          () => _credentialStorage.clearCleanupPending(
            snapshot.cleanupPendingBindingId!,
          ),
        );
      } catch (_) {
        // A marker for a different, already superseded binding cannot make the
        // current credential usable or unusable. It can be retried later.
      }
    }

    try {
      final jwt = JwtPayloadInspection.parse(credential.accessToken);
      if (!_nowUtc().toUtc().isBefore(jwt.expiresAtUtc)) {
        throw const SessionValidationException('JWT has expired.');
      }
    } on SessionValidationException {
      await _terminateGeneration(
        generation,
        operation: SessionOperation.bootstrap,
        diagnostic: 'Stored credential failed local expiry/shape gating.',
      );
      return;
    }

    try {
      final user = await _repository.getCurrentUser(credential.accessToken);
      if (!isGenerationCurrent(generation)) return;

      final validatedAt = _nowUtc().toUtc();
      final material = _securityValidator.validateOnline(
        user: user,
        credential: credential,
        nowUtc: validatedAt,
      );
      final authority = _securityValidator.createOfflineAuthorityRecord(
        user: user,
        credential: credential,
        material: material,
        validatedAtUtc: validatedAt,
      );

      final commit = await _serializeForGeneration<void>(
        generation,
        () async {
          await _profileCache.write(user);
          await _offlineAuthorityStore.write(authority);
        },
      );
      if (!commit.applied) return;
      if (!await _openBoundDatabase(
        generation: generation,
        scope: material.scope,
      )) {
        return;
      }

      _publishIfCurrent(
        generation,
        AuthenticatedOnline(
          generation: generation,
          user: user,
          scope: material.scope,
          credentialBindingId: credential.bindingId,
          onlineValidatedAtUtc: validatedAt,
          jwtExpiresAtUtc: material.jwtExpiresAtUtc,
        ),
      );
    } on UnauthorizedException {
      await _terminateGeneration(
        generation,
        operation: SessionOperation.bootstrap,
        diagnostic: '/auth/me rejected the stored credential.',
      );
    } on AuthResponseFormatException catch (error, stackTrace) {
      await _failClosedForCurrentGeneration(
        generation,
        operation: SessionOperation.bootstrap,
        error: error,
        stackTrace: stackTrace,
      );
    } on SessionValidationException catch (error, stackTrace) {
      await _failClosedForCurrentGeneration(
        generation,
        operation: SessionOperation.bootstrap,
        error: error,
        stackTrace: stackTrace,
      );
    } on AuthRemoteException catch (error) {
      if (error.isServerUnavailable) {
        await _restoreOfflineLimited(
          generation,
          credential,
          diagnostic: legacyCleanupDiagnostic,
        );
      } else {
        await _terminateGeneration(
          generation,
          operation: SessionOperation.bootstrap,
          diagnostic: 'Authority endpoint returned HTTP ${error.statusCode}.',
        );
      }
    } catch (_) {
      // Transport exceptions (DNS, socket, timeout) may enter only the narrow
      // offline path below. Cache alone is never sufficient.
      await _restoreOfflineLimited(
        generation,
        credential,
        diagnostic: legacyCleanupDiagnostic,
      );
    }
  }

  Future<bool> login(String email, String password) async {
    final generation = _begin(
      (next) => SessionAuthenticating(next),
    );

    // A new login is a new logical session, even for the same principal. Close
    // and invalidate the previous DB/credential before contacting the public
    // login endpoint.
    await _closeDatabaseBestEffort(generation);
    try {
      final cleanup = await _serializeForGeneration<_CleanupOutcome>(
        generation,
        _cleanupPersistedSession,
      );
      if (!cleanup.applied) return false;
    } catch (error) {
      debugPrint(
          'Session pre-login cleanup failed (credential omitted): $error');
    }
    if (!isGenerationCurrent(generation)) return false;

    try {
      final result = await _repository.login(email, password);
      if (!isGenerationCurrent(generation)) return false;

      final credential = StoredCredential(
        accessToken: result.accessToken,
        bindingId: _credentialBindingIdFactory(),
      );
      final validatedAt = _nowUtc().toUtc();
      final material = _securityValidator.validateOnline(
        user: result.user,
        credential: credential,
        nowUtc: validatedAt,
      );
      final authority = _securityValidator.createOfflineAuthorityRecord(
        user: result.user,
        credential: credential,
        material: material,
        validatedAtUtc: validatedAt,
      );

      final commit = await _serializeForGeneration<void>(
        generation,
        () async {
          final oldMarker =
              await _credentialStorage.readCleanupPendingBindingId();
          if (oldMarker != null && oldMarker != credential.bindingId) {
            await _credentialStorage.clearCleanupPending(oldMarker);
          }
          await _profileCache.write(result.user);
          await _offlineAuthorityStore.write(authority);
          // Credential is the final commit marker. Auxiliary cache records can
          // never authenticate without it.
          await _credentialStorage.write(credential);
        },
      );
      if (!commit.applied) return false;

      if (!await _openBoundDatabase(
        generation: generation,
        scope: material.scope,
      )) {
        return false;
      }

      _publishIfCurrent(
        generation,
        AuthenticatedOnline(
          generation: generation,
          user: result.user,
          scope: material.scope,
          credentialBindingId: credential.bindingId,
          onlineValidatedAtUtc: validatedAt,
          jwtExpiresAtUtc: material.jwtExpiresAtUtc,
        ),
      );
      return isCurrentOnlineGeneration(generation);
    } catch (error, stackTrace) {
      if (isGenerationCurrent(generation)) {
        state = SessionFailure(
          generation,
          operation: SessionOperation.login,
          error: error,
          stackTrace: stackTrace,
        );
      }
      return false;
    }
  }

  Future<LogoutResult> logout() {
    return _logoutCurrent(operation: SessionOperation.logout);
  }

  Future<bool> revalidateOnlineAuthority() async {
    final snapshot = state;
    if (snapshot is! AuthenticatedOfflineLimited ||
        !isGenerationCurrent(snapshot.generation)) {
      return snapshot is AuthenticatedOnline;
    }

    final generation = snapshot.generation;
    try {
      final requestCredential = await acquireOnlineRequestCredential(
        allowOfflineForAuthorityRevalidation: true,
      );
      final user = await _repository.getCurrentUser(
        requestCredential.accessToken,
      );
      if (!isGenerationCurrent(generation)) return false;

      final validatedAt = _nowUtc().toUtc();
      final storedCredential = StoredCredential(
        accessToken: requestCredential.accessToken,
        bindingId: requestCredential.credentialBindingId,
      );
      final material = _securityValidator.validateOnline(
        user: user,
        credential: storedCredential,
        nowUtc: validatedAt,
      );
      final authority = _securityValidator.createOfflineAuthorityRecord(
        user: user,
        credential: storedCredential,
        material: material,
        validatedAtUtc: validatedAt,
      );
      final commit = await _serializeForGeneration<void>(
        generation,
        () async {
          await _profileCache.write(user);
          await _offlineAuthorityStore.write(authority);
        },
      );
      if (!commit.applied) return false;

      _publishIfCurrent(
        generation,
        AuthenticatedOnline(
          generation: generation,
          user: user,
          scope: material.scope,
          credentialBindingId: storedCredential.bindingId,
          onlineValidatedAtUtc: validatedAt,
          jwtExpiresAtUtc: material.jwtExpiresAtUtc,
        ),
      );
      return isCurrentOnlineGeneration(generation);
    } on UnauthorizedException catch (error) {
      await handleAuthorizationFailure(
        sessionGeneration: generation,
        statusCode: error.statusCode,
        authorityRevalidation: true,
      );
      return false;
    } on AuthRemoteException catch (error) {
      if (!error.isServerUnavailable) {
        await handleAuthorizationFailure(
          sessionGeneration: generation,
          statusCode: error.statusCode,
          authorityRevalidation: true,
        );
      }
      return false;
    } on AuthResponseFormatException {
      await _terminateGeneration(
        generation,
        operation: SessionOperation.authorityRevalidation,
        diagnostic: 'Malformed authority response.',
      );
      return false;
    } on SessionValidationException {
      await _terminateGeneration(
        generation,
        operation: SessionOperation.authorityRevalidation,
        diagnostic: 'Authority response did not match the bound credential.',
      );
      return false;
    } catch (_) {
      // Connectivity failure leaves a still-valid OfflineLimited session in
      // place. It does not enable Sync or commands requiring online authority.
      return false;
    }
  }

  Future<SessionRequestCredential> acquireOnlineRequestCredential({
    bool allowOfflineForAuthorityRevalidation = false,
  }) async {
    final snapshot = state;
    final allowed = snapshot is AuthenticatedOnline ||
        (allowOfflineForAuthorityRevalidation &&
            snapshot is AuthenticatedOfflineLimited);
    if (!allowed || snapshot is! AuthenticatedSession) {
      throw const SessionRequestBlockedException(
        'Current session does not have online command authority.',
      );
    }

    final generation = snapshot.generation;
    final bindingId = snapshot.credentialBindingId;
    final result = await _serializeForGeneration<_BootstrapSnapshot>(
      generation,
      () async => _BootstrapSnapshot(
        credential: await _credentialStorage.read(),
        cleanupPendingBindingId:
            await _credentialStorage.readCleanupPendingBindingId(),
      ),
    );
    final credential = result.value?.credential;
    if (!result.applied ||
        credential == null ||
        credential.bindingId != bindingId ||
        result.value!.cleanupPendingBindingId == bindingId ||
        !isGenerationCurrent(generation)) {
      throw const SessionRequestBlockedException(
        'Session credential is missing, tombstoned, or superseded.',
      );
    }

    return SessionRequestCredential(
      sessionGeneration: generation,
      accessToken: credential.accessToken,
      credentialBindingId: credential.bindingId,
    );
  }

  /// Applies a generation-bound HTTP authorization decision.
  ///
  /// Ordinary resource 403 responses are intentionally ignored. A 403 is
  /// terminating only when it came from `/auth/me` or explicit revalidation.
  Future<void> handleAuthorizationFailure({
    required int sessionGeneration,
    required int statusCode,
    required bool authorityRevalidation,
  }) async {
    if (!isGenerationCurrent(sessionGeneration)) return;
    final mustTerminate =
        statusCode == 401 || (statusCode == 403 && authorityRevalidation);
    if (!mustTerminate) return;

    await _terminateGeneration(
      sessionGeneration,
      operation: SessionOperation.runtimeAuthorization,
      diagnostic: 'Current session authority was rejected (HTTP $statusCode).',
    );
  }

  Future<LogoutResult> _logoutCurrent({
    required SessionOperation operation,
  }) async {
    final generation = _begin(
      (next) => SessionLoggingOut(next),
    );

    String? databaseDiagnostic;
    try {
      await _databaseManager.closeCurrentDatabase(
        sessionGeneration: generation,
      );
    } catch (error) {
      databaseDiagnostic = 'Scoped database close failed: $error';
    }

    _GenerationCommit<_CleanupOutcome> cleanup;
    try {
      cleanup = await _serializeForGeneration<_CleanupOutcome>(
        generation,
        _cleanupPersistedSession,
      );
    } catch (error) {
      cleanup = _GenerationCommit<_CleanupOutcome>(
        applied: isGenerationCurrent(generation),
        value: _CleanupOutcome(
          cleanupPending: true,
          diagnostic: 'Credential cleanup failed: $error',
        ),
      );
    }

    if (!cleanup.applied || !isGenerationCurrent(generation)) {
      return const LogoutResult(
        completed: false,
        cleanupPending: false,
      );
    }

    final outcome = cleanup.value ?? const _CleanupOutcome();
    final diagnostic = _joinDiagnostics(
      databaseDiagnostic,
      outcome.diagnostic,
    );
    state = SessionUnauthenticated(
      generation,
      cleanupPending: outcome.cleanupPending,
      diagnostic: diagnostic,
    );
    return LogoutResult(
      completed: true,
      cleanupPending: outcome.cleanupPending,
      diagnostic: diagnostic,
    );
  }

  Future<void> _terminateGeneration(
    int expectedGeneration, {
    required SessionOperation operation,
    String? diagnostic,
  }) async {
    if (!isGenerationCurrent(expectedGeneration)) return;
    final result = await _logoutCurrent(operation: operation);
    if (result.completed &&
        diagnostic != null &&
        state is SessionUnauthenticated) {
      final unauthenticated = state as SessionUnauthenticated;
      state = SessionUnauthenticated(
        unauthenticated.generation,
        cleanupPending: unauthenticated.cleanupPending,
        diagnostic: _joinDiagnostics(
          diagnostic,
          unauthenticated.diagnostic,
        ),
      );
    }
  }

  Future<void> _restoreOfflineLimited(
    int generation,
    StoredCredential credential, {
    String? diagnostic,
  }) async {
    if (!isGenerationCurrent(generation)) return;

    try {
      final cached = await _serializeForGeneration<_OfflineSnapshot>(
        generation,
        () async => _OfflineSnapshot(
          user: await _profileCache.read(),
          authority: await _offlineAuthorityStore.read(),
        ),
      );
      if (!cached.applied || cached.value == null) return;
      final user = cached.value!.user;
      final authority = cached.value!.authority;
      if (user == null || authority == null) {
        await _terminateGeneration(
          generation,
          operation: SessionOperation.bootstrap,
          diagnostic:
              'Offline restore requires credential, profile and authority metadata.',
        );
        return;
      }

      final offline = _securityValidator.validateOffline(
        cachedUser: user,
        credential: credential,
        authority: authority,
        nowUtc: _nowUtc().toUtc(),
      );
      if (!await _openBoundDatabase(
        generation: generation,
        scope: offline.material.scope,
      )) {
        return;
      }

      _publishIfCurrent(
        generation,
        AuthenticatedOfflineLimited(
          generation: generation,
          user: user,
          scope: offline.material.scope,
          credentialBindingId: credential.bindingId,
          onlineValidatedAtUtc: authority.validatedAtUtc,
          jwtExpiresAtUtc: offline.material.jwtExpiresAtUtc,
          offlineAuthorityExpiresAtUtc: offline.authorityExpiresAtUtc,
        ),
      );
    } catch (error, stackTrace) {
      await _failClosedForCurrentGeneration(
        generation,
        operation: SessionOperation.bootstrap,
        error: error,
        stackTrace: stackTrace,
        diagnostic: diagnostic,
      );
    }
  }

  Future<void> _failClosedForCurrentGeneration(
    int generation, {
    required SessionOperation operation,
    required Object error,
    required StackTrace stackTrace,
    String? diagnostic,
  }) async {
    if (!isGenerationCurrent(generation)) return;
    await _closeDatabaseBestEffort(generation);

    _CleanupOutcome cleanup = const _CleanupOutcome();
    try {
      final result = await _serializeForGeneration<_CleanupOutcome>(
        generation,
        _cleanupPersistedSession,
      );
      if (!result.applied) return;
      cleanup = result.value ?? const _CleanupOutcome();
    } catch (cleanupError) {
      cleanup = _CleanupOutcome(
        cleanupPending: true,
        diagnostic: 'Fail-closed cleanup failed: $cleanupError',
      );
    }

    if (isGenerationCurrent(generation)) {
      state = SessionFailure(
        generation,
        operation: operation,
        error: error,
        stackTrace: stackTrace,
        cleanupPending: cleanup.cleanupPending,
      );
      if (diagnostic != null || cleanup.diagnostic != null) {
        debugPrint(_joinDiagnostics(diagnostic, cleanup.diagnostic));
      }
    }
  }

  Future<bool> _openBoundDatabase({
    required int generation,
    required AuthScope scope,
  }) async {
    if (kIsWeb) return isGenerationCurrent(generation);
    try {
      final handle = await _databaseManager.openDatabaseForScope(
        scope,
        sessionGeneration: generation,
      );
      return isGenerationCurrent(generation) &&
          handle.sessionGeneration == generation &&
          handle.authScope == scope &&
          _databaseManager.isCurrentHandle(handle);
    } catch (error, stackTrace) {
      if (isGenerationCurrent(generation)) {
        state = SessionFailure(
          generation,
          operation: SessionOperation.localDatabase,
          error: error,
          stackTrace: stackTrace,
        );
      }
      return false;
    }
  }

  Future<void> _closeDatabaseBestEffort(int generation) async {
    try {
      await _databaseManager.closeCurrentDatabase(
        sessionGeneration: generation,
      );
    } catch (error) {
      debugPrint('Scoped database close failed: $error');
    }
  }

  Future<_CleanupOutcome> _cleanupPersistedSession() async {
    final diagnostics = <String>[];
    var cleanupPending = false;
    StoredCredential? credential;

    try {
      credential = await _credentialStorage.read();
    } catch (error) {
      diagnostics.add('Credential read failed during cleanup: $error');
      try {
        await _credentialStorage.delete();
      } catch (deleteError) {
        cleanupPending = true;
        diagnostics.add('Malformed credential deletion failed: $deleteError');
      }
    }

    if (credential != null) {
      var markerWritten = false;
      try {
        await _credentialStorage.markCleanupPending(credential.bindingId);
        markerWritten = true;
      } catch (error) {
        diagnostics.add('Cleanup tombstone write failed: $error');
      }

      try {
        await _credentialStorage.deleteIfMatches(credential.bindingId);
        if (markerWritten) {
          await _credentialStorage.clearCleanupPending(credential.bindingId);
        }
      } catch (error) {
        cleanupPending = true;
        diagnostics.add('Credential deletion failed: $error');
      }
    } else {
      try {
        final oldMarker =
            await _credentialStorage.readCleanupPendingBindingId();
        if (oldMarker != null) {
          await _credentialStorage.clearCleanupPending(oldMarker);
        }
      } catch (error) {
        cleanupPending = true;
        diagnostics.add('Cleanup tombstone clearing failed: $error');
      }
    }

    try {
      await _offlineAuthorityStore.delete();
    } catch (error) {
      diagnostics.add('Offline authority cleanup failed: $error');
    }
    try {
      await _profileCache.delete();
    } catch (error) {
      diagnostics.add('User profile cache cleanup failed: $error');
    }

    return _CleanupOutcome(
      cleanupPending: cleanupPending,
      diagnostic: diagnostics.isEmpty ? null : diagnostics.join(' | '),
    );
  }

  int _begin(SessionState Function(int generation) transition) {
    final generation = ++_currentGeneration;
    state = transition(generation);
    return generation;
  }

  void _publishIfCurrent(int generation, SessionState nextState) {
    if (isGenerationCurrent(generation)) {
      state = nextState;
    }
  }

  Future<_GenerationCommit<T>> _serializeForGeneration<T>(
    int generation,
    Future<T> Function() operation,
  ) {
    final completer = Completer<_GenerationCommit<T>>();
    final previous = _persistenceTail;
    _persistenceTail = previous.then((_) async {
      if (!isGenerationCurrent(generation)) {
        completer.complete(_GenerationCommit<T>(applied: false));
        return;
      }
      try {
        final value = await operation();
        completer.complete(
          _GenerationCommit<T>(
            applied: isGenerationCurrent(generation),
            value: value,
          ),
        );
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static String? _joinDiagnostics(String? first, String? second) {
    final values = <String>[
      if (first != null && first.isNotEmpty) first,
      if (second != null && second.isNotEmpty) second,
    ];
    return values.isEmpty ? null : values.join(' | ');
  }
}

final class _GenerationCommit<T> {
  const _GenerationCommit({
    required this.applied,
    this.value,
  });

  final bool applied;
  final T? value;
}

final class _BootstrapSnapshot {
  const _BootstrapSnapshot({
    required this.credential,
    required this.cleanupPendingBindingId,
  });

  final StoredCredential? credential;
  final String? cleanupPendingBindingId;
}

final class _OfflineSnapshot {
  const _OfflineSnapshot({
    required this.user,
    required this.authority,
  });

  final User? user;
  final OfflineAuthorityRecord? authority;
}

final class _CleanupOutcome {
  const _CleanupOutcome({
    this.cleanupPending = false,
    this.diagnostic,
  });

  final bool cleanupPending;
  final String? diagnostic;
}
