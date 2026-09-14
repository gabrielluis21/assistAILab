import 'dart:async';
import 'dart:convert';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/security/credential_epoch.dart';
import 'package:assistailab/core/security/credential_epoch_store.dart';
import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/data/datasources/secure_session_stores.dart';
import 'package:assistailab/features/auth/domain/entities/offline_authority_record.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/features/auth/domain/repositories/auth_repository.dart';
import 'package:assistailab/features/auth/domain/repositories/offline_authority_store.dart';
import 'package:assistailab/features/auth/domain/repositories/user_profile_cache.dart';
import 'package:assistailab/features/auth/domain/services/session_security_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  final now = DateTime.utc(2026, 9, 10, 12);

  group('generation-bound session lifecycle', () {
    test('bootstrap A -> login B -> bootstrap A cannot restore A', () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(_userA, _tokenFor(_userA, now, hours: 6));

      final meEntered = Completer<void>();
      final meRelease = Completer<User>();
      final loginBEntered = Completer<void>();
      final loginBRelease = Completer<AuthLoginResult>();
      harness.repository.getMeHandler = (_) {
        meEntered.complete();
        return meRelease.future;
      };
      harness.repository.loginHandler = (email, password) {
        loginBEntered.complete();
        return loginBRelease.future;
      };

      final bootstrap = harness.controller.bootstrap();
      await meEntered.future;
      final loginB = harness.controller.login('b@example.com', 'secret');
      await loginBEntered.future;
      loginBRelease.complete(
        AuthLoginResult(
          user: _userB,
          accessToken: _tokenFor(_userB, now, hours: 6),
        ),
      );
      expect(await loginB, isTrue);

      meRelease.complete(_userA);
      await bootstrap;

      final state = harness.controller.state;
      expect(state, isA<AuthenticatedOnline>());
      expect((state as AuthenticatedOnline).user.id, _userB.id);
      expect(harness.credentials.value!.accessToken,
          _tokenFor(_userB, now, hours: 6));
      await harness.dispose();
    });

    test('bootstrap A -> logout -> bootstrap A cannot restore A', () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(_userA, _tokenFor(_userA, now, hours: 6));
      final meEntered = Completer<void>();
      final meRelease = Completer<User>();
      harness.repository.getMeHandler = (_) {
        meEntered.complete();
        return meRelease.future;
      };

      final bootstrap = harness.controller.bootstrap();
      await meEntered.future;
      final logout = await harness.controller.logout();
      expect(logout.completed, isTrue);
      meRelease.complete(_userA);
      await bootstrap;

      expect(harness.controller.state, isA<SessionUnauthenticated>());
      expect(harness.controller.state.authenticatedScope, isNull);
      expect(harness.credentials.value, isNull);
      await harness.dispose();
    });

    test('login A -> login B: stale A cannot overwrite B', () async {
      final harness = _Harness(now);
      final aEntered = Completer<void>();
      final bEntered = Completer<void>();
      final aRelease = Completer<AuthLoginResult>();
      final bRelease = Completer<AuthLoginResult>();
      harness.repository.loginHandler = (email, password) {
        if (email.startsWith('a@')) {
          aEntered.complete();
          return aRelease.future;
        }
        bEntered.complete();
        return bRelease.future;
      };

      final loginA = harness.controller.login('a@example.com', 'secret');
      await aEntered.future;
      final loginB = harness.controller.login('b@example.com', 'secret');
      await bEntered.future;

      bRelease.complete(
        AuthLoginResult(
          user: _userB,
          accessToken: _tokenFor(_userB, now, hours: 6),
        ),
      );
      expect(await loginB, isTrue);
      aRelease.complete(
        AuthLoginResult(
          user: _userA,
          accessToken: _tokenFor(_userA, now, hours: 6),
        ),
      );
      expect(await loginA, isFalse);

      expect(
        (harness.controller.state as AuthenticatedOnline).user.id,
        _userB.id,
      );
      expect(harness.profile.value!.id, _userB.id);
      await harness.dispose();
    });

    test('old logout A cleanup cannot delete login B credential', () async {
      final harness = _Harness(now);
      harness.repository.loginHandler = (email, password) async {
        final user = email.startsWith('a@') ? _userA : _userB;
        return AuthLoginResult(
          user: user,
          accessToken: _tokenFor(user, now, hours: 6),
        );
      };
      expect(await harness.controller.login('a@example.com', 'secret'), isTrue);

      final deleteEntered = Completer<void>();
      final deleteRelease = Completer<void>();
      harness.credentials
        ..deleteEntered = deleteEntered
        ..deleteRelease = deleteRelease;

      final logout = harness.controller.logout();
      await deleteEntered.future;
      final loginB = harness.controller.login('b@example.com', 'secret');
      deleteRelease.complete();

      await logout;
      expect(await loginB, isTrue);
      expect(
        (harness.controller.state as AuthenticatedOnline).user.id,
        _userB.id,
      );
      expect(harness.credentials.value!.accessToken,
          _tokenFor(_userB, now, hours: 6));
      await harness.dispose();
    });
  });

  group('limited offline authority', () {
    test('valid proof restores AuthenticatedOfflineLimited', () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(
        _userA,
        _tokenFor(_userA, now, hours: 4),
        validatedAt: now.subtract(const Duration(hours: 2)),
      );
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();

      await harness.controller.bootstrap();

      expect(harness.controller.state, isA<AuthenticatedOfflineLimited>());
      expect(harness.controller.state.authenticatedUser?.id, _userA.id);
      await harness.dispose();
    });

    test('authority older than 8h fails closed', () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(
        _userA,
        _tokenFor(_userA, now, hours: 4),
        validatedAt: now.subtract(const Duration(hours: 8, seconds: 1)),
      );
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();

      await harness.controller.bootstrap();

      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      expect(harness.controller.state.authenticatedScope, isNull);
      await harness.dispose();
    });

    test('JWT exp passed fails closed before /auth/me', () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(
        _userA,
        _tokenFor(_userA, now, hours: -1),
        validatedAt: now.subtract(const Duration(hours: 2)),
      );

      await harness.controller.bootstrap();

      expect(harness.repository.getMeCalls, 0);
      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      await harness.dispose();
    });

    test('profile cache without credential never authenticates', () async {
      final harness = _Harness(now)..profile.value = _userA;

      await harness.controller.bootstrap();

      expect(harness.controller.state, isA<SessionUnauthenticated>());
      expect(harness.controller.state.authenticatedScope, isNull);
      await harness.dispose();
    });

    test('credential without authority metadata never authenticates', () async {
      final harness = _Harness(now);
      harness.credentials.value = StoredCredential(
        accessToken: _tokenFor(_userA, now, hours: 4),
        bindingId: 'binding-a',
      );
      harness.profile.value = _userA;
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();

      await harness.controller.bootstrap();

      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      expect(harness.credentials.value, isNotNull);
      await harness.dispose();
    });

    test('principal mismatch fails closed', () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(
        _userA,
        _tokenFor(_userA, now, hours: 4),
      );
      harness.profile.value = _userB;
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();

      await harness.controller.bootstrap();

      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      await harness.dispose();
    });

    test('offline limited blocks online commands and Sync credential capture',
        () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(_userA, _tokenFor(_userA, now, hours: 4));
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();
      await harness.controller.bootstrap();
      expect(harness.controller.state, isA<AuthenticatedOfflineLimited>());

      expect(
        harness.controller.acquireOnlineRequestCredential(),
        throwsA(isA<SessionRequestBlockedException>()),
      );
      expect(
        harness.controller.isCurrentOnlineGeneration(
          harness.controller.currentGeneration,
        ),
        isFalse,
      );
      await harness.dispose();
    });

    test('reconnect remains limited until /auth/me succeeds', () async {
      final harness = _Harness(now);
      harness.seedOnlineProof(_userA, _tokenFor(_userA, now, hours: 4));
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();
      await harness.controller.bootstrap();
      expect(await harness.controller.revalidateOnlineAuthority(), isFalse);
      expect(harness.controller.state, isA<AuthenticatedOfflineLimited>());

      harness.repository.getMeHandler = (_) async => _userA;
      expect(await harness.controller.revalidateOnlineAuthority(), isTrue);
      expect(harness.controller.state, isA<AuthenticatedOnline>());
      await harness.dispose();
    });
  });

  group('logout and runtime HTTP authority', () {
    test('delete failure stays logged out and tombstone blocks restart',
        () async {
      final harness = _Harness(now);
      harness.repository.loginHandler =
          (email, password) async => AuthLoginResult(
                user: _userA,
                accessToken: _tokenFor(_userA, now, hours: 6),
              );
      expect(await harness.controller.login('a@example.com', 'secret'), isTrue);
      final invalidatedGeneration = harness.controller.currentGeneration;
      harness.credentials.failDelete = true;

      final result = await harness.controller.logout();

      expect(result.completed, isTrue);
      expect(result.cleanupPending, isTrue);
      expect(harness.controller.state, isA<SessionUnauthenticated>());
      expect(harness.controller.state.authenticatedScope, isNull);
      expect(
        harness.controller.currentGeneration,
        greaterThan(invalidatedGeneration),
      );
      expect(harness.epoch.value?.vaultState, VaultState.cleanupPending);

      final restart = _Harness(
        now,
        credentials: harness.credentials,
        profile: harness.profile,
        authority: harness.authority,
        epoch: harness.epoch,
      );
      await restart.controller.bootstrap();
      expect(restart.controller.state, isA<SessionUnauthenticated>());
      expect(restart.repository.getMeCalls, 0);
      await restart.dispose();
      await harness.dispose();
    });

    test('401 current generation terminates session', () async {
      final harness = await _authenticatedHarness(now);
      final generation = harness.controller.currentGeneration;

      await harness.controller.handleAuthorizationFailure(
        sessionGeneration: generation,
        statusCode: 401,
        authorityRevalidation: false,
      );

      expect(harness.controller.state, isA<SessionUnauthenticated>());
      await harness.dispose();
    });

    test('401 stale generation cannot terminate B', () async {
      final harness = await _authenticatedHarness(now);
      final staleGeneration = harness.controller.currentGeneration - 1;

      await harness.controller.handleAuthorizationFailure(
        sessionGeneration: staleGeneration,
        statusCode: 401,
        authorityRevalidation: false,
      );

      expect(harness.controller.state, isA<AuthenticatedOnline>());
      await harness.dispose();
    });

    test('ordinary resource 403 does not logout', () async {
      final harness = await _authenticatedHarness(now);
      final generation = harness.controller.currentGeneration;

      await harness.controller.handleAuthorizationFailure(
        sessionGeneration: generation,
        statusCode: 403,
        authorityRevalidation: false,
      );

      expect(harness.controller.state, isA<AuthenticatedOnline>());
      await harness.dispose();
    });

    test('/auth/me 403 terminates current session', () async {
      final harness = await _authenticatedHarness(now);
      final generation = harness.controller.currentGeneration;

      await harness.controller.handleAuthorizationFailure(
        sessionGeneration: generation,
        statusCode: 403,
        authorityRevalidation: true,
      );

      expect(harness.controller.state, isA<SessionUnauthenticated>());
      await harness.dispose();
    });
  });

  group('legacy credentials', () {
    test(
        'jwt_token and user_preferences/auth_token are deleted, never promoted',
        () async {
      final harness = _Harness(now);
      harness.credentials
        ..legacyJwtPresent = true
        ..legacyPreferencesTokenPresent = true;

      await harness.controller.bootstrap();

      expect(harness.credentials.legacyJwtPresent, isFalse);
      expect(harness.credentials.legacyPreferencesTokenPresent, isFalse);
      expect(harness.credentials.value, isNull);
      expect(harness.repository.getMeCalls, 0);
      expect(harness.controller.state, isA<SessionUnauthenticated>());
      await harness.dispose();
    });
  });
}

