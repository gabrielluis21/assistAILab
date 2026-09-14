import 'dart:convert';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/security/credential_epoch.dart';
import 'package:assistailab/core/security/credential_epoch_store.dart';
import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
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
  final now = DateTime.utc(2026, 9, 11, 10);
  const validator = SessionSecurityValidator();

  User makeUser({required String status, String role = 'TECHNICIAN'}) {
    return User(
      id: 'user-001',
      name: 'Test Technician',
      email: 'tech@example.com',
      role: role,
      status: status,
      organizationId: 'org-123',
    );
  }

  String tokenFor(User user, DateTime refTime, {int hours = 4}) {
    String encode(Map<String, Object?> value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

    return '${encode(<String, Object?>{'alg': 'HS256', 'typ': 'JWT'})}.'
        '${encode(<String, Object?>{
          'sub': user.id,
          'role': user.role,
          'customerId': user.customerId,
          'organizationId': user.organizationId,
          'exp': refTime.add(Duration(hours: hours)).millisecondsSinceEpoch ~/
              1000,
        })}.signature';
  }

  CredentialEpoch epochFor(StoredCredential credential) => CredentialEpoch(
        activeCredentialId: credential.credentialId,
        activeCredentialGeneration: credential.credentialGeneration,
        vaultState: VaultState.active,
      );

  group('SessionSecurityValidator - status enforcement', () {
    test('1. ACTIVE succeeds online', () {
      final user = makeUser(status: 'ACTIVE');
      final credential = StoredCredential(
        accessToken: tokenFor(user, now),
        bindingId: 'bind-001',
      );

      final material = validator.validateOnline(
        user: user,
        credential: credential,
        nowUtc: now,
      );

      expect(material.scope, isNotNull);
      expect(material.credentialFingerprint, isNotEmpty);
    });

    test('2. " active " succeeds online after trim + uppercase normalization',
        () {
      final user = makeUser(status: ' active ');
      final credential = StoredCredential(
        accessToken: tokenFor(user, now),
        bindingId: 'bind-001',
      );

      final material = validator.validateOnline(
        user: user,
        credential: credential,
        nowUtc: now,
      );

      expect(material.scope, isNotNull);
      expect(material.credentialFingerprint, isNotEmpty);
    });

    test('3. PENDING, SUSPENDED, and DISABLED rejected online', () {
      for (final nonActiveStatus in const [
        'PENDING',
        'SUSPENDED',
        'DISABLED'
      ]) {
        final user = makeUser(status: nonActiveStatus);
        final credential = StoredCredential(
          accessToken: tokenFor(user, now),
          bindingId: 'bind-001',
        );

        expect(
          () => validator.validateOnline(
            user: user,
            credential: credential,
            nowUtc: now,
          ),
          throwsA(
            isA<SessionValidationException>().having(
              (e) => e.message,
              'message',
              'User account is not active.',
            ),
          ),
          reason: 'Status $nonActiveStatus must be rejected online',
        );
      }
    });

    test('4. PENDING, SUSPENDED, and DISABLED rejected offline', () {
      final activeUser = makeUser(status: 'ACTIVE');
      final credential = StoredCredential(
        accessToken: tokenFor(activeUser, now),
        bindingId: 'bind-001',
      );
      final activeMaterial = validator.validateOnline(
        user: activeUser,
        credential: credential,
        nowUtc: now.subtract(const Duration(hours: 1)),
      );
      final authority = validator.createOfflineAuthorityRecord(
        user: activeUser,
        credential: credential,
        material: activeMaterial,
        validatedAtUtc: now.subtract(const Duration(hours: 1)),
      );

      for (final nonActiveStatus in const [
        'PENDING',
        'SUSPENDED',
        'DISABLED'
      ]) {
        final cachedUser = makeUser(status: nonActiveStatus);

        expect(
          () => validator.validateOffline(
            cachedUser: cachedUser,
            credential: credential,
            authority: authority,
            epoch: epochFor(credential),
            nowUtc: now,
          ),
          throwsA(
            isA<SessionValidationException>().having(
              (e) => e.message,
              'message',
              'User account is not active.',
            ),
          ),
          reason: 'Cached status $nonActiveStatus must be rejected offline',
        );
      }
    });

    test('5. empty status rejected online and offline', () {
      final credential = StoredCredential(
        accessToken: tokenFor(makeUser(status: 'ACTIVE'), now),
        bindingId: 'bind-001',
      );

      for (final emptyStatus in const ['', '   ', '\t\n']) {
        final user = makeUser(status: emptyStatus);

        expect(
          () => validator.validateOnline(
            user: user,
            credential: credential,
            nowUtc: now,
          ),
          throwsA(
            isA<SessionValidationException>().having(
              (e) => e.message,
              'message',
              'User account is not active.',
            ),
          ),
          reason: 'Empty status "$emptyStatus" must be rejected online',
        );
      }
    });

    test('6. unknown status rejected', () {
      for (final unknownStatus in const [
        'ARCHIVED',
        'DELETED',
        'BANNED',
        'UNKNOWN',
        'INACTIVE'
      ]) {
        final user = makeUser(status: unknownStatus);
        final credential = StoredCredential(
          accessToken: tokenFor(user, now),
          bindingId: 'bind-001',
        );

        expect(
          () => validator.validateOnline(
            user: user,
            credential: credential,
            nowUtc: now,
          ),
          throwsA(
            isA<SessionValidationException>().having(
              (e) => e.message,
              'message',
              'User account is not active.',
            ),
          ),
          reason: 'Unknown status $unknownStatus must be rejected online',
        );
      }
    });
  });

  group('Session lifecycle integration with non-ACTIVE status', () {
    test(
        '7. /auth/me returning a non-ACTIVE user cannot publish AuthenticatedOnline',
        () async {
      final harness = _TestHarness(now);
      final activeUser = makeUser(status: 'ACTIVE');
      final pendingUser = makeUser(status: 'PENDING');
      final validToken = tokenFor(activeUser, now, hours: 4);

      final credential = StoredCredential(
        accessToken: validToken,
        bindingId: 'bind-lifecycle-1',
      );
      harness.credentials.value = credential;
      harness.epoch.value = epochFor(credential);
      // /auth/me returns non-ACTIVE user
      harness.repository.getMeHandler = (_) async => pendingUser;

      await harness.controller.bootstrap();

      expect(harness.controller.state, isNot(isA<AuthenticatedOnline>()));
      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      expect(harness.controller.state, isA<SessionFailure>());
      expect(
        (harness.controller.state as SessionFailure).error,
        isA<SessionValidationException>().having(
          (e) => e.message,
          'message',
          'User account is not active.',
        ),
      );
      expect(harness.controller.state.authenticatedScope, isNull);
      await harness.dispose();
    });

    test('cached non-ACTIVE user cannot publish AuthenticatedOfflineLimited',
        () async {
      final harness = _TestHarness(now);
      final activeUser = makeUser(status: 'ACTIVE');
      final suspendedUser = makeUser(status: 'SUSPENDED');
      final validToken = tokenFor(activeUser, now, hours: 4);
      final credential = StoredCredential(
        accessToken: validToken,
        bindingId: 'bind-lifecycle-2',
      );

      final material = validator.validateOnline(
        user: activeUser,
        credential: credential,
        nowUtc: now.subtract(const Duration(hours: 1)),
      );
      final authority = validator.createOfflineAuthorityRecord(
        user: activeUser,
        credential: credential,
        material: material,
        validatedAtUtc: now.subtract(const Duration(hours: 1)),
      );

      harness.credentials.value = credential;
      harness.authority.value = authority;
      harness.epoch.value = epochFor(credential);
      // Cached user has become SUSPENDED
      harness.profile.value = suspendedUser;
      // Remote server is unavailable
      harness.repository.getMeHandler =
          (_) => throw const _TestTransportFailure();

      await harness.controller.bootstrap();

      expect(
          harness.controller.state, isNot(isA<AuthenticatedOfflineLimited>()));
      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      expect(harness.controller.state, isA<SessionFailure>());
      expect(
        (harness.controller.state as SessionFailure).error,
        isA<SessionValidationException>().having(
          (e) => e.message,
          'message',
          'User account is not active.',
        ),
      );
      expect(harness.controller.state.authenticatedScope, isNull);
      await harness.dispose();
    });
  });
}

