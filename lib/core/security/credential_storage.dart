/// A credential persisted for the current installation.
///
/// [bindingId] identifies this particular credential installation. It is not
/// the session generation and deliberately allows a future credential to be
/// rotated without changing the authenticated principal or AuthScope.
final class StoredCredential {
  StoredCredential({
    required this.accessToken,
    required this.bindingId,
  }) {
    if (accessToken.trim().isEmpty || accessToken != accessToken.trim()) {
      throw ArgumentError.value(
        accessToken,
        'accessToken',
        'Credential must be a non-empty token without surrounding whitespace.',
      );
    }
    if (bindingId.trim().isEmpty) {
      throw ArgumentError.value(
        bindingId,
        'bindingId',
        'Credential binding id must not be empty.',
      );
    }
  }

  final String accessToken;
  final String bindingId;

  Map<String, Object> toJson() => <String, Object>{
        'accessToken': accessToken,
        'bindingId': bindingId,
      };

  static StoredCredential fromJson(Map<Object?, Object?> json) {
    final accessToken = json['accessToken'];
    final bindingId = json['bindingId'];
    if (accessToken is! String || bindingId is! String) {
      throw const CredentialStorageFormatException(
        'Stored credential has an invalid shape.',
      );
    }
    return StoredCredential(
      accessToken: accessToken,
      bindingId: bindingId,
    );
  }
}

/// Stores authentication secret material only.
///
/// User/profile data and authorization metadata intentionally live behind
/// separate abstractions. The cleanup marker is a durable logical tombstone:
/// a matching residual credential must never be restored after logout.
abstract interface class CredentialStorage {
  Future<StoredCredential?> read();

  Future<void> write(StoredCredential credential);

  Future<String?> readCleanupPendingBindingId();

  Future<void> markCleanupPending(String bindingId);

  /// Unconditionally deletes malformed/unowned canonical credential material.
  /// Session orchestration must invoke this only inside its generation commit
  /// gate so it cannot race a newer write.
  Future<void> delete();

  /// Deletes the credential only when it still belongs to [bindingId].
  ///
  /// This conditional delete prevents cleanup from an old session from
  /// deleting a newer credential.
  Future<bool> deleteIfMatches(String bindingId);

  Future<void> clearCleanupPending(String bindingId);

  /// Deletes known pre-FE-01C credential keys without promoting their values.
  Future<void> purgeLegacyCredentials();
}

final class CredentialStorageFormatException implements Exception {
  const CredentialStorageFormatException(this.message);

  final String message;

  @override
  String toString() => 'CredentialStorageFormatException: $message';
}
