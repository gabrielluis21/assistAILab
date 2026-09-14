import 'dart:io';

import 'package:assistailab/core/security/credential_epoch.dart';
import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/core/security/hive_credential_storage.dart';
import 'package:assistailab/core/security/revocation_fence.dart';
import 'package:assistailab/features/auth/data/datasources/secure_session_stores.dart';
import 'package:assistailab/features/auth/domain/entities/offline_authority_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory tempDirectory;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('web_legacy_auth_');
    Hive.init(tempDirectory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('production Web stores delete all legacy auth values without promotion',
      () async {
    final legacyVault = await Hive.openBox<dynamic>(
      LegacyCredentialPurger.legacyVaultBoxName,
    );
    final legacyAuthority = await Hive.openBox<dynamic>(
      LegacyCredentialPurger.legacyAuthorityBoxName,
    );
    final legacyAuth = await Hive.openBox<dynamic>(
      LegacyCredentialPurger.legacyAuthBoxName,
    );
    final legacyPreferences = await Hive.openBox<dynamic>(
      LegacyCredentialPurger.legacyPreferencesBoxName,
    );
    await legacyVault.put(
      LegacyCredentialPurger.legacyVaultCredentialKey,
      <String, Object>{'accessToken': 'legacy-credential-token'},
    );
    await legacyVault.put(
      LegacyCredentialPurger.legacyVaultCleanupKey,
      'legacy-binding',
    );
    await legacyAuthority.put(
      LegacyCredentialPurger.legacyAuthorityKey,
      <String, Object>{'principalId': 'legacy-user'},
    );
    await legacyAuth.put(
      LegacyCredentialPurger.legacyJwtKey,
      'legacy-jwt',
    );
    await legacyPreferences.put(
      LegacyCredentialPurger.legacyPreferencesTokenKey,
      'legacy-preferences-token',
    );

    final stores = SecureSessionStores.web();

    expect(
        await stores.credentialStorage.readById('legacy-credential'), isNull);
    expect(
      await stores.offlineAuthorityStore.readByCredentialId(
        'legacy-credential',
      ),
      isNull,
    );
    expect(await stores.credentialEpochStore.read(), isNull);
    expect(
      await stores.secureVaultMetadataStore.readRevocationFence(),
      isNull,
    );

    await stores.credentialStorage.purgeLegacyCredentials();

    expect(
      legacyVault.get(LegacyCredentialPurger.legacyVaultCredentialKey),
      isNull,
    );
    expect(
      legacyVault.get(LegacyCredentialPurger.legacyVaultCleanupKey),
      isNull,
    );
    expect(
      legacyAuthority.get(LegacyCredentialPurger.legacyAuthorityKey),
      isNull,
    );
    expect(
      legacyAuth.get(LegacyCredentialPurger.legacyJwtKey),
      isNull,
    );
    expect(
      legacyPreferences.get(
        LegacyCredentialPurger.legacyPreferencesTokenKey,
      ),
      isNull,
    );
    expect(await stores.credentialEpochStore.read(), isNull);
    expect(
      await stores.secureVaultMetadataStore.readRevocationFence(),
      isNull,
    );
    expect(
      await stores.secureVaultMetadataStore.containsSessionArtifacts(),
      isFalse,
    );
  });

  test('production Web current Vault remains per-instance memory-only',
      () async {
    final first = SecureSessionStores.web();
    final credential = StoredCredential(
      accessToken: 'current-token',
      bindingId: 'current-binding',
      credentialId: 'current-credential',
      credentialGeneration: 4,
    );
    final authority = OfflineAuthorityRecord(
      principalId: 'current-user',
      scopeKey: 'PROFESSIONAL:current-org:current-user',
      validatedAtUtc: DateTime.utc(2026, 9, 14, 12),
      credentialBindingId: credential.bindingId,
      credentialId: credential.credentialId,
      credentialGeneration: credential.credentialGeneration,
      credentialFingerprint: 'current-fingerprint',
      jwtExpiresAtUtc: DateTime.utc(2026, 9, 14, 18),
    );
    final epoch = CredentialEpoch(
      activeCredentialId: credential.credentialId,
      activeCredentialGeneration: credential.credentialGeneration,
      vaultState: VaultState.active,
    );
    final fence = RevocationFence(
      credentialId: credential.credentialId,
      credentialGeneration: credential.credentialGeneration,
    );

    await first.credentialStorage.write(credential);
    await first.offlineAuthorityStore.write(authority);
    await first.credentialEpochStore.write(epoch);
    await first.secureVaultMetadataStore.writeRevocationFence(fence);
    await first.credentialStorage.purgeLegacyCredentials();

    expect(
      await first.credentialStorage.readById(credential.credentialId),
      isNotNull,
    );
    expect(
      await first.offlineAuthorityStore.readByCredentialId(
        credential.credentialId,
      ),
      isNotNull,
    );
    expect(await first.credentialEpochStore.read(), isNotNull);
    expect(
      await first.secureVaultMetadataStore.readRevocationFence(),
      isNotNull,
    );

    final second = SecureSessionStores.web();

    expect(
      await second.credentialStorage.readById(credential.credentialId),
      isNull,
    );
    expect(
      await second.offlineAuthorityStore.readByCredentialId(
        credential.credentialId,
      ),
      isNull,
    );
    expect(await second.credentialEpochStore.read(), isNull);
    expect(
      await second.secureVaultMetadataStore.readRevocationFence(),
      isNull,
    );
    expect(
      await second.secureVaultMetadataStore.containsSessionArtifacts(),
      isFalse,
    );
  });
}
