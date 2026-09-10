import '../entities/user.dart';

final class AuthLoginResult {
  const AuthLoginResult({
    required this.user,
    required this.accessToken,
  });

  final User user;
  final String accessToken;
}

/// Remote authentication gateway. Persistence belongs to session orchestration,
/// not to this repository.
abstract class AuthRepository {
  Future<AuthLoginResult> login(String email, String password);

  /// Validates the exact captured credential against `/auth/me`.
  Future<User> getCurrentUser(String accessToken);
}
