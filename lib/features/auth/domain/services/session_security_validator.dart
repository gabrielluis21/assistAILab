import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../../core/security/credential_storage.dart';
import '../entities/auth_scope.dart';
import '../entities/offline_authority_record.dart';
import '../entities/user.dart';
import 'auth_scope_manager.dart';

final class ValidatedSessionMaterial {
  const ValidatedSessionMaterial({
    required this.scope,
    required this.jwtExpiresAtUtc,
    required this.credentialFingerprint,
  });

  final AuthScope scope;
  final DateTime jwtExpiresAtUtc;
  final String credentialFingerprint;
}

final class ValidatedOfflineSession {
  const ValidatedOfflineSession({
    required this.material,
    required this.authorityExpiresAtUtc,
  });

  final ValidatedSessionMaterial material;
  final DateTime authorityExpiresAtUtc;
}

/// Fail-closed validation shared by login, /auth/me and limited-offline restore.
///
/// JWT payload parsing here does *not* verify an HS256 signature and no backend
/// secret is present in Flutter. Online authority is established only by a
/// successful backend response made with the exact captured credential. Local
/// parsing adds shape, expiry and claim-coherence rejection checks.
final class SessionSecurityValidator {
  const SessionSecurityValidator({
    this.maximumOfflineAge = const Duration(hours: 8),
  });

  final Duration maximumOfflineAge;

  ValidatedSessionMaterial validateOnline({
    required User user,
    required StoredCredential credential,
    required DateTime nowUtc,
  }) {
    return _validateUserAndCredential(
      user: user,
      credential: credential,
      nowUtc: nowUtc.toUtc(),
    );
  }

  OfflineAuthorityRecord createOfflineAuthorityRecord({
    required User user,
    required StoredCredential credential,
    required ValidatedSessionMaterial material,
    required DateTime validatedAtUtc,
  }) {
    return OfflineAuthorityRecord(
      principalId: user.id,
      scopeKey: material.scope.canonicalKey,
      validatedAtUtc: validatedAtUtc.toUtc(),
      credentialBindingId: credential.bindingId,
      credentialFingerprint: material.credentialFingerprint,
      jwtExpiresAtUtc: material.jwtExpiresAtUtc,
    );
  }

  ValidatedOfflineSession validateOffline({
    required User cachedUser,
    required StoredCredential credential,
    required OfflineAuthorityRecord authority,
    required DateTime nowUtc,
  }) {
    final now = nowUtc.toUtc();
    if (authority.schemaVersion !=
        OfflineAuthorityRecord.currentSchemaVersion) {
      throw const SessionValidationException(
        'Unsupported offline authority record version.',
      );
    }
    if (authority.validatedAtUtc.isAfter(now)) {
      throw const SessionValidationException(
        'Offline authority validation timestamp is in the future.',
      );
    }

    final material = _validateUserAndCredential(
      user: cachedUser,
      credential: credential,
      nowUtc: now,
    );
    final authorityDeadline = authority.validatedAtUtc.add(maximumOfflineAge);

    if (now.isAfter(authorityDeadline)) {
      throw const SessionValidationException(
        'Offline authority freshness window has expired.',
      );
    }
    if (authority.principalId != cachedUser.id ||
        authority.scopeKey != material.scope.canonicalKey ||
        authority.credentialBindingId != credential.bindingId ||
        authority.credentialFingerprint != material.credentialFingerprint ||
        !_sameInstant(
          authority.jwtExpiresAtUtc,
          material.jwtExpiresAtUtc,
        )) {
      throw const SessionValidationException(
        'Offline authority binding does not match credential, principal or scope.',
      );
    }

    final offlineDeadline = authorityDeadline.isBefore(material.jwtExpiresAtUtc)
        ? authorityDeadline
        : material.jwtExpiresAtUtc;
    if (!now.isBefore(material.jwtExpiresAtUtc)) {
      throw const SessionValidationException('JWT has expired.');
    }

    return ValidatedOfflineSession(
      material: material,
      authorityExpiresAtUtc: offlineDeadline,
    );
  }

