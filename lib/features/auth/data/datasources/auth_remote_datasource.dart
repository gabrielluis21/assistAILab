import 'dart:convert';

import '../../../../core/network/api_client.dart';
import '../../../../core/sync/sync_lease.dart';

class AuthRemoteDataSource {
  AuthRemoteDataSource(this.apiClient);

  final ApiClient apiClient;

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await apiClient.postUnauthenticated(
      '/auth/login',
      body: <String, dynamic>{
        'email': email,
        'password': password,
      },
    );

    if (response.statusCode == 200) {
      return _decodeObject(response.body, endpoint: '/auth/login');
    }
    throw AuthRemoteException(
      endpoint: '/auth/login',
      statusCode: response.statusCode,
      message: 'Login request was rejected.',
    );
  }

  /// Validates one exact captured credential against the backend authority.
  Future<Map<String, dynamic>> getMe(String accessToken) async {
    final response = await apiClient.getBound(
      '/auth/me',
      BoundCredential.explicit(accessToken),
    );

    if (response.statusCode == 200) {
      return _decodeObject(response.body, endpoint: '/auth/me');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw UnauthorizedException(
        'Credential was rejected by /auth/me.',
        statusCode: response.statusCode,
      );
    }
    throw AuthRemoteException(
      endpoint: '/auth/me',
      statusCode: response.statusCode,
      message: 'Authority validation request failed.',
    );
  }

  static Map<String, dynamic> _decodeObject(
    String body, {
    required String endpoint,
  }) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FormatException('JSON root is not an object.');
      }
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      throw AuthResponseFormatException(endpoint, error);
    }
  }
}

class AuthRemoteException implements Exception {
  const AuthRemoteException({
    required this.endpoint,
    required this.statusCode,
    required this.message,
  });

  final String endpoint;
  final int statusCode;
  final String message;

  bool get isServerUnavailable => statusCode >= 500;

  @override
  String toString() =>
      'AuthRemoteException($endpoint, HTTP $statusCode): $message';
}

class UnauthorizedException extends AuthRemoteException {
  const UnauthorizedException(
    String message, {
    required super.statusCode,
  }) : super(
          endpoint: '/auth/me',
          message: message,
        );
}

final class AuthResponseFormatException implements Exception {
  const AuthResponseFormatException(this.endpoint, this.cause);

  final String endpoint;
  final Object cause;

  @override
  String toString() => 'AuthResponseFormatException($endpoint): $cause';
}
