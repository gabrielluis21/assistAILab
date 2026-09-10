import 'dart:convert';

import 'package:assistailab/core/config/app_env.dart';
import 'package:assistailab/core/sync/sync_lease.dart';
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

  /// Builds HTTP headers using the [BoundCredential] abstraction.
  ///
  /// - [BoundCredential.absent] (or null): fall back to Hive dynamic resolution
  ///   (normal non-leased caller behaviour).
  /// - [BoundCredential.explicit]: use the pinned token exactly, NEVER falling
  ///   back to Hive. Callers must ensure validity before calling this.
  Future<Map<String, String>> _getHeadersBound(BoundCredential bound) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    final String? token;
    if (bound.isExplicit) {
      // Explicit lease credential: use exactly this value, no Hive fallback.
      token = bound.pinnedToken;
    } else {
      // No override: normal Hive-based dynamic resolution for non-leased callers.
      token = await _getToken();
    }

    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }

    return headers;
  }

  /// Backwards-compatible header builder for callers that pass an optional raw token.
  ///
  /// When [authToken] is provided (non-null), it is used directly as an explicit
  /// value (equivalent to [BoundCredential.explicit]). When null, falls back to
  /// Hive dynamic resolution (equivalent to [BoundCredential.absent]).
  Future<Map<String, String>> _getHeaders({String? authToken}) async {
    final bound = authToken != null
        ? BoundCredential.explicit(authToken)
        : BoundCredential.absent;
    return _getHeadersBound(bound);
  }

  Future<http.Response> get(String endpoint, {String? authToken}) async {
    final headers = await _getHeaders(authToken: authToken);

    return _client.get(
      Uri.parse('$baseUrl$endpoint'),
      headers: headers,
    );
  }

  /// Session-bound variant of [get] that uses an explicit [BoundCredential].
  ///
  /// Callers that hold a [SyncLease] must use this variant to ensure no
  /// dynamic Hive lookup can occur during an authenticated leased request.
  Future<http.Response> getBound(
    String endpoint,
    BoundCredential credential,
  ) async {
    final headers = await _getHeadersBound(credential);
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

  /// Session-bound variant of [post] that uses an explicit [BoundCredential].
  Future<http.Response> postBound(
    String endpoint,
    BoundCredential credential, {
    Map<String, dynamic>? body,
  }) async {
    final headers = await _getHeadersBound(credential);
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
