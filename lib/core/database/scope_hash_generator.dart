import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../features/auth/domain/entities/auth_scope.dart';

class ScopeHashGenerator {
  /// Computes a canonical scope key string from a valid [AuthScope].
  ///
  /// - [ProfessionalAuthScope] -> `"PROFESSIONAL:$userId:$organizationId"`
  /// - [CustomerAuthScope] -> `"CUSTOMER:$userId:$customerId"`
  ///
  /// Throws [ArgumentError] if passed an invalid scope.
  static String canonicalScopeKey(AuthScope scope) {
    if (scope is ProfessionalAuthScope) {
      return 'PROFESSIONAL:${scope.userId}:${scope.organizationId}';
    } else if (scope is CustomerAuthScope) {
      return 'CUSTOMER:${scope.userId}:${scope.customerId}';
    } else if (scope is InvalidAuthScope) {
      throw ArgumentError(
        'Cannot generate database scope key for InvalidAuthScope: ${scope.reason}',
      );
    } else {
      throw ArgumentError(
        'Unknown or unsupported AuthScope type: ${scope.runtimeType}',
      );
    }
  }

  /// Generates a deterministic SHA-256 hex string hash from a canonical scope key.
  static String computeScopeHash(AuthScope scope) {
    final key = canonicalScopeKey(scope);
    final bytes = utf8.encode(key);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Generates the isolated SQLite database filename for a given [AuthScope].
  ///
  /// Format: `assistailab_<scopeHash>.db`
  static String databaseFileName(AuthScope scope) {
    final hash = computeScopeHash(scope);
    return 'assistailab_$hash.db';
  }
}