Future<_Harness> _authenticatedHarness(DateTime now) async {
  final harness = _Harness(now);
  harness.repository.loginHandler = (email, password) async => AuthLoginResult(
        user: _userA,
        accessToken: _tokenFor(_userA, now, hours: 6),
      );
  expect(await harness.controller.login('a@example.com', 'secret'), isTrue);
  return harness;
}

const _userA = User(
  id: 'user-a',
  name: 'User A',
  email: 'a@example.com',
  role: 'TECHNICIAN',
  status: 'ACTIVE',
  organizationId: 'org-a',
);

const _userB = User(
  id: 'user-b',
  name: 'User B',
  email: 'b@example.com',
  role: 'TECHNICIAN',
  status: 'ACTIVE',
  organizationId: 'org-b',
);

String _tokenFor(User user, DateTime now, {required int hours}) {
  String encode(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  return '${encode(<String, Object?>{'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode(<String, Object?>{
        'sub': user.id,
        'role': user.role,
        'customerId': user.customerId,
        'organizationId': user.organizationId,
        'exp': now.add(Duration(hours: hours)).millisecondsSinceEpoch ~/ 1000,
      })}.signature';
}

final class _Harness {
  _Harness(
    this.now, {
    _MemoryCredentialStorage? credentials,
    _MemoryProfileCache? profile,
    _MemoryAuthorityStore? authority,
    _MemoryEpochStore? epoch,
  })  : credentials = credentials ?? _MemoryCredentialStorage(),
        profile = profile ?? _MemoryProfileCache(),
        authority = authority ?? _MemoryAuthorityStore(),
        epoch = epoch ?? _MemoryEpochStore(),
        repository = _ControlledAuthRepository(),
        manager = AuthScopedDatabaseManager.forTesting(
          opener: (_) async => _FakeDatabase(),
        ) {
    var bindingSequence = 0;
    controller = AuthNotifier(
      repository: repository,
      credentialStorage: this.credentials,
      profileCache: this.profile,
      offlineAuthorityStore: this.authority,
      credentialEpochStore: this.epoch,
      secureVaultMetadataStore: MemorySecureVaultMetadataStore(),
      securityValidator: validator,
      databaseManager: manager,
      nowUtc: () => now,
      credentialBindingIdFactory: () => 'binding-${++bindingSequence}',
      credentialIdFactory: () => 'credential-$bindingSequence',
      autoBootstrap: false,
    );
  }

