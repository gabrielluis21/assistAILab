import 'dart:io';

import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/core/security/hive_credential_storage.dart';
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
      HiveCredentialStorage.legacyAuthBoxName,
    );
    final legacyPreferences = await Hive.openBox<dynamic>(
      HiveCredentialStorage.legacyPreferencesBoxName,
    );
    await legacyAuth.put(HiveCredentialStorage.legacyJwtKey, 'legacy-jwt');
    await legacyPreferences.put(
      HiveCredentialStorage.legacyPreferencesTokenKey,
      'legacy-preferences-token',
    );

    final storage = HiveCredentialStorage();
    await storage.purgeLegacyCredentials();

    expect(legacyAuth.get(HiveCredentialStorage.legacyJwtKey), isNull);
    expect(
      legacyPreferences.get(
        HiveCredentialStorage.legacyPreferencesTokenKey,
      ),
      isNull,
    );
    expect(await storage.read(), isNull);
  });

  test('conditional old cleanup cannot delete a replacement credential',
      () async {
    final storage = HiveCredentialStorage();
    final credentialA = StoredCredential(
      accessToken: 'token-a',
      bindingId: 'binding-a',
    );
    final credentialB = StoredCredential(
      accessToken: 'token-b',
      bindingId: 'binding-b',
    );

    await storage.write(credentialA);
    await storage.markCleanupPending(credentialA.bindingId);
    await storage.write(credentialB);

    expect(await storage.deleteIfMatches(credentialA.bindingId), isFalse);
    expect((await storage.read())?.bindingId, credentialB.bindingId);
    expect(
      await storage.readCleanupPendingBindingId(),
      credentialA.bindingId,
    );
  });
}
