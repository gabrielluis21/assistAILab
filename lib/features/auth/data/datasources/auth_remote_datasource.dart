import 'dart:convert';
import '../../../../core/network/api_client.dart';

class AuthRemoteDataSource {
  final ApiClient apiClient;

  AuthRemoteDataSource(this.apiClient);

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await apiClient.post('/auth/login', body: {
      'email': email,
      'password': password,
    });

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(
          'Failed to login: ${response.statusCode} - ${response.body}');
    }
  }

  /// Valida a sessão local junto ao backend.
  ///
  /// Retorna o mapa do usuário se o token for válido (HTTP 200).
  /// Lança [UnauthorizedException] para 401/403.
  /// Lança [Exception] genérica para outros erros de rede.
  Future<Map<String, dynamic>> getMe() async {
    final response = await apiClient.get('/auth/me');

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else if (response.statusCode == 401 || response.statusCode == 403) {
      throw UnauthorizedException(
          'Token inválido ou expirado (${response.statusCode})');
    } else {
      throw Exception('GET /auth/me falhou: ${response.statusCode}');
    }
  }
}

class UnauthorizedException implements Exception {
  final String message;
  UnauthorizedException(this.message);
  @override
  String toString() => 'UnauthorizedException: $message';
}
