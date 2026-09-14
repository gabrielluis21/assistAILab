import 'package:hive/hive.dart';

/// Delete-only access to authentication remnants predating the secure vault.
/// Values are never read, migrated, promoted, rewrapped, or imported.
class LegacyCredentialPurger {
  static const String legacyVaultBoxName = 'auth_credentials_v1';
  static const String legacyVaultCredentialKey = 'credential';
  static const String legacyVaultCleanupKey = 'cleanup_pending_binding_id';
  static const String legacyAuthorityBoxName = 'auth_offline_authority_v1';
  static const String legacyAuthorityKey = 'authority_record';
  static const String legacyAuthBoxName = 'auth_box';
  static const String legacyJwtKey = 'jwt_token';
  static const String legacyPreferencesBoxName = 'user_preferences';
  static const String legacyPreferencesTokenKey = 'auth_token';

  Future<void> purge() async {
    final legacyVault = await Hive.openBox<dynamic>(legacyVaultBoxName);
    await legacyVault.delete(legacyVaultCredentialKey);
    await legacyVault.delete(legacyVaultCleanupKey);

    final legacyAuthority = await Hive.openBox<dynamic>(legacyAuthorityBoxName);
    await legacyAuthority.delete(legacyAuthorityKey);

    final legacyAuth = await Hive.openBox<dynamic>(legacyAuthBoxName);
    await legacyAuth.delete(legacyJwtKey);

    final legacyPreferences =
        await Hive.openBox<dynamic>(legacyPreferencesBoxName);
    await legacyPreferences.delete(legacyPreferencesTokenKey);
  }
}