  final DateTime now;
  final _MemoryCredentialStorage credentials;
  final _MemoryProfileCache profile;
  final _MemoryAuthorityStore authority;
  final _MemoryEpochStore epoch;
  final _ControlledAuthRepository repository;
  final AuthScopedDatabaseManager manager;
  final SessionSecurityValidator validator = const SessionSecurityValidator();
  late final AuthNotifier controller;

  void seedOnlineProof(
    User user,
    String token, {
    DateTime? validatedAt,
  }) {
    final credential = StoredCredential(
      accessToken: token,
      bindingId: 'binding-seed',
      credentialId: 'credential-seed',
      credentialGeneration: 1,
    );
    final timestamp = validatedAt ?? now.subtract(const Duration(hours: 1));
    final material = validator.validateOnline(
      user: user,
      credential: credential,
      nowUtc: timestamp,
    );
    credentials.value = credential;
    profile.value = user;
    authority.value = validator.createOfflineAuthorityRecord(
      user: user,
      credential: credential,
      material: material,
      validatedAtUtc: timestamp,
    );
    epoch.value = CredentialEpoch(
      activeCredentialId: credential.credentialId,
      activeCredentialGeneration: credential.credentialGeneration,
      vaultState: VaultState.active,
    );
  }

  Future<void> dispose() async {
    final closeGeneration = controller.currentGeneration + 1000000;
    controller.dispose();
    await manager.closeCurrentDatabase(
      sessionGeneration: closeGeneration,
    );
  }
}