final class _TestHarness {
  _TestHarness(this.now)
      : credentials = _MemoryCredentialStorage(),
        profile = _MemoryProfileCache(),
        authority = _MemoryAuthorityStore(),
        epoch = _MemoryEpochStore(),
        repository = _MockAuthRepository(),
        manager = AuthScopedDatabaseManager.forTesting(
          opener: (_) async => _MockDatabase(),
        ) {
    controller = AuthNotifier(
      repository: repository,
      credentialStorage: credentials,
      profileCache: profile,
      offlineAuthorityStore: authority,
      credentialEpochStore: epoch,
      securityValidator: const SessionSecurityValidator(),
      databaseManager: manager,
      nowUtc: () => now,
      credentialBindingIdFactory: () => 'binding-test',
      credentialIdFactory: () => 'credential-test',
      autoBootstrap: false,
    );
  }

  final DateTime now;
  final _MemoryCredentialStorage credentials;
  final _MemoryProfileCache profile;
  final _MemoryAuthorityStore authority;
  final _MemoryEpochStore epoch;
  final _MockAuthRepository repository;
  final AuthScopedDatabaseManager manager;
  late final AuthNotifier controller;

  Future<void> dispose() async {
    controller.dispose();
    await manager.closeCurrentDatabase(
      sessionGeneration: controller.currentGeneration + 1000000,
    );
  }
}

final class _MockAuthRepository implements AuthRepository {
  Future<User> Function(String token)? getMeHandler;

  @override
  Future<User> getCurrentUser(String token) async {
    if (getMeHandler != null) {
      return getMeHandler!(token);
    }
    throw UnimplementedError();
  }

  @override
  Future<AuthLoginResult> login(String email, String password) async {
    throw UnimplementedError();
  }
}

final class _MemoryCredentialStorage implements CredentialStorage {
  StoredCredential? value;

  @override
  Future<StoredCredential?> readById(String credentialId) async =>
      value?.credentialId == credentialId ? value : null;

  @override
  Future<void> write(StoredCredential credential) async {
    value = credential;
  }

  @override
  Future<void> deleteById(String credentialId) async {
    if (value?.credentialId == credentialId) value = null;
  }

  @override
  Future<bool> deleteIfMatches({
    required String credentialId,
    required int credentialGeneration,
  }) async {
    if (value?.credentialId != credentialId ||
        value?.credentialGeneration != credentialGeneration) {
      return false;
    }
    value = null;
    return true;
  }

  @override
  Future<void> purgeLegacyCredentials() async {}
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

final class _MockDatabase implements Database {
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

final class _TestTransportFailure implements Exception {
  const _TestTransportFailure();
}
