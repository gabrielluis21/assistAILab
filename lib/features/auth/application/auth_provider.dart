import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/auth_scoped_database_manager.dart';
import '../../../core/network/api_client.dart';
import '../../../core/security/credential_epoch.dart';
import '../../../core/security/credential_epoch_store.dart';
import '../../../core/security/credential_storage.dart';
import '../../../core/security/revocation_fence.dart';
import '../data/datasources/auth_remote_datasource.dart';
import '../data/datasources/hive_user_profile_cache.dart';
import '../data/datasources/secure_session_stores.dart';
import '../data/repositories/auth_repository_impl.dart';
import '../domain/entities/auth_scope.dart';
import '../domain/entities/offline_authority_record.dart';
import '../domain/entities/session_state.dart';
import '../domain/entities/user.dart';
import '../domain/repositories/auth_repository.dart';
import '../domain/repositories/offline_authority_store.dart';
import '../domain/repositories/user_profile_cache.dart';
import '../domain/services/session_security_validator.dart';

final secureSessionStoresProvider = Provider<SecureSessionStores>((ref) {
  return createSecureSessionStores();
});

final credentialStorageProvider = Provider<CredentialStorage>((ref) {
  return ref.watch(secureSessionStoresProvider).credentialStorage;
});

final userProfileCacheProvider = Provider<UserProfileCache>((ref) {
  return HiveUserProfileCache();
});

final offlineAuthorityStoreProvider = Provider<OfflineAuthorityStore>((ref) {
  return ref.watch(secureSessionStoresProvider).offlineAuthorityStore;
});

final credentialEpochStoreProvider = Provider<CredentialEpochStore>((ref) {
  return ref.watch(secureSessionStoresProvider).credentialEpochStore;
});

final secureVaultMetadataStoreProvider = Provider<SecureVaultMetadataStore>(
  (ref) => ref.watch(secureSessionStoresProvider).secureVaultMetadataStore,
);

