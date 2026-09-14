/// Semantic state persisted by the secure credential Epoch.
enum VaultState {
  empty('EMPTY'),
  active('ACTIVE'),
  revoked('REVOKED'),
  cleanupPending('CLEANUP_PENDING');

  const VaultState(this.wireName);

  final String wireName;

  static VaultState parse(String value) {
    for (final state in values) {
      if (state.wireName == value) return state;
    }
    throw FormatException('Unsupported vault state: $value.');
  }
}

/// Durable local authority anchor. It is never deleted or reset on corruption.
final class CredentialEpoch {
  CredentialEpoch({
    required this.activeCredentialId,
    required this.activeCredentialGeneration,
    required this.vaultState,
    this.schemaVersion = currentSchemaVersion,
  }) {
    final hasId =
        activeCredentialId != null && activeCredentialId!.trim().isNotEmpty;
    if (activeCredentialGeneration < 0 ||
        (vaultState == VaultState.empty &&
            (hasId || activeCredentialGeneration != 0)) ||
        (vaultState != VaultState.empty &&
            (!hasId || activeCredentialGeneration <= 0))) {
      throw ArgumentError('Credential Epoch contains invalid values.');
    }
  }

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String? activeCredentialId;
  final int activeCredentialGeneration;
  final VaultState vaultState;

  bool get isActive => vaultState == VaultState.active;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'activeCredentialId': activeCredentialId,
        'activeCredentialGeneration': activeCredentialGeneration,
        'vaultState': vaultState.wireName,
      };

  static CredentialEpoch fromJson(Map<Object?, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final activeCredentialId = json['activeCredentialId'];
    final activeCredentialGeneration = json['activeCredentialGeneration'];
    final vaultState = json['vaultState'];
    if (schemaVersion is! int ||
        (activeCredentialId != null && activeCredentialId is! String) ||
        activeCredentialGeneration is! int ||
        vaultState is! String) {
      throw const FormatException('Invalid credential Epoch shape.');
    }
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported credential Epoch schema version: $schemaVersion.',
      );
    }
    try {
      return CredentialEpoch(
        schemaVersion: schemaVersion,
        activeCredentialId: activeCredentialId as String?,
        activeCredentialGeneration: activeCredentialGeneration,
        vaultState: VaultState.parse(vaultState),
      );
    } on ArgumentError {
      throw const FormatException('Invalid credential Epoch values.');
    }
  }
}
