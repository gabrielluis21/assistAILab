import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/sync/sync_lease.dart';
import 'auth_provider.dart';

final sessionApiClientProvider = Provider<SessionApiClient>((ref) {
  return SessionApiClient(
    apiClient: ref.watch(apiClientProvider),
    authNotifier: ref.read(authStateProvider.notifier),
  );
});

/// Executes ordinary authenticated resource requests with a credential and
/// session generation captured together.
///
/// Authorization failures are reported back with that exact generation, so a
/// late response from session A cannot terminate session B.
final class SessionApiClient {
  const SessionApiClient({
    required ApiClient apiClient,
    required AuthNotifier authNotifier,
  })  : _apiClient = apiClient,
        _authNotifier = authNotifier;

  final ApiClient _apiClient;
  final AuthNotifier _authNotifier;

  Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final request = await _authNotifier.acquireOnlineRequestCredential();
    final response = await _apiClient.postBound(
      endpoint,
      BoundCredential.explicit(request.accessToken),
      body: body,
    );
    await _authNotifier.handleAuthorizationFailure(
      sessionGeneration: request.sessionGeneration,
      statusCode: response.statusCode,
      authorityRevalidation: false,
    );
    if (!_authNotifier.isGenerationCurrent(request.sessionGeneration)) {
      throw const SessionRequestBlockedException(
        'Request completed after its session was invalidated.',
      );
    }
    return response;
  }

  Future<http.Response> get(String endpoint) async {
    final request = await _authNotifier.acquireOnlineRequestCredential();
    final response = await _apiClient.getBound(
      endpoint,
      BoundCredential.explicit(request.accessToken),
    );
    await _validateResponse(request.sessionGeneration, response.statusCode);
    return response;
  }

  Future<http.Response> postWithHeaders(
    String endpoint, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
  }) async {
    final request = await _authNotifier.acquireOnlineRequestCredential();
    final response = await _apiClient.postBoundWithHeaders(
      endpoint,
      BoundCredential.explicit(request.accessToken),
      body: body,
      headers: headers,
    );
    await _validateResponse(request.sessionGeneration, response.statusCode);
    return response;
  }

  Future<http.Response> patchWithHeaders(
    String endpoint, {
    Map<String, dynamic>? body,
    Map<String, String> headers = const {},
  }) async {
    final request = await _authNotifier.acquireOnlineRequestCredential();
    final response = await _apiClient.patchBoundWithHeaders(
      endpoint,
      BoundCredential.explicit(request.accessToken),
      body: body,
      headers: headers,
    );
    await _validateResponse(request.sessionGeneration, response.statusCode);
    return response;
  }

  Future<void> _validateResponse(int generation, int statusCode) async {
    await _authNotifier.handleAuthorizationFailure(
      sessionGeneration: generation,
      statusCode: statusCode,
      authorityRevalidation: false,
    );
    if (!_authNotifier.isGenerationCurrent(generation)) {
      throw const SessionRequestBlockedException(
        'Request completed after its session was invalidated.',
      );
    }
  }

  Future<http.Response> postUnauthenticated(
    String endpoint, {
    Map<String, dynamic>? body,
  }) {
    return _apiClient.postUnauthenticated(endpoint, body: body);
  }
}
