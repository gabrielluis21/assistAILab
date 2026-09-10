import 'dart:convert';

import 'package:assistailab/core/config/app_env.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

class ApiClient {
  final String baseUrl;
  final http.Client _client;

  ApiClient({
    String? baseUrl,
    http.Client? client,
  })  : baseUrl = baseUrl ?? AppEnv.apiBaseUrl,
        _client = client ?? http.Client();

  Future<String?> _getToken() async {
    final box = await Hive.openBox('auth_box');
    return box.get('jwt_token');
  }

  /// Exposes the current auth token for session-bound lease creation at orchestration boundaries.
  Future<String?> getAuthToken() => _getToken();

  Future<Map<String, String>> _getHeaders({String? authToken}) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    final token = authToken ?? await _getToken();

    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    return headers;
  }

  Future<http.Response> get(String endpoint, {String? authToken}) async {
    final headers = await _getHeaders(authToken: authToken);

    return _client.get(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
    );
  }

  Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
    String? authToken,
  }) async {
    final headers = await _getHeaders(authToken: authToken);

    return _client.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
    );
  }

  Future<http.Response> put(
    String endpoint, {
    Map<String, dynamic>? body,
    String? authToken,
  }) async {
    final headers = await _getHeaders(authToken: authToken);

    return _client.put(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
      body: body != null ? jsonEncode(body) : null,
    );
  }

  Future<http.Response> delete(String endpoint, {String? authToken}) async {
    final headers = await _getHeaders(authToken: authToken);

    return _client.delete(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
    );
  }
}
