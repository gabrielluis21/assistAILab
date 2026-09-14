import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../../core/security/credential_storage.dart';
import '../../../../core/security/credential_epoch.dart';
import '../../../../core/security/credential_epoch_store.dart';
import '../../../../core/security/hive_credential_storage.dart';
import '../../../../core/security/revocation_fence.dart';
import '../../../../core/security/secure_key_value_storage.dart';
import '../../domain/entities/offline_authority_record.dart';
import '../../domain/repositories/offline_authority_store.dart';

final class SecureSessionStores {
  const SecureSessionStores({
    required this.credentialStorage,
    required this.offlineAuthorityStore,
    required this.credentialEpochStore,
    required this.secureVaultMetadataStore,
  });

  factory SecureSessionStores.native({SecureKeyValueStorage? storage}) {
    final backend = storage ?? NativeSecureKeyValueStorage();
    return SecureSessionStores(
      credentialStorage: NativeSecureCredentialStorage(backend),
      offlineAuthorityStore: NativeSecureOfflineAuthorityStore(backend),
      credentialEpochStore: NativeSecureCredentialEpochStore(backend),
      secureVaultMetadataStore: NativeSecureVaultMetadataStore(backend),
    );
  }

  factory SecureSessionStores.memory() {
    final backend = MemorySecureKeyValueStorage();
    return SecureSessionStores(
      credentialStorage: MemoryCredentialStorage(backend),
      offlineAuthorityStore: MemoryOfflineAuthorityStore(backend),
      credentialEpochStore: MemoryCredentialEpochStore(backend),
      secureVaultMetadataStore: MemorySecureVaultMetadataStore(backend),
    );
  }

  final CredentialStorage credentialStorage;
  final OfflineAuthorityStore offlineAuthorityStore;
  final CredentialEpochStore credentialEpochStore;
  final SecureVaultMetadataStore secureVaultMetadataStore;
}

SecureSessionStores createSecureSessionStores() =>
    kIsWeb ? SecureSessionStores.memory() : SecureSessionStores.native();

final class NativeSecureCredentialStorage implements CredentialStorage {
  NativeSecureCredentialStorage(
    this._storage, {
    LegacyCredentialPurger? legacyPurger,
  }) : _legacyPurger = legacyPurger ?? LegacyCredentialPurger();

  static const String keyPrefix = 'assistailab.session_vault.credential.v1.';

  final SecureKeyValueStorage _storage;
  final LegacyCredentialPurger _legacyPurger;

  @override
  Future<StoredCredential?> readById(String credentialId) async {
    final raw = await _storage.read(_credentialKey(credentialId));
    if (raw == null) return null;
    return StoredCredential.fromJson(_decodeObject(raw, 'credential'));
  }

  @override
  Future<void> write(StoredCredential credential) => _storage.write(
        _credentialKey(credential.credentialId),
        jsonEncode(credential.toJson()),
      );

  @override
  Future<void> deleteById(String credentialId) =>
      _storage.delete(_credentialKey(credentialId));

  @override
  Future<bool> deleteIfMatches({
    required String credentialId,
    required int credentialGeneration,
  }) async {
    final current = await readById(credentialId);
    if (current == null ||
        current.credentialId != credentialId ||
        current.credentialGeneration != credentialGeneration) {
      return false;
    }
    await deleteById(credentialId);
    return true;
  }

  @override
  Future<void> purgeLegacyCredentials() => _legacyPurger.purge();
}

final class MemoryCredentialStorage implements CredentialStorage {
  MemoryCredentialStorage([SecureKeyValueStorage? storage])
      : _delegate = NativeSecureCredentialStorage(
          storage ?? MemorySecureKeyValueStorage(),
          legacyPurger: _NoOpLegacyPurger(),
        );

  final NativeSecureCredentialStorage _delegate;

  @override
  Future<StoredCredential?> readById(String credentialId) =>
      _delegate.readById(credentialId);

  @override
  Future<void> write(StoredCredential credential) =>
      _delegate.write(credential);

  @override
  Future<void> deleteById(String credentialId) =>
      _delegate.deleteById(credentialId);

  @override
  Future<bool> deleteIfMatches({
    required String credentialId,
    required int credentialGeneration,
  }) =>
      _delegate.deleteIfMatches(
        credentialId: credentialId,
        credentialGeneration: credentialGeneration,
      );

  @override
  Future<void> purgeLegacyCredentials() async {}
}

final class NativeSecureOfflineAuthorityStore implements OfflineAuthorityStore {
  NativeSecureOfflineAuthorityStore(this._storage);

  static const String keyPrefix = 'assistailab.session_vault.authority.v1.';

  final SecureKeyValueStorage _storage;

  @override
  Future<OfflineAuthorityRecord?> readByCredentialId(
    String credentialId,
  ) async {
    final raw = await _storage.read(_authorityKey(credentialId));
    if (raw == null) return null;
    return OfflineAuthorityRecord.fromJson(_decodeObject(raw, 'authority'));
  }

