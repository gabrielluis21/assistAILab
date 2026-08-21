import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';

class AuthRepositoryImpl implements AuthRepository {
  final AuthRemoteDataSource remoteDataSource;

  AuthRepositoryImpl(this.remoteDataSource);

  @override
  Future<User> login(String email, String password) async {
    final response = await remoteDataSource.login(email, password);
    final user = User.fromJson(response['user']);
    final token = response['token'];

    final box = await Hive.openBox('auth_box');
    await box.put('jwt_token', token);
    await box.put('current_user', jsonEncode(user.toJson()));

    return user;
  }

  @override
  Future<void> logout() async {
    final box = await Hive.openBox('auth_box');
    await box.delete('jwt_token');
    await box.delete('current_user');
  }

  @override
  Future<User?> getCurrentUser() async {
    final box = await Hive.openBox('auth_box');
    final token = box.get('jwt_token');

    // Sem token local: sessão inválida.
    if (token == null || (token as String).isEmpty) {
      return null;
    }

    try {
      // Valida o token no backend e obtém dados frescos do usuário.
      final meData = await remoteDataSource.getMe();
      final user = User.fromJson(meData);

      // Atualiza o cache local com dados vindos do backend.
      await box.put('current_user', jsonEncode(user.toJson()));

      return user;
    } on UnauthorizedException {
      // Token expirado ou revogado: limpa a sessão.
      await box.delete('jwt_token');
      await box.delete('current_user');
      return null;
    } catch (_) {
      // Falha de rede (offline etc.): cai de volta no cache local.
      final userStr = box.get('current_user');
      if (userStr != null) {
        return User.fromJson(jsonDecode(userStr as String));
      }
      return null;
    }
  }
}
