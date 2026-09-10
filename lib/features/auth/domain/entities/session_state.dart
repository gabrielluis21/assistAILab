import 'auth_scope.dart';
import 'user.dart';

enum SessionOperation {
  bootstrap,
  login,
  logout,
  authorityRevalidation,
  runtimeAuthorization,
  localDatabase,
}

sealed class SessionState {
  const SessionState(this.generation);

  final int generation;

  bool get isBusy =>
      this is SessionBootstrapping ||
      this is SessionAuthenticating ||
      this is SessionLoggingOut;

  User? get authenticatedUser => switch (this) {
        AuthenticatedSession(:final user) => user,
        _ => null,
      };

  AuthScope? get authenticatedScope => switch (this) {
        AuthenticatedSession(:final scope) => scope,
        _ => null,
      };
}

final class SessionBootstrapping extends SessionState {
  const SessionBootstrapping(super.generation);
}

final class SessionUnauthenticated extends SessionState {
  const SessionUnauthenticated(
    super.generation, {
    this.cleanupPending = false,
    this.diagnostic,
  });

  final bool cleanupPending;
  final String? diagnostic;
}

final class SessionAuthenticating extends SessionState {
  const SessionAuthenticating(super.generation);
}

sealed class AuthenticatedSession extends SessionState {
  const AuthenticatedSession({
    required int generation,
    required this.user,
    required this.scope,
    required this.credentialBindingId,
    required this.onlineValidatedAtUtc,
    required this.jwtExpiresAtUtc,
  }) : super(generation);

  final User user;
  final AuthScope scope;
  final String credentialBindingId;
  final DateTime onlineValidatedAtUtc;
  final DateTime jwtExpiresAtUtc;
}

final class AuthenticatedOnline extends AuthenticatedSession {
  const AuthenticatedOnline({
    required super.generation,
    required super.user,
    required super.scope,
    required super.credentialBindingId,
    required super.onlineValidatedAtUtc,
    required super.jwtExpiresAtUtc,
  });
}

final class AuthenticatedOfflineLimited extends AuthenticatedSession {
  const AuthenticatedOfflineLimited({
    required super.generation,
    required super.user,
    required super.scope,
    required super.credentialBindingId,
    required super.onlineValidatedAtUtc,
    required super.jwtExpiresAtUtc,
    required this.offlineAuthorityExpiresAtUtc,
  });

  final DateTime offlineAuthorityExpiresAtUtc;
}

final class SessionLoggingOut extends SessionState {
  const SessionLoggingOut(super.generation);
}

final class SessionFailure extends SessionState {
  const SessionFailure(
    super.generation, {
    required this.operation,
    required this.error,
    required this.stackTrace,
    this.cleanupPending = false,
  });

  final SessionOperation operation;
  final Object error;
  final StackTrace stackTrace;
  final bool cleanupPending;
}

/// Cache/container identity. A repeated login to the same user and scope still
/// receives a new generation and therefore a distinct provider identity.
final class AuthenticatedSessionKey {
  const AuthenticatedSessionKey({
    required this.scope,
    required this.sessionGeneration,
  });

  final AuthScope scope;
  final int sessionGeneration;

  String get value => '${scope.canonicalKey}:$sessionGeneration';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthenticatedSessionKey &&
          scope == other.scope &&
          sessionGeneration == other.sessionGeneration;

  @override
  int get hashCode => Object.hash(scope, sessionGeneration);

  @override
  String toString() => 'AuthenticatedSessionKey($value)';
}
