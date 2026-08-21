import 'package:hive/hive.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';
import 'dart:convert';

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
    final userStr = box.get('current_user');
    if (userStr != null) {
      return User.fromJson(jsonDecode(userStr));
    }
    return null;
  }
}