final sessionSecurityValidatorProvider = Provider<SessionSecurityValidator>(
  (ref) => const SessionSecurityValidator(),
);

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    credentialStorage: ref.watch(credentialStorageProvider),
    credentialEpochStore: ref.watch(credentialEpochStoreProvider),
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
      credentialEpochStore: ref.watch(credentialEpochStoreProvider),
      secureVaultMetadataStore: ref.watch(secureVaultMetadataStoreProvider),
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
    required this.credentialId,
    required this.credentialGeneration,
  });

  final int sessionGeneration;
  final String accessToken;
  final String credentialBindingId;
  final String credentialId;
  final int credentialGeneration;
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
    required CredentialEpochStore credentialEpochStore,
    required SecureVaultMetadataStore secureVaultMetadataStore,
    required SessionSecurityValidator securityValidator,
    required AuthScopedDatabaseManager databaseManager,
    DateTime Function()? nowUtc,
    String Function()? credentialBindingIdFactory,
    String Function()? credentialIdFactory,
    bool autoBootstrap = true,
  })  : _repository = repository,
        _credentialStorage = credentialStorage,
        _profileCache = profileCache,
        _offlineAuthorityStore = offlineAuthorityStore,
        _credentialEpochStore = credentialEpochStore,
        _secureVaultMetadataStore = secureVaultMetadataStore,
        _securityValidator = securityValidator,
        _databaseManager = databaseManager,
        _nowUtc = nowUtc ?? (() => DateTime.now().toUtc()),
        _credentialBindingIdFactory =
            credentialBindingIdFactory ?? (() => const Uuid().v4()),
        _credentialIdFactory = credentialIdFactory ?? (() => const Uuid().v4()),
        super(const SessionBootstrapping(0)) {
    if (autoBootstrap) {
      unawaited(bootstrap());
    }
  }

  final AuthRepository _repository;
  final CredentialStorage _credentialStorage;
  final UserProfileCache _profileCache;
  final OfflineAuthorityStore _offlineAuthorityStore;
  final CredentialEpochStore _credentialEpochStore;
  final SecureVaultMetadataStore _secureVaultMetadataStore;
  final SessionSecurityValidator _securityValidator;
  final AuthScopedDatabaseManager _databaseManager;
  final DateTime Function() _nowUtc;
  final String Function() _credentialBindingIdFactory;
  final String Function() _credentialIdFactory;

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

    late _ActiveVaultSnapshot snapshot;
    try {
      final result = await _serializeForGeneration<_ActiveVaultSnapshot?>(
        generation,
        _readActiveVaultSnapshot,
      );
      if (!result.applied) return;
      if (result.value == null) {
        final cleanup = await _serializeForGeneration<_CleanupOutcome>(
          generation,
          _cleanupPersistedSession,
        );
        if (!cleanup.applied) return;
        final outcome = cleanup.value ?? const _CleanupOutcome();
        _publishIfCurrent(
          generation,
          SessionUnauthenticated(
            generation,
            cleanupPending: outcome.cleanupPending,
            diagnostic: _joinDiagnostics(
              legacyCleanupDiagnostic,
              outcome.diagnostic,
            ),
          ),
        );
        return;
      }
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
          final verified = await _offlineAuthorityStore.readByCredentialId(
            credential.credentialId,
          );
          if (!_sameAuthority(verified, authority)) {
            throw const SessionVaultException(
              'Secure authority verification failed.',
            );
          }
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
          snapshot,
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
        snapshot,
        diagnostic: legacyCleanupDiagnostic,
      );
    }
  }

  Future<bool> login(String email, String password) async {
    final wasAuthenticated = state is AuthenticatedSession;
    final generation = _begin(
      (next) => SessionAuthenticating(next),
    );

    // A new login invalidates the in-memory session and DB immediately, while
    // the previous secure Epoch remains authoritative until replacement commit.
    await _closeDatabaseBestEffort(generation);
    if (!isGenerationCurrent(generation)) return false;

    try {
      final result = await _repository.login(email, password);
      if (!isGenerationCurrent(generation)) return false;

      final provisionalCredential = StoredCredential(
        accessToken: result.accessToken,
        bindingId: _credentialBindingIdFactory(),
      );
      final validatedAt = _nowUtc().toUtc();
      final material = _securityValidator.validateOnline(
        user: result.user,
        credential: provisionalCredential,
        nowUtc: validatedAt,
      );

      final commit = await _serializeForGeneration<_VaultCommit>(
        generation,
        () => _commitCredentialReplacement(
          generation: generation,
          user: result.user,
          accessToken: result.accessToken,
          bindingId: provisionalCredential.bindingId,
          material: material,
          validatedAtUtc: validatedAt,
          requiresActiveReplacementEpoch: wasAuthenticated,
        ),
      );
      if (!commit.applied || commit.value == null) return false;
      final credential = commit.value!.credential;

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
        credentialId: requestCredential.credentialId,
        credentialGeneration: requestCredential.credentialGeneration,
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
          final verified = await _offlineAuthorityStore.readByCredentialId(
            storedCredential.credentialId,
          );
          if (!_sameAuthority(verified, authority)) {
            throw const SessionVaultException(
              'Secure authority verification failed.',
            );
          }
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
    final result = await _serializeForGeneration<_ActiveVaultSnapshot?>(
      generation,
      _readActiveVaultSnapshot,
    );
    final credential = result.value?.credential;
    if (!result.applied ||
        credential == null ||
        credential.bindingId != bindingId ||
        !isGenerationCurrent(generation)) {
      throw const SessionRequestBlockedException(
        'Session credential is missing, tombstoned, or superseded.',
      );
    }

    return SessionRequestCredential(
      sessionGeneration: generation,
      accessToken: credential.accessToken,
      credentialBindingId: credential.bindingId,
      credentialId: credential.credentialId,
      credentialGeneration: credential.credentialGeneration,
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
          durableLogoutIncomplete: true,
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
      completed: !outcome.durableLogoutIncomplete,
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
    _ActiveVaultSnapshot vault, {
    String? diagnostic,
  }) async {
    if (!isGenerationCurrent(generation)) return;

    try {
      final cached = await _serializeForGeneration<_OfflineSnapshot>(
        generation,
        () async => _OfflineSnapshot(
          user: await _profileCache.read(),
          authority: await _offlineAuthorityStore.readByCredentialId(
            vault.credential.credentialId,
          ),
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
        credential: vault.credential,
        authority: authority,
        epoch: vault.epoch,
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
          credentialBindingId: vault.credential.bindingId,
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

  Future<_ActiveVaultSnapshot?> _readActiveVaultSnapshot() async {
    final fence = await _secureVaultMetadataStore.readRevocationFence();
    final epoch = await _credentialEpochStore.read();

    if (fence != null) {
      if (_fenceMatchesEpoch(fence, epoch)) {
        if (epoch!.isActive) {
          throw const SessionVaultException(
            'ACTIVE Epoch is blocked by a durable revocation fence.',
          );
        }
        return null;
      }

      if (epoch == null || !epoch.isActive) {
        final credential =
            await _credentialStorage.readById(fence.credentialId);
        final authority = await _offlineAuthorityStore.readByCredentialId(
          fence.credentialId,
        );
        if (credential == null && authority == null) {
          await _secureVaultMetadataStore.deleteRevocationFence();
          if (await _secureVaultMetadataStore.readRevocationFence() != null) {
            throw const SessionVaultException(
              'Revocation fence deletion could not be verified.',
            );
          }
        } else {
          throw const SessionVaultException(
            'Revocation fence references residual protected artifacts.',
          );
        }
      }
      // A fence for an older credential cannot revoke a distinct newer ACTIVE
      // Epoch. It remains durable until recovery can prove its target is gone.
    }

    if (epoch == null || !epoch.isActive) return null;

    final credentialId = epoch.activeCredentialId!;
    final credential = await _credentialStorage.readById(credentialId);
    if (credential == null ||
        credential.credentialId != credentialId ||
        credential.credentialGeneration != epoch.activeCredentialGeneration) {
      throw const SessionVaultException(
        'ACTIVE Epoch does not resolve to its exact credential.',
      );
    }
    return _ActiveVaultSnapshot(epoch: epoch, credential: credential);
  }

  Future<_VaultCommit> _commitCredentialReplacement({
    required int generation,
    required User user,
    required String accessToken,
    required String bindingId,
    required ValidatedSessionMaterial material,
    required DateTime validatedAtUtc,
    required bool requiresActiveReplacementEpoch,
  }) async {
    final previousEpoch = await _credentialEpochStore.read();
    if (requiresActiveReplacementEpoch &&
        (previousEpoch == null || !previousEpoch.isActive)) {
      throw const SessionVaultException(
        'Authenticated credential replacement requires an ACTIVE Epoch.',
      );
    }
    if (previousEpoch == null &&
        await _secureVaultMetadataStore.containsSessionArtifacts()) {
      throw const SessionVaultException(
        'Missing Epoch with residual secure Vault artifacts.',
      );
    }
    final isFreshVault =
        previousEpoch == null || previousEpoch.vaultState == VaultState.empty;
    final nextGeneration =
        isFreshVault ? 1 : previousEpoch.activeCredentialGeneration + 1;
    final credential = StoredCredential(
      accessToken: accessToken,
      bindingId: bindingId,
      credentialId: _credentialIdFactory(),
      credentialGeneration: nextGeneration,
    );
    final authority = _securityValidator.createOfflineAuthorityRecord(
      user: user,
      credential: credential,
      material: material,
      validatedAtUtc: validatedAtUtc,
    );
    var epochCommitted = false;
    try {
      await _credentialStorage.write(credential);
      await _offlineAuthorityStore.write(authority);

      final verifiedCredential =
          await _credentialStorage.readById(credential.credentialId);
      final verifiedAuthority = await _offlineAuthorityStore.readByCredentialId(
        credential.credentialId,
      );
      if (!_sameCredential(verifiedCredential, credential) ||
          !_sameAuthority(verifiedAuthority, authority)) {
        throw const SessionVaultException(
          'Pending credential or authority read-back verification failed.',
        );
      }

      await _profileCache.write(user);
      if (!isGenerationCurrent(generation)) {
        throw const SessionVaultException(
          'Credential replacement was superseded before Epoch commit.',
        );
      }

      final nextEpoch = CredentialEpoch(
        activeCredentialId: credential.credentialId,
        activeCredentialGeneration: credential.credentialGeneration,
        vaultState: VaultState.active,
      );
      await _credentialEpochStore.write(nextEpoch);
      final verifiedEpoch = await _credentialEpochStore.read();
      if (!_sameEpoch(verifiedEpoch, nextEpoch)) {
        throw const SessionVaultException(
          'ACTIVE Epoch read-back verification failed.',
        );
      }
      epochCommitted = true;
    } catch (_) {
      if (!epochCommitted) {
        await _deletePendingReplacementBestEffort(credential);
      }
      rethrow;
    }

    final previousId = previousEpoch?.activeCredentialId;
    if (previousId != null && previousId != credential.credentialId) {
      try {
        await _offlineAuthorityStore.deleteByCredentialId(previousId);
      } catch (_) {
        // The old authority is non-authoritative after Epoch commit.
      }
      try {
        await _credentialStorage.deleteIfMatches(
          credentialId: previousId,
          credentialGeneration: previousEpoch!.activeCredentialGeneration,
        );
      } catch (_) {
        // The old credential is non-authoritative after Epoch commit.
      }
    }

    return _VaultCommit(credential: credential);
  }

  Future<void> _deletePendingReplacementBestEffort(
    StoredCredential credential,
  ) async {
    try {
      await _offlineAuthorityStore.deleteByCredentialId(
        credential.credentialId,
      );
    } catch (_) {
      // A partial record cannot authenticate without its ACTIVE Epoch.
    }
    try {
      await _credentialStorage.deleteIfMatches(
        credentialId: credential.credentialId,
        credentialGeneration: credential.credentialGeneration,
      );
    } catch (_) {
      // A partial record cannot authenticate without its ACTIVE Epoch.
    }
  }

  Future<_CleanupOutcome> _cleanupPersistedSession() async {
    final diagnostics = <String>[];
    var cleanupPending = false;
    var durableLogoutIncomplete = false;
    var protectedCleanupAllowed = false;
    RevocationFence? fence;
    CredentialEpoch? epoch;

    try {
      fence = await _secureVaultMetadataStore.readRevocationFence();
    } catch (error) {
      cleanupPending = true;
      durableLogoutIncomplete = true;
      diagnostics.add('Revocation fence read failed during cleanup: $error');
    }

    if (!durableLogoutIncomplete) {
      try {
        epoch = await _credentialEpochStore.read();
      } catch (error) {
        cleanupPending = true;
        durableLogoutIncomplete = true;
        diagnostics.add('Credential Epoch read failed during cleanup: $error');
      }
    }

    if (!durableLogoutIncomplete && epoch?.isActive == true) {
      final expectedFence = RevocationFence(
        credentialId: epoch!.activeCredentialId!,
        credentialGeneration: epoch.activeCredentialGeneration,
      );
      try {
        if (!_sameFence(fence, expectedFence)) {
          await _secureVaultMetadataStore.writeRevocationFence(expectedFence);
          fence = await _secureVaultMetadataStore.readRevocationFence();
          if (!_sameFence(fence, expectedFence)) {
            throw const SessionVaultException(
              'Revocation fence read-back verification failed.',
            );
          }
        }
      } catch (error) {
        cleanupPending = true;
        durableLogoutIncomplete = true;
        diagnostics.add('Revocation fence commit failed: $error');
      }
    }

    if (!durableLogoutIncomplete && epoch?.isActive == true) {
      final revokedEpoch = CredentialEpoch(
        activeCredentialId: epoch!.activeCredentialId,
        activeCredentialGeneration: epoch.activeCredentialGeneration,
        vaultState: VaultState.revoked,
      );
      try {
        await _credentialEpochStore.write(revokedEpoch);
        final verifiedEpoch = await _credentialEpochStore.read();
        if (!_sameEpoch(verifiedEpoch, revokedEpoch)) {
          throw const SessionVaultException(
            'REVOKED Epoch read-back verification failed.',
          );
        }
        epoch = verifiedEpoch;
        protectedCleanupAllowed = true;
      } catch (error) {
        cleanupPending = true;
        diagnostics.add('Credential Epoch revocation failed: $error');
      }
    } else if (!durableLogoutIncomplete && (epoch == null || !epoch.isActive)) {
      protectedCleanupAllowed = true;
    }

    final cleanupTargets = <_CredentialReference>[];
    void addCleanupTarget(String? credentialId, int? credentialGeneration) {
      if (credentialId == null || credentialGeneration == null) return;
      if (cleanupTargets.any(
        (target) =>
            target.credentialId == credentialId &&
            target.credentialGeneration == credentialGeneration,
      )) {
        return;
      }
      cleanupTargets.add(
        _CredentialReference(
          credentialId: credentialId,
          credentialGeneration: credentialGeneration,
        ),
      );
    }

    addCleanupTarget(
      epoch?.activeCredentialId,
      epoch?.activeCredentialGeneration,
    );
    addCleanupTarget(fence?.credentialId, fence?.credentialGeneration);

    if (protectedCleanupAllowed) {
      for (final target in cleanupTargets) {
        try {
          await _offlineAuthorityStore.deleteByCredentialId(
            target.credentialId,
          );
        } catch (error) {
          cleanupPending = true;
          diagnostics.add('Offline authority cleanup failed: $error');
        }
        try {
          final credential =
              await _credentialStorage.readById(target.credentialId);
          if (credential != null) {
            final deleted = await _credentialStorage.deleteIfMatches(
              credentialId: target.credentialId,
              credentialGeneration: target.credentialGeneration,
            );
            if (!deleted) {
              cleanupPending = true;
              diagnostics.add(
                'Credential cleanup could not verify its target.',
              );
            }
          }
        } catch (error) {
          cleanupPending = true;
          diagnostics.add('Credential cleanup failed: $error');
        }
      }
    }

    try {
      await _credentialStorage.purgeLegacyCredentials();
    } catch (error) {
      diagnostics.add('Legacy authentication cleanup failed: $error');
    }
    try {
      await _profileCache.delete();
    } catch (error) {
      diagnostics.add('User profile cache cleanup failed: $error');
    }

    if (cleanupPending &&
        protectedCleanupAllowed &&
        epoch != null &&
        epoch.vaultState != VaultState.empty &&
        epoch.vaultState != VaultState.active) {
      try {
        await _credentialEpochStore.write(
          CredentialEpoch(
            activeCredentialId: epoch.activeCredentialId,
            activeCredentialGeneration: epoch.activeCredentialGeneration,
            vaultState: VaultState.cleanupPending,
          ),
        );
      } catch (error) {
        diagnostics.add('CLEANUP_PENDING Epoch write failed: $error');
      }
    }

    if (fence != null && protectedCleanupAllowed) {
      var safeToClearFence = epoch != null && !epoch.isActive;
      if (epoch == null) {
        try {
          final fencedCredential =
              await _credentialStorage.readById(fence.credentialId);
          final fencedAuthority =
              await _offlineAuthorityStore.readByCredentialId(
            fence.credentialId,
          );
          safeToClearFence =
              fencedCredential == null && fencedAuthority == null;
        } catch (error) {
          cleanupPending = true;
          diagnostics.add('Revocation fence recovery check failed: $error');
        }
      }
      if (safeToClearFence) {
        try {
          await _secureVaultMetadataStore.deleteRevocationFence();
          if (await _secureVaultMetadataStore.readRevocationFence() != null) {
            throw const SessionVaultException(
              'Revocation fence deletion could not be verified.',
            );
          }
        } catch (error) {
          cleanupPending = true;
          diagnostics.add('Revocation fence cleanup failed: $error');
        }
      }
    }

    return _CleanupOutcome(
      cleanupPending: cleanupPending,
      durableLogoutIncomplete: durableLogoutIncomplete,
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

final class _ActiveVaultSnapshot {
  const _ActiveVaultSnapshot({
    required this.epoch,
    required this.credential,
  });

  final CredentialEpoch epoch;
  final StoredCredential credential;
}

final class _VaultCommit {
  const _VaultCommit({required this.credential});

  final StoredCredential credential;
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
    this.durableLogoutIncomplete = false,
    this.diagnostic,
  });

  final bool cleanupPending;
  final bool durableLogoutIncomplete;
  final String? diagnostic;
}

final class _CredentialReference {
  const _CredentialReference({
    required this.credentialId,
    required this.credentialGeneration,
  });

  final String credentialId;
  final int credentialGeneration;
}

final class SessionVaultException implements Exception {
  const SessionVaultException(this.message);

  final String message;

  @override
  String toString() => 'SessionVaultException: $message';
}

bool _sameCredential(StoredCredential? left, StoredCredential right) =>
    left != null &&
    left.schemaVersion == right.schemaVersion &&
    left.accessToken == right.accessToken &&
    left.bindingId == right.bindingId &&
    left.credentialId == right.credentialId &&
    left.credentialGeneration == right.credentialGeneration;

bool _sameAuthority(
  OfflineAuthorityRecord? left,
  OfflineAuthorityRecord right,
) =>
    left != null &&
    left.schemaVersion == right.schemaVersion &&
    left.principalId == right.principalId &&
    left.scopeKey == right.scopeKey &&
    left.credentialBindingId == right.credentialBindingId &&
    left.credentialId == right.credentialId &&
    left.credentialGeneration == right.credentialGeneration &&
    left.validatedAtUtc.toUtc() == right.validatedAtUtc.toUtc() &&
    left.jwtExpiresAtUtc.toUtc() == right.jwtExpiresAtUtc.toUtc() &&
    left.credentialFingerprint == right.credentialFingerprint;

bool _sameEpoch(CredentialEpoch? left, CredentialEpoch right) =>
    left != null &&
    left.schemaVersion == right.schemaVersion &&
    left.activeCredentialId == right.activeCredentialId &&
    left.activeCredentialGeneration == right.activeCredentialGeneration &&
    left.vaultState == right.vaultState;

bool _sameFence(RevocationFence? left, RevocationFence right) =>
    left != null &&
    left.schemaVersion == right.schemaVersion &&
    left.credentialId == right.credentialId &&
    left.credentialGeneration == right.credentialGeneration &&
    left.state == right.state;

bool _fenceMatchesEpoch(
  RevocationFence fence,
  CredentialEpoch? epoch,
) =>
    epoch != null &&
    fence.credentialId == epoch.activeCredentialId &&
    fence.credentialGeneration == epoch.activeCredentialGeneration;
