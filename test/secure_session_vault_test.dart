import 'dart:convert';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/security/credential_epoch.dart';
import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/core/security/hive_credential_storage.dart';
import 'package:assistailab/core/security/revocation_fence.dart';
import 'package:assistailab/core/security/secure_key_value_storage.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/data/datasources/secure_session_stores.dart';
import 'package:assistailab/features/auth/domain/entities/offline_authority_record.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/features/auth/domain/repositories/auth_repository.dart';
import 'package:assistailab/features/auth/domain/repositories/user_profile_cache.dart';
import 'package:assistailab/features/auth/domain/services/session_security_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  final now = DateTime.utc(2026, 9, 14, 12);

  group('secure record stores', () {
    test('credential, authority and Epoch write/read/delete round-trip',
        () async {
      final backend = _FaultingSecureStorage();
      final stores = _storesFor(backend);
      final credential = _credential(_userA, now);
      final authority = _authority(_userA, credential, now);
      final epoch = _epoch(credential);

      await stores.credentialStorage.write(credential);
      await stores.offlineAuthorityStore.write(authority);
      await stores.credentialEpochStore.write(epoch);

      final restoredCredential =
          await stores.credentialStorage.readById(credential.credentialId);
      final restoredAuthority = await stores.offlineAuthorityStore
          .readByCredentialId(credential.credentialId);
      final restoredEpoch = await stores.credentialEpochStore.read();
      expect(restoredCredential?.toJson(), credential.toJson());
      expect(restoredAuthority?.toJson(), authority.toJson());
      expect(restoredEpoch?.toJson(), epoch.toJson());
      expect(
        backend.values.keys,
        containsAll(<String>{
          '${NativeSecureCredentialStorage.keyPrefix}credential-a',
          '${NativeSecureOfflineAuthorityStore.keyPrefix}credential-a',
          NativeSecureCredentialEpochStore.epochKey,
        }),
      );

      await stores.offlineAuthorityStore.deleteByCredentialId(
        credential.credentialId,
      );
      await stores.credentialStorage.deleteById(credential.credentialId);
      expect(
        await stores.credentialStorage.readById(credential.credentialId),
        isNull,
      );
      expect(
        await stores.offlineAuthorityStore.readByCredentialId(
          credential.credentialId,
        ),
        isNull,
      );
    });

    test('revocation fence round-trip uses the secure Vault namespace',
        () async {
      final backend = _FaultingSecureStorage();
      final stores = _storesFor(backend);
      final fence = RevocationFence(
        credentialId: 'credential-a',
        credentialGeneration: 7,
      );

      await stores.secureVaultMetadataStore.writeRevocationFence(fence);

      expect(
        (await stores.secureVaultMetadataStore.readRevocationFence())?.toJson(),
        fence.toJson(),
      );
      expect(
        backend.values.keys,
        contains(NativeSecureVaultMetadataStore.revocationFenceKey),
      );
      expect(
        await stores.secureVaultMetadataStore.containsSessionArtifacts(),
        isTrue,
      );

      await stores.secureVaultMetadataStore.deleteRevocationFence();
      expect(
        await stores.secureVaultMetadataStore.readRevocationFence(),
        isNull,
      );
    });

    test('artifact discovery ignores keys outside known Vault families',
        () async {
      final backend = _FaultingSecureStorage()
        ..values['unrelated.application.key'] = 'value';
      final stores = _storesFor(backend);

      expect(
        await stores.secureVaultMetadataStore.containsSessionArtifacts(),
        isFalse,
      );

      backend.values['${NativeSecureCredentialStorage.keyPrefix}residual'] =
          'corrupt-but-present';
      expect(
        await stores.secureVaultMetadataStore.containsSessionArtifacts(),
        isTrue,
      );
    });

    test('malformed records fail closed', () async {
      final backend = _FaultingSecureStorage();
      final stores = _storesFor(backend);
      backend.values
        ..['${NativeSecureCredentialStorage.keyPrefix}bad'] = 'not-json'
        ..['${NativeSecureOfflineAuthorityStore.keyPrefix}bad'] = '[]'
        ..[NativeSecureCredentialEpochStore.epochKey] = '{'
        ..[NativeSecureVaultMetadataStore.revocationFenceKey] = '{';

      await expectLater(
        stores.credentialStorage.readById('bad'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        stores.offlineAuthorityStore.readByCredentialId('bad'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        stores.credentialEpochStore.read(),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        stores.secureVaultMetadataStore.readRevocationFence(),
        throwsA(isA<FormatException>()),
      );
    });

    test('unsupported schemas fail closed', () async {
      final backend = _FaultingSecureStorage();
      final stores = _storesFor(backend);
      final credential = _credential(_userA, now);
      final authority = _authority(_userA, credential, now);
      final epoch = _epoch(credential);
      backend.values
        ..['${NativeSecureCredentialStorage.keyPrefix}credential-a'] =
            jsonEncode(<String, Object>{
          ...credential.toJson(),
          'schemaVersion': 999,
        })
        ..['${NativeSecureOfflineAuthorityStore.keyPrefix}credential-a'] =
            jsonEncode(<String, Object>{
          ...authority.toJson(),
          'schemaVersion': 999,
        })
        ..[NativeSecureCredentialEpochStore.epochKey] =
            jsonEncode(<String, Object?>{
          ...epoch.toJson(),
          'schemaVersion': 999,
        })
        ..[NativeSecureVaultMetadataStore.revocationFenceKey] =
            jsonEncode(<String, Object>{
          ...RevocationFence(
            credentialId: 'credential-a',
            credentialGeneration: 1,
          ).toJson(),
          'schemaVersion': 999,
        });

      await expectLater(
        stores.credentialStorage.readById('credential-a'),
        throwsA(isA<CredentialStorageFormatException>()),
      );
      await expectLater(
        stores.offlineAuthorityStore.readByCredentialId('credential-a'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        stores.credentialEpochStore.read(),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        stores.secureVaultMetadataStore.readRevocationFence(),
        throwsA(isA<FormatException>()),
      );
    });

    test('unavailable secure storage propagates and bootstrap fails closed',
        () async {
      final backend = _FaultingSecureStorage()..unavailable = true;
      final stores = _storesFor(backend);

      await expectLater(
        stores.credentialEpochStore.read(),
        throwsA(isA<SecureStorageUnavailableException>()),
      );

      final harness = _VaultHarness(now, backend: backend);
      await harness.controller.bootstrap();
      expect(harness.controller.state, isA<SessionFailure>());
      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      await harness.dispose();
    });

    test('corrupt Epoch blocks authenticated replacement without reset',
        () async {
      final harness = await _loggedInHarness(now);
      harness.backend.values[NativeSecureCredentialEpochStore.epochKey] =
          '{corrupt';
      harness.repository.loginHandler = (_) async => AuthLoginResult(
            user: _userB,
            accessToken: _tokenFor(_userB, now),
          );

      expect(
          await harness.controller.login('b@example.com', 'secret'), isFalse);
      expect(
        harness.backend.values[NativeSecureCredentialEpochStore.epochKey],
        '{corrupt',
      );
      expect(
        harness.backend.values.keys,
        isNot(contains(
          '${NativeSecureCredentialStorage.keyPrefix}credential-2',
        )),
      );
      expect(harness.controller.state, isA<SessionFailure>());
      await harness.dispose();
    });
  });

  group('offline authority coherence', () {
    test('valid ACTIVE credential/authority/Epoch succeeds', () {
      final credential = _credential(_userA, now);
      final authority = _authority(_userA, credential, now);

      final result = const SessionSecurityValidator().validateOffline(
        cachedUser: _userA,
        credential: credential,
        authority: authority,
        epoch: _epoch(credential),
        nowUtc: now,
      );

      expect(result.material.scope.canonicalKey, authority.scopeKey);
    });

    for (final mismatch in <_AuthorityMismatch>[
      const _AuthorityMismatch('wrong bindingId', bindingId: 'wrong-binding'),
      const _AuthorityMismatch('wrong credentialId', credentialId: 'wrong-id'),
      const _AuthorityMismatch('wrong generation', credentialGeneration: 2),
      const _AuthorityMismatch('wrong principal', principalId: 'wrong-user'),
      const _AuthorityMismatch('wrong AuthScope', scopeKey: 'wrong-scope'),
      const _AuthorityMismatch('wrong fingerprint', fingerprint: 'wrong-hash'),
      _AuthorityMismatch(
        'wrong JWT expiration',
        jwtExpiresAtUtc: DateTime.utc(2026, 9, 14, 19),
      ),
    ]) {
      test('${mismatch.name} is rejected', () {
        final credential = _credential(_userA, now);
        final authority = _authority(
          _userA,
          credential,
          now,
          mismatch: mismatch,
        );
        expect(
          () => const SessionSecurityValidator().validateOffline(
            cachedUser: _userA,
            credential: credential,
            authority: authority,
            epoch: _epoch(credential),
            nowUtc: now,
          ),
          throwsA(isA<SessionValidationException>()),
        );
      });
    }

    test('wrong Epoch credentialId and generation are rejected', () {
      final credential = _credential(_userA, now);
      final authority = _authority(_userA, credential, now);
      for (final epoch in <CredentialEpoch>[
        CredentialEpoch(
          activeCredentialId: 'other-id',
          activeCredentialGeneration: credential.credentialGeneration,
          vaultState: VaultState.active,
        ),
        CredentialEpoch(
          activeCredentialId: credential.credentialId,
          activeCredentialGeneration: 99,
          vaultState: VaultState.active,
        ),
      ]) {
        expect(
          () => const SessionSecurityValidator().validateOffline(
            cachedUser: _userA,
            credential: credential,
            authority: authority,
            epoch: epoch,
            nowUtc: now,
          ),
          throwsA(isA<SessionValidationException>()),
        );
      }
    });
  });

  group('login and safe replacement', () {
    test('fresh empty Vault creates generation one and commits Epoch last',
        () async {
      final harness = _VaultHarness(now)
        ..repository.loginHandler = (_) async => AuthLoginResult(
              user: _userA,
              accessToken: _tokenFor(_userA, now),
            );

      expect(await harness.controller.login('a@example.com', 'secret'), isTrue);
      final epoch = await harness.stores.credentialEpochStore.read();
      final credential = await harness.stores.credentialStorage
          .readById(epoch!.activeCredentialId!);
      final authority = await harness.stores.offlineAuthorityStore
          .readByCredentialId(epoch.activeCredentialId!);
      expect(epoch.vaultState, VaultState.active);
      expect(credential?.credentialGeneration, 1);
      expect(authority?.credentialGeneration, 1);
      expect(harness.controller.state, isA<AuthenticatedOnline>());
      final epochWrite = harness.backend.events.lastIndexWhere(
        (event) =>
            event == 'write:${NativeSecureCredentialEpochStore.epochKey}',
      );
      final authorityWrite = harness.backend.events.indexWhere(
        (event) => event
            .startsWith('write:${NativeSecureOfflineAuthorityStore.keyPrefix}'),
      );
      expect(epochWrite, greaterThan(authorityWrite));
      await harness.dispose();
    });

    test('authenticated replacement with missing Epoch fails closed', () async {
      final harness = await _loggedInHarness(now);
      final authenticatedGeneration = harness.controller.currentGeneration;
      final epochA = await harness.stores.credentialEpochStore.read();
      harness.backend.values.remove(
        NativeSecureCredentialEpochStore.epochKey,
      );
      harness.repository.loginHandler = (_) async => AuthLoginResult(
            user: _userB,
            accessToken: _tokenFor(_userB, now),
          );

      expect(
          await harness.controller.login('b@example.com', 'secret'), isFalse);

      expect(harness.controller.state, isA<SessionFailure>());
      expect(
        harness.controller.currentGeneration,
        greaterThan(authenticatedGeneration),
      );
      expect(await harness.stores.credentialEpochStore.read(), isNull);
      expect(
        harness.backend.values.keys,
        isNot(contains(
          '${NativeSecureCredentialStorage.keyPrefix}credential-2',
        )),
      );
      expect(
        await harness.stores.credentialStorage.readById(
          epochA!.activeCredentialId!,
        ),
        isNotNull,
      );

      expect(
          await harness.controller.login('b@example.com', 'secret'), isFalse);
      expect(await harness.stores.credentialEpochStore.read(), isNull);
      expect(
        harness.backend.values.keys,
        isNot(contains(
          '${NativeSecureCredentialStorage.keyPrefix}credential-2',
        )),
      );
      await harness.dispose();
    });

    test('missing Epoch with residual artifacts fails across process restart',
        () async {
      final backend = _FaultingSecureStorage();
      final first = await _loggedInHarness(now, backend: backend);
      final epochA = await first.stores.credentialEpochStore.read();
      final credentialKeyA =
          '${NativeSecureCredentialStorage.keyPrefix}${epochA!.activeCredentialId}';
      final authorityKeyA =
          '${NativeSecureOfflineAuthorityStore.keyPrefix}${epochA.activeCredentialId}';
      final credentialA = backend.values[credentialKeyA];
      final authorityA = backend.values[authorityKeyA];
      backend.values.remove(NativeSecureCredentialEpochStore.epochKey);
      await first.dispose();

      final restarted = _VaultHarness(
        now,
        backend: backend,
        initialCredentialSequence: 1,
      )..repository.loginHandler = (_) async => AuthLoginResult(
            user: _userB,
            accessToken: _tokenFor(_userB, now),
          );

      expect(
        await restarted.controller.login('b@example.com', 'secret'),
        isFalse,
      );
      expect(restarted.controller.state, isA<SessionFailure>());
      expect(
        restarted.controller.state,
        isNot(isA<AuthenticatedSession>()),
      );
      expect(
        backend.values.keys,
        isNot(contains(
          '${NativeSecureCredentialStorage.keyPrefix}credential-2',
        )),
      );
      expect(
        backend.values.keys,
        isNot(contains(
          '${NativeSecureOfflineAuthorityStore.keyPrefix}credential-2',
        )),
      );
      expect(
        backend.values.keys,
        isNot(contains(NativeSecureCredentialEpochStore.epochKey)),
      );
      expect(backend.values[credentialKeyA], credentialA);
      expect(backend.values[authorityKeyA], authorityA);
      await restarted.dispose();
    });

    test('partial credential without ACTIVE Epoch never bootstraps', () async {
      final harness = _VaultHarness(now);
      final credential = _credential(_userA, now);
      await harness.stores.credentialStorage.write(credential);
      harness.profile.value = _userA;

      await harness.controller.bootstrap();

      expect(harness.repository.getMeCalls, 0);
      expect(harness.controller.state, isA<SessionUnauthenticated>());
      await harness.dispose();
    });

    test(
        'partial credential and authority without ACTIVE Epoch never bootstrap',
        () async {
      final harness = _VaultHarness(now);
      final credential = _credential(_userA, now);
      await harness.stores.credentialStorage.write(credential);
      await harness.stores.offlineAuthorityStore.write(
        _authority(_userA, credential, now),
      );
      harness.profile.value = _userA;

      await harness.controller.bootstrap();

      expect(harness.repository.getMeCalls, 0);
      expect(harness.controller.state, isA<SessionUnauthenticated>());
      await harness.dispose();
    });

    for (final failure in <_ReplacementFailure>[
      _ReplacementFailure.credentialWrite,
      _ReplacementFailure.authorityWrite,
      _ReplacementFailure.verification,
      _ReplacementFailure.epochCommit,
    ]) {
      test('A remains authoritative on ${failure.name}', () async {
        final harness = await _loggedInHarness(now);
        final epochA = await harness.stores.credentialEpochStore.read();
        const idB = 'credential-2';
        switch (failure) {
          case _ReplacementFailure.credentialWrite:
            harness.backend.failWriteKeys.add(
              '${NativeSecureCredentialStorage.keyPrefix}$idB',
            );
          case _ReplacementFailure.authorityWrite:
            harness.backend.failWriteKeys.add(
              '${NativeSecureOfflineAuthorityStore.keyPrefix}$idB',
            );
          case _ReplacementFailure.verification:
            harness.backend.corruptAfterWrite[
                '${NativeSecureCredentialStorage.keyPrefix}$idB'] = 'not-json';
          case _ReplacementFailure.epochCommit:
            harness.backend.failWriteKeys.add(
              NativeSecureCredentialEpochStore.epochKey,
            );
        }
        harness.repository.loginHandler = (_) async => AuthLoginResult(
              user: _userB,
              accessToken: _tokenFor(_userB, now),
            );

        expect(
          await harness.controller.login('b@example.com', 'secret'),
          isFalse,
        );
        harness.backend
          ..failWriteKeys.clear()
          ..corruptAfterWrite.clear()
          ..readOverrides.clear();
        final currentEpoch = await harness.stores.credentialEpochStore.read();
        expect(currentEpoch?.toJson(), epochA?.toJson());
        expect(
          await harness.stores.credentialStorage.readById(
            epochA!.activeCredentialId!,
          ),
          isNotNull,
        );
        await harness.dispose();
      });
    }

    test('A to B happy path increments secure generation and deletes A',
        () async {
      final harness = await _loggedInHarness(now);
      final epochA = await harness.stores.credentialEpochStore.read();
      harness.repository.loginHandler = (_) async => AuthLoginResult(
            user: _userB,
            accessToken: _tokenFor(_userB, now),
          );

      expect(await harness.controller.login('b@example.com', 'secret'), isTrue);

      final epochB = await harness.stores.credentialEpochStore.read();
      expect(epochB?.activeCredentialId, 'credential-2');
      expect(epochB?.activeCredentialGeneration, 2);
      expect(
        await harness.stores.credentialStorage.readById(
          epochA!.activeCredentialId!,
        ),
        isNull,
      );
      expect(
        await harness.stores.offlineAuthorityStore.readByCredentialId(
          epochA.activeCredentialId!,
        ),
        isNull,
      );
      await harness.dispose();
    });

    test('crash after Epoch commit leaves B authoritative and A unusable',
        () async {
      final harness = await _loggedInHarness(now);
      final epochA = await harness.stores.credentialEpochStore.read();
      final credentialA = await harness.stores.credentialStorage
          .readById(epochA!.activeCredentialId!);
      final authorityA = await harness.stores.offlineAuthorityStore
          .readByCredentialId(epochA.activeCredentialId!);
      harness.backend.failDeleteKeys.addAll(<String>{
        '${NativeSecureCredentialStorage.keyPrefix}${epochA.activeCredentialId}',
        '${NativeSecureOfflineAuthorityStore.keyPrefix}${epochA.activeCredentialId}',
      });
      harness.repository.loginHandler = (_) async => AuthLoginResult(
            user: _userB,
            accessToken: _tokenFor(_userB, now),
          );

      expect(await harness.controller.login('b@example.com', 'secret'), isTrue);
      final epochB = await harness.stores.credentialEpochStore.read();
      expect(epochB?.activeCredentialId, 'credential-2');
      expect(
        () => const SessionSecurityValidator().validateOffline(
          cachedUser: _userA,
          credential: credentialA!,
          authority: authorityA!,
          epoch: epochB!,
          nowUtc: now,
        ),
        throwsA(isA<SessionValidationException>()),
      );
      await harness.dispose();
    });
  });

  group('offline bootstrap and anti-resurrection', () {
    test('valid secure vault restores OfflineLimited', () async {
      final harness = _VaultHarness(now);
      await harness.seedActive(_userA);
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();

      await harness.controller.bootstrap();

      expect(harness.controller.state, isA<AuthenticatedOfflineLimited>());
      await harness.dispose();
    });

    test('expired JWT, authority older than 8h and cached non-ACTIVE fail',
        () async {
      final cases = <Future<_VaultHarness> Function()>[
        () async {
          final harness = _VaultHarness(now);
          await harness.seedActive(
            _userA,
            tokenHours: -1,
            validatedAt: now.subtract(const Duration(hours: 2)),
          );
          return harness;
        },
        () async {
          final harness = _VaultHarness(now);
          await harness.seedActive(
            _userA,
            validatedAt: now.subtract(const Duration(hours: 9)),
          );
          return harness;
        },
        () async {
          final harness = _VaultHarness(now);
          await harness.seedActive(_userA);
          harness.profile.value = _suspendedUser;
          return harness;
        },
      ];
      for (final createHarness in cases) {
        final harness = await createHarness();
        harness.repository.getMeHandler =
            (_) => throw const _TransportFailure();
        await harness.controller.bootstrap();
        expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
        await harness.dispose();
      }
    });

    for (final state in <VaultState?>[
      null,
      VaultState.revoked,
      VaultState.cleanupPending,
    ]) {
      test('${state?.wireName ?? 'missing'} Epoch cannot restore authority',
          () async {
        final harness = _VaultHarness(now);
        await harness.seedActive(_userA);
        final active = await harness.stores.credentialEpochStore.read();
        if (state == null) {
          harness.backend.values.remove(
            NativeSecureCredentialEpochStore.epochKey,
          );
        } else {
          await harness.stores.credentialEpochStore.write(
            CredentialEpoch(
              activeCredentialId: active!.activeCredentialId,
              activeCredentialGeneration: active.activeCredentialGeneration,
              vaultState: state,
            ),
          );
        }
        harness.repository.getMeHandler =
            (_) => throw const _TransportFailure();

        await harness.controller.bootstrap();

        expect(harness.repository.getMeCalls, 0);
        expect(harness.controller.state, isA<SessionUnauthenticated>());
        expect(harness.manager.currentHandle, isNull);
        await harness.dispose();
      });
    }

    test('stale A authority and operational DB cannot bypass Epoch B',
        () async {
      final harness = _VaultHarness(now);
      final credentialA = _credential(_userA, now);
      await harness.stores.credentialStorage.write(credentialA);
      await harness.stores.offlineAuthorityStore.write(
        _authority(_userA, credentialA, now),
      );
      final credentialB = _credential(
        _userB,
        now,
        credentialId: 'credential-b',
        generation: 2,
      );
      await harness.stores.credentialStorage.write(credentialB);
      await harness.stores.credentialEpochStore.write(_epoch(credentialB));
      harness.profile.value = _userA;
      harness.repository.getMeHandler = (_) => throw const _TransportFailure();

      await harness.controller.bootstrap();

      expect(harness.controller.state, isNot(isA<AuthenticatedSession>()));
      expect(harness.manager.currentHandle, isNull);
      await harness.dispose();
    });
  });

  group('logout revocation', () {
    test('Epoch is revoked before authority and credential deletion', () async {
      final harness = await _loggedInHarness(now);
      final epoch = await harness.stores.credentialEpochStore.read();
      harness.backend.events.clear();

      final result = await harness.controller.logout();

      expect(result.completed, isTrue);
      expect(result.cleanupPending, isFalse);
      final fenceWrite = harness.backend.events.indexOf(
        'write:${NativeSecureVaultMetadataStore.revocationFenceKey}',
      );
      final fenceReadBack = harness.backend.events.indexOf(
        'read:${NativeSecureVaultMetadataStore.revocationFenceKey}',
        fenceWrite + 1,
      );
      final epochWrite = harness.backend.events.indexOf(
        'write:${NativeSecureCredentialEpochStore.epochKey}',
      );
      final authorityDelete = harness.backend.events.indexOf(
        'delete:${NativeSecureOfflineAuthorityStore.keyPrefix}${epoch!.activeCredentialId}',
      );
      final credentialDelete = harness.backend.events.indexOf(
        'delete:${NativeSecureCredentialStorage.keyPrefix}${epoch.activeCredentialId}',
      );
      final fenceDelete = harness.backend.events.indexOf(
        'delete:${NativeSecureVaultMetadataStore.revocationFenceKey}',
      );
      expect(fenceWrite, greaterThanOrEqualTo(0));
      expect(fenceReadBack, greaterThan(fenceWrite));
      expect(epochWrite, greaterThan(fenceReadBack));
      expect(authorityDelete, greaterThan(epochWrite));
      expect(credentialDelete, greaterThan(epochWrite));
      expect(fenceDelete, greaterThan(credentialDelete));
      expect(
        (await harness.stores.credentialEpochStore.read())?.vaultState,
        VaultState.revoked,
      );
      expect(
        await harness.stores.secureVaultMetadataStore.readRevocationFence(),
        isNull,
      );
      await harness.dispose();
    });

    test('failed REVOKED write remains fenced across process restart',
        () async {
      final backend = _FaultingSecureStorage();
      final first = await _loggedInHarness(now, backend: backend);
      final authenticatedGeneration = first.controller.currentGeneration;
      final epoch = await first.stores.credentialEpochStore.read();
      backend
        ..events.clear()
        ..failWriteKeys.add(NativeSecureCredentialEpochStore.epochKey);

      final result = await first.controller.logout();

      expect(result.completed, isTrue);
      expect(result.cleanupPending, isTrue);
      expect(first.controller.state, isA<SessionUnauthenticated>());
      expect(
        first.controller.currentGeneration,
        greaterThan(authenticatedGeneration),
      );
      final fence =
          await first.stores.secureVaultMetadataStore.readRevocationFence();
      expect(fence?.credentialId, epoch!.activeCredentialId);
      expect(
        fence?.credentialGeneration,
        epoch.activeCredentialGeneration,
      );
      expect(fence?.state, RevocationFenceState.revokeIntent);
      expect(
        backend.events,
        isNot(contains(
          'delete:${NativeSecureOfflineAuthorityStore.keyPrefix}${epoch.activeCredentialId}',
        )),
      );
      expect(
        backend.events,
        isNot(contains(
          'delete:${NativeSecureCredentialStorage.keyPrefix}${epoch.activeCredentialId}',
        )),
      );
      expect(
        jsonDecode(
          backend.values[NativeSecureCredentialEpochStore.epochKey]!,
        )['vaultState'],
        VaultState.active.wireName,
      );
      await first.dispose();

      final restarted = _VaultHarness(now, backend: backend)
        ..repository.getMeHandler = (_) async => _userA;
      await restarted.controller.bootstrap();
      expect(restarted.repository.getMeCalls, 0);
      expect(restarted.manager.currentHandle, isNull);
      expect(restarted.controller.state, isNot(isA<AuthenticatedSession>()));
      expect(
        await restarted.stores.secureVaultMetadataStore.readRevocationFence(),
        isNotNull,
      );
      await restarted.dispose();
    });

    for (final readBackMismatch in <bool>[false, true]) {
      test(
          'fence ${readBackMismatch ? 'read-back mismatch' : 'write failure'} reports incomplete logout without protected deletion',
          () async {
        final backend = _FaultingSecureStorage();
        final harness = await _loggedInHarness(now, backend: backend);
        final epoch = await harness.stores.credentialEpochStore.read();
        backend.events.clear();
        if (readBackMismatch) {
          backend.corruptAfterWrite[
              NativeSecureVaultMetadataStore.revocationFenceKey] = jsonEncode(
            RevocationFence(
              credentialId: 'other-credential',
              credentialGeneration: 99,
            ).toJson(),
          );
        } else {
          backend.failWriteKeys.add(
            NativeSecureVaultMetadataStore.revocationFenceKey,
          );
        }

        final result = await harness.controller.logout();

        expect(result.completed, isFalse);
        expect(result.cleanupPending, isTrue);
        expect(harness.controller.state, isA<SessionUnauthenticated>());
        expect(
          backend.events,
          isNot(contains(
            'delete:${NativeSecureOfflineAuthorityStore.keyPrefix}${epoch!.activeCredentialId}',
          )),
        );
        expect(
          backend.events,
          isNot(contains(
            'delete:${NativeSecureCredentialStorage.keyPrefix}${epoch.activeCredentialId}',
          )),
        );
        expect(
          jsonDecode(
            backend.values[NativeSecureCredentialEpochStore.epochKey]!,
          )['vaultState'],
          VaultState.active.wireName,
        );
        await harness.dispose();
      });
    }

    test('restart with REVOKED Epoch and matching fence completes recovery',
        () async {
      final backend = _FaultingSecureStorage();
      final harness = _VaultHarness(now, backend: backend);
      await harness.seedActive(_userA);
      final active = await harness.stores.credentialEpochStore.read();
      await harness.stores.credentialEpochStore.write(
        CredentialEpoch(
          activeCredentialId: active!.activeCredentialId,
          activeCredentialGeneration: active.activeCredentialGeneration,
          vaultState: VaultState.revoked,
        ),
      );
      await harness.stores.secureVaultMetadataStore.writeRevocationFence(
        RevocationFence(
          credentialId: active.activeCredentialId!,
          credentialGeneration: active.activeCredentialGeneration,
        ),
      );

      await harness.controller.bootstrap();

      expect(harness.repository.getMeCalls, 0);
      expect(harness.controller.state, isA<SessionUnauthenticated>());
      expect(
        await harness.stores.secureVaultMetadataStore.readRevocationFence(),
        isNull,
      );
      expect(
        await harness.stores.credentialStorage.readById(
          active.activeCredentialId!,
        ),
        isNull,
      );
      await harness.dispose();
    });

    for (final unsupported in <bool>[false, true]) {
      test(
          '${unsupported ? 'unsupported' : 'malformed'} fence fails bootstrap closed',
          () async {
        final backend = _FaultingSecureStorage();
        final harness = _VaultHarness(now, backend: backend);
        await harness.seedActive(_userA);
        backend.values[NativeSecureVaultMetadataStore.revocationFenceKey] =
            unsupported
                ? jsonEncode(<String, Object>{
                    ...RevocationFence(
                      credentialId: 'credential-a',
                      credentialGeneration: 1,
                    ).toJson(),
                    'schemaVersion': 999,
                  })
                : '{';
        harness.repository.getMeHandler = (_) async => _userA;

        await harness.controller.bootstrap();

        expect(harness.repository.getMeCalls, 0);
        expect(harness.manager.currentHandle, isNull);
        expect(harness.controller.state, isA<SessionFailure>());
        expect(
          backend.values.keys,
          contains(NativeSecureVaultMetadataStore.revocationFenceKey),
        );
        await harness.dispose();
      });
    }

    test('stale fence does not revoke a distinct newer ACTIVE credential',
        () async {
      final backend = _FaultingSecureStorage();
      final harness = _VaultHarness(now, backend: backend);
      final credentialA = _credential(_userA, now);
      final credentialB = _credential(
        _userB,
        now,
        credentialId: 'credential-b',
        generation: 2,
      );
      await harness.stores.credentialStorage.write(credentialA);
      await harness.stores.offlineAuthorityStore.write(
        _authority(_userA, credentialA, now),
      );
      await harness.stores.credentialStorage.write(credentialB);
      await harness.stores.offlineAuthorityStore.write(
        _authority(_userB, credentialB, now),
      );
      await harness.stores.credentialEpochStore.write(_epoch(credentialB));
      await harness.stores.secureVaultMetadataStore.writeRevocationFence(
        RevocationFence(
          credentialId: credentialA.credentialId,
          credentialGeneration: credentialA.credentialGeneration,
        ),
      );
      harness.profile.value = _userB;
      harness.repository.getMeHandler = (_) async => _userB;

      await harness.controller.bootstrap();

      expect(harness.repository.getMeCalls, 1);
      expect(harness.controller.state, isA<AuthenticatedOnline>());
      expect(
        await harness.stores.secureVaultMetadataStore.readRevocationFence(),
        isNotNull,
      );
      await harness.dispose();
    });

    for (final failAuthority in <bool>[false, true]) {
      test(
          '${failAuthority ? 'authority' : 'credential'} deletion failure stays logged out',
          () async {
        final backend = _FaultingSecureStorage();
        final harness = await _loggedInHarness(now, backend: backend);
        final epoch = await harness.stores.credentialEpochStore.read();
        backend.failDeleteKeys.add(
          failAuthority
              ? '${NativeSecureOfflineAuthorityStore.keyPrefix}${epoch!.activeCredentialId}'
              : '${NativeSecureCredentialStorage.keyPrefix}${epoch!.activeCredentialId}',
        );

        final result = await harness.controller.logout();

        expect(result.completed, isTrue);
        expect(result.cleanupPending, isTrue);
        expect(harness.controller.state, isA<SessionUnauthenticated>());
        expect(
          (await harness.stores.credentialEpochStore.read())?.vaultState,
          VaultState.cleanupPending,
        );
        final restart = _VaultHarness(now, backend: backend);
        await restart.controller.bootstrap();
        expect(restart.repository.getMeCalls, 0);
        expect(restart.controller.state, isA<SessionUnauthenticated>());
        await restart.dispose();
        await harness.dispose();
      });
    }
  });

  group('Web memory-only semantics', () {
    test('same bundle instance works and a new instance has no auth state',
        () async {
      final first = SecureSessionStores.memory();
      final credential = _credential(_userA, now);
      await first.credentialStorage.write(credential);
      await first.offlineAuthorityStore.write(
        _authority(_userA, credential, now),
      );
      await first.credentialEpochStore.write(_epoch(credential));
      await first.secureVaultMetadataStore.writeRevocationFence(
        RevocationFence(
          credentialId: credential.credentialId,
          credentialGeneration: credential.credentialGeneration,
        ),
      );

      expect(
        await first.credentialStorage.readById(credential.credentialId),
        isNotNull,
      );
      expect(await first.credentialEpochStore.read(), isNotNull);
      expect(
        await first.secureVaultMetadataStore.readRevocationFence(),
        isNotNull,
      );

      final nextAppSession = SecureSessionStores.memory();
      expect(await nextAppSession.credentialEpochStore.read(), isNull);
      expect(
        await nextAppSession.credentialStorage.readById(
          credential.credentialId,
        ),
        isNull,
      );
      expect(
        await nextAppSession.secureVaultMetadataStore.readRevocationFence(),
        isNull,
      );
    });
  });
}

SecureSessionStores _storesFor(_FaultingSecureStorage backend) =>
    SecureSessionStores(
      credentialStorage: NativeSecureCredentialStorage(
        backend,
        legacyPurger: _NoOpLegacyPurger(),
      ),
      offlineAuthorityStore: NativeSecureOfflineAuthorityStore(backend),
      credentialEpochStore: NativeSecureCredentialEpochStore(backend),
      secureVaultMetadataStore: NativeSecureVaultMetadataStore(backend),
    );

StoredCredential _credential(
  User user,
  DateTime now, {
  String credentialId = 'credential-a',
  int generation = 1,
  int tokenHours = 6,
}) =>
    StoredCredential(
      accessToken: _tokenFor(user, now, hours: tokenHours),
      bindingId: 'binding-$credentialId',
      credentialId: credentialId,
      credentialGeneration: generation,
    );

CredentialEpoch _epoch(StoredCredential credential) => CredentialEpoch(
      activeCredentialId: credential.credentialId,
      activeCredentialGeneration: credential.credentialGeneration,
      vaultState: VaultState.active,
    );

OfflineAuthorityRecord _authority(
  User user,
  StoredCredential credential,
  DateTime now, {
  DateTime? validatedAt,
  _AuthorityMismatch? mismatch,
}) {
  final material = const SessionSecurityValidator().validateOnline(
    user: user,
    credential: credential,
    nowUtc: validatedAt ?? now.subtract(const Duration(hours: 1)),
  );
  final original =
      const SessionSecurityValidator().createOfflineAuthorityRecord(
    user: user,
    credential: credential,
    material: material,
    validatedAtUtc: validatedAt ?? now.subtract(const Duration(hours: 1)),
  );
  return OfflineAuthorityRecord(
    principalId: mismatch?.principalId ?? original.principalId,
    scopeKey: mismatch?.scopeKey ?? original.scopeKey,
    validatedAtUtc: original.validatedAtUtc,
    credentialBindingId: mismatch?.bindingId ?? original.credentialBindingId,
    credentialId: mismatch?.credentialId ?? original.credentialId,
    credentialGeneration:
        mismatch?.credentialGeneration ?? original.credentialGeneration,
    credentialFingerprint:
        mismatch?.fingerprint ?? original.credentialFingerprint,
    jwtExpiresAtUtc: mismatch?.jwtExpiresAtUtc ?? original.jwtExpiresAtUtc,
  );
}

String _tokenFor(User user, DateTime now, {int hours = 6}) {
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

const _suspendedUser = User(
  id: 'user-a',
  name: 'User A',
  email: 'a@example.com',
  role: 'TECHNICIAN',
  status: 'SUSPENDED',
  organizationId: 'org-a',
);

final class _AuthorityMismatch {
  const _AuthorityMismatch(
    this.name, {
    this.bindingId,
    this.credentialId,
    this.credentialGeneration,
    this.principalId,
    this.scopeKey,
    this.fingerprint,
    this.jwtExpiresAtUtc,
  });

  final String name;
  final String? bindingId;
  final String? credentialId;
  final int? credentialGeneration;
  final String? principalId;
  final String? scopeKey;
  final String? fingerprint;
  final DateTime? jwtExpiresAtUtc;
}

enum _ReplacementFailure {
  credentialWrite('Credential B write failure'),
  authorityWrite('Authority B write failure'),
  verification('verification failure'),
  epochCommit('crash before Epoch commit');

  const _ReplacementFailure(this.name);
  final String name;
}

final class _FaultingSecureStorage implements SecureKeyValueStorage {
  final Map<String, String> values = <String, String>{};
  final Set<String> failWriteKeys = <String>{};
  final Set<String> failDeleteKeys = <String>{};
  final Map<String, String> corruptAfterWrite = <String, String>{};
  final Map<String, String> readOverrides = <String, String>{};
  final List<String> events = <String>[];
  bool unavailable = false;

  @override
  Future<String?> read(String key) async {
    events.add('read:$key');
    if (unavailable) {
      throw const SecureStorageUnavailableException('read');
    }
    return readOverrides[key] ?? values[key];
  }

  @override
  Future<Set<String>> readKeys() async {
    events.add('readKeys');
    if (unavailable) {
      throw const SecureStorageUnavailableException('read');
    }
    return values.keys.toSet();
  }

  @override
  Future<void> write(String key, String value) async {
    events.add('write:$key');
    if (unavailable || failWriteKeys.contains(key)) {
      throw const SecureStorageUnavailableException('write');
    }
    values[key] = value;
    final corruptValue = corruptAfterWrite[key];
    if (corruptValue != null) readOverrides[key] = corruptValue;
  }

  @override
  Future<void> delete(String key) async {
    events.add('delete:$key');
    if (unavailable || failDeleteKeys.contains(key)) {
      throw const SecureStorageUnavailableException('delete');
    }
    values.remove(key);
    readOverrides.remove(key);
  }
}

final class _NoOpLegacyPurger extends LegacyCredentialPurger {
  @override
  Future<void> purge() async {}
}

final class _VaultHarness {
  _VaultHarness(
    DateTime now, {
    _FaultingSecureStorage? backend,
    int initialCredentialSequence = 0,
  })  : backend = backend ?? _FaultingSecureStorage(),
        profile = _MemoryProfileCache(),
        repository = _ControlledRepository(),
        manager = AuthScopedDatabaseManager.forTesting(
          opener: (_) async => _FakeDatabase(),
        ) {
    stores = _storesFor(this.backend);
    var bindingSequence = 0;
    var credentialSequence = initialCredentialSequence;
    controller = AuthNotifier(
      repository: repository,
      credentialStorage: stores.credentialStorage,
      profileCache: profile,
      offlineAuthorityStore: stores.offlineAuthorityStore,
      credentialEpochStore: stores.credentialEpochStore,
      secureVaultMetadataStore: stores.secureVaultMetadataStore,
      securityValidator: const SessionSecurityValidator(),
      databaseManager: manager,
      nowUtc: () => now,
      credentialBindingIdFactory: () => 'binding-${++bindingSequence}',
      credentialIdFactory: () => 'credential-${++credentialSequence}',
      autoBootstrap: false,
    );
  }

  final _FaultingSecureStorage backend;
  final _MemoryProfileCache profile;
  final _ControlledRepository repository;
  final AuthScopedDatabaseManager manager;
  late final SecureSessionStores stores;
  late final AuthNotifier controller;

  Future<void> seedActive(
    User user, {
    int tokenHours = 6,
    DateTime? validatedAt,
  }) async {
    final credential = _credential(
      user,
      DateTime.utc(2026, 9, 14, 12),
      tokenHours: tokenHours,
    );
    await stores.credentialStorage.write(credential);
    await stores.offlineAuthorityStore.write(
      _authority(
        user,
        credential,
        DateTime.utc(2026, 9, 14, 12),
        validatedAt: validatedAt,
      ),
    );
    await stores.credentialEpochStore.write(_epoch(credential));
    profile.value = user;
  }

  Future<void> dispose() async {
    final generation = controller.currentGeneration + 100000;
    controller.dispose();
    await manager.closeCurrentDatabase(sessionGeneration: generation);
  }
}

Future<_VaultHarness> _loggedInHarness(
  DateTime now, {
  _FaultingSecureStorage? backend,
}) async {
  final harness = _VaultHarness(now, backend: backend)
    ..repository.loginHandler = (_) async => AuthLoginResult(
          user: _userA,
          accessToken: _tokenFor(_userA, now),
        );
  expect(await harness.controller.login('a@example.com', 'secret'), isTrue);
  return harness;
}

final class _ControlledRepository implements AuthRepository {
  Future<AuthLoginResult> Function(String email)? loginHandler;
  Future<User> Function(String token)? getMeHandler;
  int getMeCalls = 0;

  @override
  Future<AuthLoginResult> login(String email, String password) {
    final handler = loginHandler;
    if (handler == null) throw StateError('Unexpected login.');
    return handler(email);
  }

  @override
  Future<User> getCurrentUser(String token) {
    getMeCalls++;
    final handler = getMeHandler;
    if (handler == null) throw StateError('Unexpected /auth/me.');
    return handler(token);
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
