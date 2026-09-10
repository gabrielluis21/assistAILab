import 'package:hive/hive.dart';

import 'credential_storage.dart';

/// Temporary Hive adapter for [CredentialStorage].
///
/// This is deliberately isolated so it can be replaced by an OS-backed vault
/// without changing session orchestration. Hive does not provide platform
/// secure storage; no additional trust is granted to this adapter.
final class HiveCredentialStorage implements CredentialStorage {
  static const String boxName = 'auth_credentials_v1';
  static const String credentialKey = 'credential';
  static const String cleanupPendingKey = 'cleanup_pending_binding_id';

  static const String legacyAuthBoxName = 'auth_box';
  static const String legacyJwtKey = 'jwt_token';
  static const String legacyPreferencesBoxName = 'user_preferences';
  static const String legacyPreferencesTokenKey = 'auth_token';

  Future<Box<dynamic>> _box() => Hive.openBox<dynamic>(boxName);

  @override
  Future<StoredCredential?> read() async {
    final value = (await _box()).get(credentialKey);
    if (value == null) return null;
    if (value is! Map) {
      throw const CredentialStorageFormatException(
        'Stored credential value is not a map.',
      );
    }
    return StoredCredential.fromJson(value.cast<Object?, Object?>());
  }

  @override
  Future<void> write(StoredCredential credential) async {
    await (await _box()).put(credentialKey, credential.toJson());
  }

  @override
  Future<String?> readCleanupPendingBindingId() async {
    final value = (await _box()).get(cleanupPendingKey);
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  @override
  Future<void> markCleanupPending(String bindingId) async {
    if (bindingId.trim().isEmpty) {
      throw ArgumentError.value(bindingId, 'bindingId');
    }
    await (await _box()).put(cleanupPendingKey, bindingId);
  }

  @override
  Future<void> delete() async {
    await (await _box()).delete(credentialKey);
  }

  @override
  Future<bool> deleteIfMatches(String bindingId) async {
    final box = await _box();
    final value = box.get(credentialKey);
    if (value is! Map || value['bindingId'] != bindingId) {
      return false;
    }
    await box.delete(credentialKey);
    return true;
  }

  @override
  Future<void> clearCleanupPending(String bindingId) async {
    final box = await _box();
    if (box.get(cleanupPendingKey) == bindingId) {
      await box.delete(cleanupPendingKey);
    }
  }

  @override
  Future<void> purgeLegacyCredentials() async {
    final legacyAuthBox = await Hive.openBox<dynamic>(legacyAuthBoxName);
    await legacyAuthBox.delete(legacyJwtKey);

    final legacyPreferences =
        await Hive.openBox<dynamic>(legacyPreferencesBoxName);
    await legacyPreferences.delete(legacyPreferencesTokenKey);
  }
}