final class _ControlledAuthRepository implements AuthRepository {
  Future<AuthLoginResult> Function(String email, String password)? loginHandler;
  Future<User> Function(String token)? getMeHandler;
  int getMeCalls = 0;

  @override
  Future<AuthLoginResult> login(String email, String password) {
    final handler = loginHandler;
    if (handler == null) {
      throw StateError('Unexpected login call.');
    }
    return handler(email, password);
  }

  @override
  Future<User> getCurrentUser(String accessToken) {
    getMeCalls++;
    final handler = getMeHandler;
    if (handler == null) {
      throw StateError('Unexpected /auth/me call.');
    }
    return handler(accessToken);
  }
}

final class _MemoryCredentialStorage implements CredentialStorage {
  StoredCredential? value;
  bool failDelete = false;
  bool legacyJwtPresent = false;
  bool legacyPreferencesTokenPresent = false;
  Completer<void>? deleteEntered;
  Completer<void>? deleteRelease;

  @override
  Future<StoredCredential?> readById(String credentialId) async =>
      value?.credentialId == credentialId ? value : null;

  @override
  Future<void> write(StoredCredential credential) async {
    value = credential;
  }

  @override
  Future<void> deleteById(String credentialId) async {
    if (failDelete) throw StateError('delete failed');
    if (value?.credentialId == credentialId) value = null;
  }

  @override
  Future<bool> deleteIfMatches({
    required String credentialId,
    required int credentialGeneration,
  }) async {
    if (deleteEntered != null && !deleteEntered!.isCompleted) {
      deleteEntered!.complete();
    }
    if (deleteRelease != null) await deleteRelease!.future;
    if (failDelete) throw StateError('delete failed');
    if (value?.credentialId != credentialId ||
        value?.credentialGeneration != credentialGeneration) {
      return false;
    }
    value = null;
    return true;
  }

  @override
  Future<void> purgeLegacyCredentials() async {
    legacyJwtPresent = false;
    legacyPreferencesTokenPresent = false;
  }
}

final class _MemoryProfileCache implements UserProfileCache {
  User? value;

  @override
  Future<User?> read() async => value;

  @override
  Future<void> write(User user) async {
    value = user;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

final class _MemoryAuthorityStore implements OfflineAuthorityStore {
  OfflineAuthorityRecord? value;

  @override
  Future<OfflineAuthorityRecord?> readByCredentialId(
          String credentialId) async =>
      value?.credentialId == credentialId ? value : null;

  @override
  Future<void> write(OfflineAuthorityRecord record) async {
    value = record;
  }

  @override
  Future<void> deleteByCredentialId(String credentialId) async {
    if (value?.credentialId == credentialId) value = null;
  }
}

final class _MemoryEpochStore implements CredentialEpochStore {
  CredentialEpoch? value;

  @override
  Future<CredentialEpoch?> read() async => value;

  @override
  Future<void> write(CredentialEpoch epoch) async {
    value = epoch;
  }
}

final class _FakeDatabase implements Database {
  bool _isOpen = true;

  @override
  bool get isOpen => _isOpen;

  @override
  Future<void> close() async {
    _isOpen = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TransportFailure implements Exception {
  const _TransportFailure();
}
