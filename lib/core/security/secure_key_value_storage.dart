import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureKeyValueStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class NativeSecureKeyValueStorage implements SecureKeyValueStorage {
  NativeSecureKeyValueStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                resetOnError: false,
                migrateOnAlgorithmChange: false,
                storageNamespace: androidStorageNamespace,
              ),
              iOptions: IOSOptions(
                accountName: appleAccountName,
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
              mOptions: MacOsOptions(
                accountName: appleAccountName,
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
                usesDataProtectionKeychain: true,
              ),
              wOptions: WindowsOptions(useBackwardCompatibility: false),
            );

  static const String androidStorageNamespace = 'assistailab_session_vault_v1';
  static const String appleAccountName =
      'com.example.assistailab.session-vault.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      throw const SecureStorageUnavailableException('read');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {
      throw const SecureStorageUnavailableException('write');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {
      throw const SecureStorageUnavailableException('delete');
    }
  }
}

final class MemorySecureKeyValueStorage implements SecureKeyValueStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

final class SecureStorageUnavailableException implements Exception {
  const SecureStorageUnavailableException(this.operation);

  final String operation;

  @override
  String toString() =>
      'SecureStorageUnavailableException: secure storage $operation failed.';
}
