final class OfflineAuthorityRecord {
  const OfflineAuthorityRecord({
    required this.principalId,
    required this.scopeKey,
    required this.validatedAtUtc,
    required this.credentialBindingId,
    required this.credentialFingerprint,
    required this.jwtExpiresAtUtc,
    this.schemaVersion = currentSchemaVersion,
  });

  static const int currentSchemaVersion = 1;

  final String principalId;
  final String scopeKey;
  final DateTime validatedAtUtc;
  final String credentialBindingId;
  final String credentialFingerprint;
  final DateTime jwtExpiresAtUtc;
  final int schemaVersion;

  Map<String, Object> toJson() => <String, Object>{
        'principalId': principalId,
        'scopeKey': scopeKey,
        'validatedAtUtc': validatedAtUtc.toUtc().toIso8601String(),
        'credentialBindingId': credentialBindingId,
        'credentialFingerprint': credentialFingerprint,
        'jwtExpiresAtUtc': jwtExpiresAtUtc.toUtc().toIso8601String(),
        'schemaVersion': schemaVersion,
      };

  static OfflineAuthorityRecord fromJson(Map<Object?, Object?> json) {
    final principalId = json['principalId'];
    final scopeKey = json['scopeKey'];
    final validatedAt = json['validatedAtUtc'];
    final credentialBindingId = json['credentialBindingId'];
    final credentialFingerprint = json['credentialFingerprint'];
    final jwtExpiresAt = json['jwtExpiresAtUtc'];
    final schemaVersion = json['schemaVersion'];

    if (principalId is! String ||
        scopeKey is! String ||
        validatedAt is! String ||
        credentialBindingId is! String ||
        credentialFingerprint is! String ||
        jwtExpiresAt is! String ||
        schemaVersion is! int) {
      throw const FormatException('Invalid offline authority record shape.');
    }

    final parsedValidatedAt = DateTime.tryParse(validatedAt);
    final parsedJwtExpiresAt = DateTime.tryParse(jwtExpiresAt);
    if (parsedValidatedAt == null || parsedJwtExpiresAt == null) {
      throw const FormatException('Invalid offline authority timestamps.');
    }

    return OfflineAuthorityRecord(
      principalId: principalId,
      scopeKey: scopeKey,
      validatedAtUtc: parsedValidatedAt.toUtc(),
      credentialBindingId: credentialBindingId,
      credentialFingerprint: credentialFingerprint,
      jwtExpiresAtUtc: parsedJwtExpiresAt.toUtc(),
      schemaVersion: schemaVersion,
    );
  }
}
