enum RevocationFenceState {
  revokeIntent('REVOKE_INTENT');

  const RevocationFenceState(this.wireName);

  final String wireName;

  static RevocationFenceState parse(String value) {
    for (final state in values) {
      if (state.wireName == value) return state;
    }
    throw FormatException('Unsupported revocation fence state: $value.');
  }
}

final class RevocationFence {
  RevocationFence({
    required this.credentialId,
    required this.credentialGeneration,
    this.state = RevocationFenceState.revokeIntent,
    this.schemaVersion = currentSchemaVersion,
  }) {
    if (credentialId.trim().isEmpty || credentialGeneration <= 0) {
      throw ArgumentError('Revocation fence contains invalid values.');
    }
  }

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String credentialId;
  final int credentialGeneration;
  final RevocationFenceState state;

  Map<String, Object> toJson() => <String, Object>{
        'schemaVersion': schemaVersion,
        'credentialId': credentialId,
        'credentialGeneration': credentialGeneration,
        'state': state.wireName,
      };

  static RevocationFence fromJson(Map<Object?, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final credentialId = json['credentialId'];
    final credentialGeneration = json['credentialGeneration'];
    final state = json['state'];
    if (schemaVersion is! int ||
        credentialId is! String ||
        credentialGeneration is! int ||
        state is! String) {
      throw const FormatException('Invalid revocation fence shape.');
    }
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported revocation fence schema version: $schemaVersion.',
      );
    }
    try {
      return RevocationFence(
        schemaVersion: schemaVersion,
        credentialId: credentialId,
        credentialGeneration: credentialGeneration,
        state: RevocationFenceState.parse(state),
      );
    } on ArgumentError {
      throw const FormatException('Invalid revocation fence values.');
    }
  }
}

abstract interface class SecureVaultMetadataStore {
  Future<RevocationFence?> readRevocationFence();

  Future<void> writeRevocationFence(RevocationFence fence);

  Future<void> deleteRevocationFence();

  Future<bool> containsSessionArtifacts();
}