  @override
  Future<void> write(OfflineAuthorityRecord record) => _storage.write(
        _authorityKey(record.credentialId),
        jsonEncode(record.toJson()),
      );

  @override
  Future<void> deleteByCredentialId(String credentialId) =>
      _storage.delete(_authorityKey(credentialId));
}

final class MemoryOfflineAuthorityStore implements OfflineAuthorityStore {
  MemoryOfflineAuthorityStore([SecureKeyValueStorage? storage])
      : _delegate = NativeSecureOfflineAuthorityStore(
          storage ?? MemorySecureKeyValueStorage(),
        );

  final NativeSecureOfflineAuthorityStore _delegate;

  @override
  Future<OfflineAuthorityRecord?> readByCredentialId(String credentialId) =>
      _delegate.readByCredentialId(credentialId);

  @override
  Future<void> write(OfflineAuthorityRecord record) => _delegate.write(record);

  @override
  Future<void> deleteByCredentialId(String credentialId) =>
      _delegate.deleteByCredentialId(credentialId);
}

final class NativeSecureCredentialEpochStore implements CredentialEpochStore {
  NativeSecureCredentialEpochStore(this._storage);

  static const String epochKey = 'assistailab.session_vault.epoch.v1';

  final SecureKeyValueStorage _storage;

  @override
  Future<CredentialEpoch?> read() async {
    final raw = await _storage.read(epochKey);
    if (raw == null) return null;
    return CredentialEpoch.fromJson(_decodeObject(raw, 'Epoch'));
  }

  @override
  Future<void> write(CredentialEpoch epoch) =>
      _storage.write(epochKey, jsonEncode(epoch.toJson()));
}

final class MemoryCredentialEpochStore implements CredentialEpochStore {
  MemoryCredentialEpochStore([SecureKeyValueStorage? storage])
      : _delegate = NativeSecureCredentialEpochStore(
          storage ?? MemorySecureKeyValueStorage(),
        );

  final NativeSecureCredentialEpochStore _delegate;

  @override
  Future<CredentialEpoch?> read() => _delegate.read();

  @override
  Future<void> write(CredentialEpoch epoch) => _delegate.write(epoch);
}

final class NativeSecureVaultMetadataStore implements SecureVaultMetadataStore {
  NativeSecureVaultMetadataStore(this._storage);

  static const String revocationFenceKey =
      'assistailab.session_vault.revocation_fence.v1';

  final SecureKeyValueStorage _storage;

  @override
  Future<RevocationFence?> readRevocationFence() async {
    final raw = await _storage.read(revocationFenceKey);
    if (raw == null) return null;
    return RevocationFence.fromJson(_decodeObject(raw, 'revocation fence'));
  }

  @override
  Future<void> writeRevocationFence(RevocationFence fence) => _storage.write(
        revocationFenceKey,
        jsonEncode(fence.toJson()),
      );

  @override
  Future<void> deleteRevocationFence() => _storage.delete(revocationFenceKey);

  @override
  Future<bool> containsSessionArtifacts() async {
    final keys = await _storage.readKeys();
    return keys.any(
      (key) =>
          key == NativeSecureCredentialEpochStore.epochKey ||
          key == revocationFenceKey ||
          key.startsWith(NativeSecureCredentialStorage.keyPrefix) ||
          key.startsWith(NativeSecureOfflineAuthorityStore.keyPrefix),
    );
  }
}

final class MemorySecureVaultMetadataStore implements SecureVaultMetadataStore {
  MemorySecureVaultMetadataStore([SecureKeyValueStorage? storage])
      : _delegate = NativeSecureVaultMetadataStore(
          storage ?? MemorySecureKeyValueStorage(),
        );

  final NativeSecureVaultMetadataStore _delegate;

  @override
  Future<RevocationFence?> readRevocationFence() =>
      _delegate.readRevocationFence();

  @override
  Future<void> writeRevocationFence(RevocationFence fence) =>
      _delegate.writeRevocationFence(fence);

  @override
  Future<void> deleteRevocationFence() => _delegate.deleteRevocationFence();

  @override
  Future<bool> containsSessionArtifacts() =>
      _delegate.containsSessionArtifacts();
}

Map<Object?, Object?> _decodeObject(String raw, String recordName) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('Secure $recordName record is not an object.');
    }
    return decoded.cast<Object?, Object?>();
  } on FormatException {
    rethrow;
  } catch (_) {
    throw FormatException('Secure $recordName record is malformed.');
  }
}

String _credentialKey(String credentialId) =>
    '${NativeSecureCredentialStorage.keyPrefix}${_safeId(credentialId)}';

String _authorityKey(String credentialId) =>
    '${NativeSecureOfflineAuthorityStore.keyPrefix}${_safeId(credentialId)}';

String _safeId(String credentialId) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(credentialId)) {
    throw ArgumentError.value(credentialId, 'credentialId');
  }
  return credentialId;
}

final class _NoOpLegacyPurger extends LegacyCredentialPurger {
  @override
  Future<void> purge() async {}
}
