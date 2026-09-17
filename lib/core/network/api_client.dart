import 'dart:convert';

import 'package:assistailab/core/config/app_env.dart';
import 'package:assistailab/core/security/credential_epoch_store.dart';
import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/core/sync/sync_lease.dart';
import 'package:http/http.dart' as http;

class ApiClient {
  final String baseUrl;
  final http.Client _client;
  final CredentialStorage? credentialStorage;
  final CredentialEpochStore? credentialEpochStore;

  ApiClient({
    String? baseUrl,
    http.Client? client,
    this.credentialStorage,
    this.credentialEpochStore,
  })  : baseUrl = baseUrl ?? AppEnv.apiBaseUrl,
        _client = client ?? http.Client();

  Future<String?> _getToken() async {
    try {
      final epochs = credentialEpochStore;
      final credentials = credentialStorage;
      if (epochs == null || credentials == null) return null;
      final epoch = await epochs.read();
      if (epoch == null || !epoch.isActive) return null;
      final credential = await credentials.readById(epoch.activeCredentialId!);
      if (credential == null ||
          credential.credentialId != epoch.activeCredentialId ||
          credential.credentialGeneration != epoch.activeCredentialGeneration) {
        return null;
      }
      return credential.accessToken;
    } catch (_) {
      return null;
    }
  }

  /// Exposes the current auth token for session-bound lease creation at orchestration boundaries.
  Future<String?> getAuthToken() => _getToken();

  /// Builds HTTP headers using the [BoundCredential] abstraction.
  ///
  /// - [BoundCredential.absent] (or null): use canonical CredentialStorage
  ///   (normal non-leased caller behaviour).
  /// - [BoundCredential.explicit]: use the pinned token exactly, NEVER falling
  ///   back to storage. Callers must ensure validity before calling this.
  Future<Map<String, String>> _getHeadersBound(BoundCredential bound) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    final String? token;
    if (bound.isExplicit) {
      // Explicit lease credential: use exactly this value, no storage fallback.
      token = bound.pinnedToken;
    } else {
      // No override: canonical storage resolution for non-leased callers.
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
  /// dynamic canonical-storage resolution (equivalent to
  /// [BoundCredential.absent]).
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
  /// dynamic credential lookup can occur during an authenticated leased request.
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

  Future<http.Response> getBoundWithHeaders(
    String endpoint,
    BoundCredential credential, {
    Map<String, String> headers = const {},
  }) async {
    final requestHeaders = await _getHeadersBound(credential)
      ..addAll(headers);
    return _client.get(
      Uri.parse('$baseUrl$endpoint'),
      headers: requestHeaders,
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

  /// Explicitly anonymous POST. Unlike [post] with a null token, this path
  /// never consults credential storage and therefore cannot attach a previous
  /// Bearer credential to login or another public authentication endpoint.
  Future<http.Response> postUnauthenticated(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final headers = await _getHeadersBound(BoundCredential.explicit(null));
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

  Future<http.Response> postBoundWithHeaders(
    String endpoint,
    BoundCredential credential, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
  }) async {
    final requestHeaders = await _getHeadersBound(credential)
      ..addAll(headers);
    return _client.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: requestHeaders,
      body: body != null ? jsonEncode(body) : null,
    );
  }

  Future<http.Response> patchBoundWithHeaders(
    String endpoint,
    BoundCredential credential, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
  }) async {
    final requestHeaders = await _getHeadersBound(credential)
      ..addAll(headers);
    return _client.patch(
      Uri.parse('$baseUrl$endpoint'),
      headers: requestHeaders,
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