  ValidatedSessionMaterial _validateUserAndCredential({
    required User user,
    required StoredCredential credential,
    required DateTime nowUtc,
  }) {
    final scope = AuthScopeManager.scopeFromUser(user);
    if (scope == null || scope is InvalidAuthScope) {
      throw SessionValidationException(
        scope is InvalidAuthScope
            ? scope.reason
            : 'Authenticated user has no authoritative scope.',
      );
    }

    final jwt = JwtPayloadInspection.parse(credential.accessToken);
    if (!nowUtc.isBefore(jwt.expiresAtUtc)) {
      throw const SessionValidationException('JWT has expired.');
    }

    final normalizedRole = user.role.trim().toUpperCase();
    if (jwt.subject != user.id ||
        jwt.role.trim().toUpperCase() != normalizedRole ||
        jwt.customerId != user.customerId ||
        jwt.organizationId != user.organizationId) {
      throw const SessionValidationException(
        'JWT authority claims do not match the validated user context.',
      );
    }

    return ValidatedSessionMaterial(
      scope: scope,
      jwtExpiresAtUtc: jwt.expiresAtUtc,
      credentialFingerprint: credentialFingerprint(credential.accessToken),
    );
  }

  static String credentialFingerprint(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  static bool _sameInstant(DateTime left, DateTime right) =>
      left.toUtc().millisecondsSinceEpoch ==
      right.toUtc().millisecondsSinceEpoch;
}

final class JwtPayloadInspection {
  const JwtPayloadInspection({
    required this.subject,
    required this.role,
    required this.customerId,
    required this.organizationId,
    required this.expiresAtUtc,
  });

  final String subject;
  final String role;
  final String? customerId;
  final String? organizationId;
  final DateTime expiresAtUtc;

  static JwtPayloadInspection parse(String token) {
    final segments = token.split('.');
    if (segments.length != 3 || segments.any((part) => part.isEmpty)) {
      throw const SessionValidationException('Credential is not a valid JWT.');
    }

    try {
      final payloadText = utf8.decode(
        base64Url.decode(base64Url.normalize(segments[1])),
      );
      final decoded = jsonDecode(payloadText);
      if (decoded is! Map) {
        throw const SessionValidationException(
          'JWT payload is not an object.',
        );
      }
      final payload = Map<String, dynamic>.from(decoded);
      final subject = payload['sub'];
      final role = payload['role'];
      final expiresAt = payload['exp'];

      if (subject is! String || subject.trim().isEmpty) {
        throw const SessionValidationException(
          'JWT subject claim is missing or invalid.',
        );
      }
      if (role is! String || role.trim().isEmpty) {
        throw const SessionValidationException(
          'JWT role claim is missing or invalid.',
        );
      }
      if (expiresAt is! num || expiresAt.isNaN || !expiresAt.isFinite) {
        throw const SessionValidationException(
          'JWT expiration claim is missing or invalid.',
        );
      }
      final expirationSeconds = expiresAt.toInt();
      if (expirationSeconds.toDouble() != expiresAt.toDouble()) {
        throw const SessionValidationException(
          'JWT expiration claim must be an integer.',
        );
      }

      final customerId = _nullableStringClaim(payload, 'customerId');
      final organizationId = _nullableStringClaim(payload, 'organizationId');

      return JwtPayloadInspection(
        subject: subject,
        role: role,
        customerId: customerId,
        organizationId: organizationId,
        expiresAtUtc: DateTime.fromMillisecondsSinceEpoch(
          expirationSeconds * 1000,
          isUtc: true,
        ),
      );
    } on SessionValidationException {
      rethrow;
    } catch (_) {
      throw const SessionValidationException(
        'Credential contains a malformed JWT payload.',
      );
    }
  }

  static String? _nullableStringClaim(
    Map<String, dynamic> payload,
    String name,
  ) {
    if (!payload.containsKey(name)) {
      throw SessionValidationException('JWT claim $name is missing.');
    }
    final value = payload[name];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) {
      throw SessionValidationException('JWT claim $name is invalid.');
    }
    return value;
  }
}

final class SessionValidationException implements Exception {
  const SessionValidationException(this.message);

  final String message;

  @override
  String toString() => 'SessionValidationException: $message';
}
