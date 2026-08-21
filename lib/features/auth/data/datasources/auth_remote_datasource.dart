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
      throw Exception('Failed to login: ${response.statusCode} - ${response.body}');
    }
  }
}
