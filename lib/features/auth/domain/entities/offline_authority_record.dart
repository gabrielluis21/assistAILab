final class OfflineAuthorityRecord {
  const OfflineAuthorityRecord({
    required this.principalId,
    required this.scopeKey,
    required this.validatedAtUtc,
    required this.credentialBindingId,
    required this.credentialId,
    required this.credentialGeneration,
    required this.credentialFingerprint,
    required this.jwtExpiresAtUtc,
    this.schemaVersion = currentSchemaVersion,
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String principalId;
  final String scopeKey;
  final String credentialBindingId;
  final String credentialId;
  final int credentialGeneration;
  final DateTime validatedAtUtc;
  final DateTime jwtExpiresAtUtc;
  final String credentialFingerprint;

  Map<String, Object> toJson() => <String, Object>{
        'schemaVersion': schemaVersion,
        'principalId': principalId,
        'canonicalAuthScope': scopeKey,
        'bindingId': credentialBindingId,
        'credentialId': credentialId,
        'credentialGeneration': credentialGeneration,
        'validatedAtUtc': validatedAtUtc.toUtc().toIso8601String(),
        'jwtExpiresAtUtc': jwtExpiresAtUtc.toUtc().toIso8601String(),
        'credentialFingerprint': credentialFingerprint,
      };

  static OfflineAuthorityRecord fromJson(Map<Object?, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final principalId = json['principalId'];
    final scopeKey = json['canonicalAuthScope'];
    final credentialBindingId = json['bindingId'];
    final credentialId = json['credentialId'];
    final credentialGeneration = json['credentialGeneration'];
    final validatedAt = json['validatedAtUtc'];
    final jwtExpiresAt = json['jwtExpiresAtUtc'];
    final credentialFingerprint = json['credentialFingerprint'];

    if (schemaVersion is! int ||
        principalId is! String ||
        scopeKey is! String ||
        credentialBindingId is! String ||
        credentialId is! String ||
        credentialGeneration is! int ||
        validatedAt is! String ||
        jwtExpiresAt is! String ||
        credentialFingerprint is! String) {
      throw const FormatException('Invalid offline authority record shape.');
    }
    if (schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported offline authority schema version: $schemaVersion.',
      );
    }

    final parsedValidatedAt = DateTime.tryParse(validatedAt);
    final parsedJwtExpiresAt = DateTime.tryParse(jwtExpiresAt);
    if (principalId.trim().isEmpty ||
        scopeKey.trim().isEmpty ||
        credentialBindingId.trim().isEmpty ||
        credentialId.trim().isEmpty ||
        credentialGeneration <= 0 ||
        credentialFingerprint.trim().isEmpty ||
        parsedValidatedAt == null ||
        parsedJwtExpiresAt == null) {
      throw const FormatException('Invalid offline authority record values.');
    }

    return OfflineAuthorityRecord(
      schemaVersion: schemaVersion,
      principalId: principalId,
      scopeKey: scopeKey,
      credentialBindingId: credentialBindingId,
      credentialId: credentialId,
      credentialGeneration: credentialGeneration,
      validatedAtUtc: parsedValidatedAt.toUtc(),
      jwtExpiresAtUtc: parsedJwtExpiresAt.toUtc(),
      credentialFingerprint: credentialFingerprint,
    );
  }
}
