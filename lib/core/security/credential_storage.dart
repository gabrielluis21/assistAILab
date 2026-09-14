/// A versioned credential record stored under its immutable [credentialId].
final class StoredCredential {
  StoredCredential({
    required this.accessToken,
    required this.bindingId,
    String? credentialId,
    this.credentialGeneration = 1,
    this.schemaVersion = currentSchemaVersion,
  }) : credentialId = credentialId ?? bindingId {
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
    if (this.credentialId.trim().isEmpty) {
      throw ArgumentError.value(
        this.credentialId,
        'credentialId',
        'Credential id must not be empty.',
      );
    }
    if (credentialGeneration <= 0) {
      throw ArgumentError.value(
        credentialGeneration,
        'credentialGeneration',
        'Credential generation must be positive.',
      );
    }
  }

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String accessToken;
  final String bindingId;
  final String credentialId;
  final int credentialGeneration;

  Map<String, Object> toJson() => <String, Object>{
        'schemaVersion': schemaVersion,
        'accessToken': accessToken,
        'bindingId': bindingId,
        'credentialId': credentialId,
        'credentialGeneration': credentialGeneration,
      };

  static StoredCredential fromJson(Map<Object?, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final accessToken = json['accessToken'];
    final bindingId = json['bindingId'];
    final credentialId = json['credentialId'];
    final credentialGeneration = json['credentialGeneration'];
    if (schemaVersion is! int ||
        accessToken is! String ||
        bindingId is! String ||
        credentialId is! String ||
        credentialGeneration is! int) {
      throw const CredentialStorageFormatException(
        'Stored credential has an invalid shape.',
      );
    }
    if (schemaVersion != currentSchemaVersion) {
      throw CredentialStorageFormatException(
        'Unsupported credential schema version: $schemaVersion.',
      );
    }
    try {
      return StoredCredential(
        schemaVersion: schemaVersion,
        accessToken: accessToken,
        bindingId: bindingId,
        credentialId: credentialId,
        credentialGeneration: credentialGeneration,
      );
    } on ArgumentError {
      throw const CredentialStorageFormatException(
        'Stored credential contains invalid values.',
      );
    }
  }
}

/// Stores credential records by immutable credential id.
abstract interface class CredentialStorage {
  Future<StoredCredential?> readById(String credentialId);

  Future<void> write(StoredCredential credential);

  Future<void> deleteById(String credentialId);

  /// Deletes only the exact id/generation pair, protecting a replacement.
  Future<bool> deleteIfMatches({
    required String credentialId,
    required int credentialGeneration,
  });

  /// Deletes known pre-vault values without reading or promoting them.
  Future<void> purgeLegacyCredentials();
}

final class CredentialStorageFormatException implements Exception {
  const CredentialStorageFormatException(this.message);

  final String message;

  @override
  String toString() => 'CredentialStorageFormatException: $message';
}
