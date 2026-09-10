import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl(this.remoteDataSource);

  final AuthRemoteDataSource remoteDataSource;

  @override
  Future<AuthLoginResult> login(String email, String password) async {
    final response = await remoteDataSource.login(email, password);
    final token = response['token'];
    final userJson = response['user'];

    if (token is! String || token.trim().isEmpty || token != token.trim()) {
      throw const AuthResponseFormatException(
        '/auth/login',
        'Response token is missing, empty, or not a string.',
      );
    }
    if (userJson is! Map) {
      throw const AuthResponseFormatException(
        '/auth/login',
        'Response user is missing or not an object.',
      );
    }

    try {
      return AuthLoginResult(
        user: User.fromJson(Map<String, dynamic>.from(userJson)),
        accessToken: token,
      );
    } catch (error) {
      throw AuthResponseFormatException('/auth/login', error);
    }
  }

  @override
  Future<User> getCurrentUser(String accessToken) async {
    final meData = await remoteDataSource.getMe(accessToken);
    final userMap = meData['user'];
    if (userMap is! Map) {
      throw const AuthResponseFormatException(
        '/auth/me',
        'Response user is missing or not an object.',
      );
    }

    try {
      return User.fromJson(Map<String, dynamic>.from(userMap));
    } catch (error) {
      throw AuthResponseFormatException('/auth/me', error);
    }
  }
}
