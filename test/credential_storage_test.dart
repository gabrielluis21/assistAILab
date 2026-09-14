import 'dart:io';

import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/core/security/hive_credential_storage.dart';
import 'package:assistailab/features/auth/data/datasources/secure_session_stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory tempDirectory;

  setUp(() {
    tempDirectory = Directory.systemTemp.createTempSync('credential_store_');
    Hive.init(tempDirectory.path);
  });

  tearDown(() async {
    await Hive.close();
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  test('legacy tokens are deleted and never migrated to canonical storage',
      () async {
    final legacyAuth = await Hive.openBox<dynamic>(
      LegacyCredentialPurger.legacyAuthBoxName,
    );
    final legacyPreferences = await Hive.openBox<dynamic>(
      LegacyCredentialPurger.legacyPreferencesBoxName,
    );
    await legacyAuth.put(LegacyCredentialPurger.legacyJwtKey, 'legacy-jwt');
    await legacyPreferences.put(
      LegacyCredentialPurger.legacyPreferencesTokenKey,
      'legacy-preferences-token',
    );

    await LegacyCredentialPurger().purge();

    expect(legacyAuth.get(LegacyCredentialPurger.legacyJwtKey), isNull);
    expect(
      legacyPreferences.get(
        LegacyCredentialPurger.legacyPreferencesTokenKey,
      ),
      isNull,
    );
  });

  test('credential records coexist and conditional cleanup is id-bound',
      () async {
    final storage = MemoryCredentialStorage();
    final credentialA = StoredCredential(
      accessToken: 'token-a',
      bindingId: 'binding-a',
      credentialId: 'credential-a',
      credentialGeneration: 1,
    );
    final credentialB = StoredCredential(
      accessToken: 'token-b',
      bindingId: 'binding-b',
      credentialId: 'credential-b',
      credentialGeneration: 2,
    );

    await storage.write(credentialA);
    await storage.write(credentialB);

    expect(
      await storage.deleteIfMatches(
        credentialId: credentialA.credentialId,
        credentialGeneration: credentialA.credentialGeneration,
      ),
      isTrue,
    );
    expect(await storage.readById(credentialA.credentialId), isNull);
    expect(
      (await storage.readById(credentialB.credentialId))?.bindingId,
      credentialB.bindingId,
    );
  });
}
